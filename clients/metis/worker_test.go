package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// stubServer is a real HTTP server speaking the bridge surface, so the
// worker tests exercise the actual Api client too.
type stubServer struct {
	mu          sync.Mutex
	events      []string
	results     []map[string]any
	state       TaskState
	goneOnEvent bool
	claimable   *Task
	claimStatus int
	server      *httptest.Server
}

func newStubServer(t *testing.T) *stubServer {
	t.Helper()
	stub := &stubServer{state: TaskState{Status: "running", ClaimedBy: "testbox"}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/bridge/tasks/next", func(w http.ResponseWriter, r *http.Request) {
		stub.mu.Lock()
		defer stub.mu.Unlock()
		if stub.claimStatus != 0 {
			w.WriteHeader(stub.claimStatus)
			return
		}
		if stub.claimable == nil {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		task := stub.claimable
		stub.claimable = nil
		_ = json.NewEncoder(w).Encode(task)
	})
	mux.HandleFunc("POST /api/bridge/tasks/{id}/events", func(w http.ResponseWriter, r *http.Request) {
		stub.mu.Lock()
		defer stub.mu.Unlock()
		if stub.goneOnEvent {
			w.WriteHeader(http.StatusGone)
			return
		}
		var body struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		stub.events = append(stub.events, body.Text)
		w.WriteHeader(http.StatusAccepted)
	})
	mux.HandleFunc("POST /api/bridge/tasks/{id}/result", func(w http.ResponseWriter, r *http.Request) {
		stub.mu.Lock()
		defer stub.mu.Unlock()
		result := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&result)
		stub.results = append(stub.results, result)
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /api/bridge/tasks/{id}", func(w http.ResponseWriter, r *http.Request) {
		stub.mu.Lock()
		defer stub.mu.Unlock()
		_ = json.NewEncoder(w).Encode(stub.state)
	})
	stub.server = httptest.NewServer(mux)
	t.Cleanup(stub.server.Close)
	return stub
}

func (s *stubServer) lastResult(t *testing.T) map[string]any {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.results) == 0 {
		t.Fatal("no result reported")
	}
	return s.results[len(s.results)-1]
}

func (s *stubServer) resultCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.results)
}

// fakeAgent runs a shell script emitting {"text":…} / {"final":…} lines.
type fakeAgent struct{ script string }

func (f fakeAgent) Command(_ string, _ []string) []string {
	return []string{"/bin/sh", "-c", f.script}
}

func (f fakeAgent) Parse(line string) ParsedEvent {
	var event struct {
		Text  string  `json:"text"`
		Final *string `json:"final"`
		Model string  `json:"model"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ParsedEvent{}
	}
	if event.Final != nil {
		return ParsedEvent{Text: *event.Final, Final: *event.Final, HasFinal: true, Model: event.Model}
	}
	return ParsedEvent{Text: event.Text, Model: event.Model}
}

func initRepo(t *testing.T) (repo, root string) {
	t.Helper()
	dir := t.TempDir()
	repo = filepath.Join(dir, "repo")
	root = filepath.Join(dir, "worktrees")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"},
	} {
		cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	return repo, root
}

func testConfig(server, repo, root string, mutate func(*Config)) *Config {
	cfg := &Config{
		Servers: []*Server{{Name: "test", Server: server, Token: "mbt_x",
			Projects: map[string]string{"proj": repo}}},
		Client: "testbox", Agent: "claude",
		WorkspacesRoot:    root,
		HeartbeatInterval: 1000, CancelPollInterval: 1000, InactivityTimeout: 30,
		PollInterval: 1, GCTTL: 86400,
	}
	if mutate != nil {
		mutate(cfg)
	}
	return cfg
}

// testWorktreeRoot is where testConfig's server keeps its worktrees.
func testWorktreeRoot(root string) string {
	return filepath.Join(root, "test")
}

func testTask(ref string) *Task {
	task := &Task{TaskID: 1, Ref: ref, Prompt: "implement the thing"}
	task.Context.Project.Name = "proj"
	task.Context.PriorSteps = []PriorStep{{Name: "spec", Content: "the spec",
		Artifacts: []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		}{{Name: "spec.md", URL: "http://a/spec.md"}}}}
	return task
}

func runWorker(t *testing.T, stub *stubServer, repo, root, script, ref string, mutate func(*Config)) *Config {
	t.Helper()
	cfg := testConfig(stub.server.URL, repo, root, mutate)
	server := cfg.Servers[0]
	worker := &Worker{api: NewApi(server, cfg.Client), cfg: cfg, server: server,
		task: testTask(ref), agent: fakeAgent{script: script}, logf: func(string, ...any) {}}
	worker.Run()
	return cfg
}

func TestHappyPathStructuredResult(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	script := `echo '{"text":"editing files","model":"anthropic/claude-opus-4-8"}'; ` +
		`printf '%s\n' '{"final":"All done\nMETIS_RESULT: {\"status\":\"completed\",\"summary\":\"capped retries\",\"artifacts\":[{\"type\":\"pr\",\"url\":\"http://x/1\"}]}"}'`
	runWorker(t, stub, repo, root, script, "RUN-1", nil)

	result := stub.lastResult(t)
	if result["status"] != "completed" || result["summary"] != "capped retries" {
		t.Fatalf("result = %v", result)
	}
	artifacts := result["artifacts"].([]any)
	if len(artifacts) != 1 || artifacts[0].(map[string]any)["url"] != "http://x/1" {
		t.Fatalf("artifacts = %v", artifacts)
	}
	if result["agent"] != "claude" || result["model"] != "anthropic/claude-opus-4-8" {
		t.Fatalf("agent/model must ride with the result: %v", result)
	}

	worktree := filepath.Join(testWorktreeRoot(root), "RUN-1")
	branch, _ := exec.Command("git", "-C", worktree, "branch", "--show-current").Output()
	if strings.TrimSpace(string(branch)) != "metis/run-1" {
		t.Fatalf("branch = %q", branch)
	}
	raw, err := os.ReadFile(filepath.Join(worktree, metaFile))
	if err != nil {
		t.Fatal(err)
	}
	var meta map[string]any
	_ = json.Unmarshal(raw, &meta)
	if meta["status"] != "completed" || meta["settled_at"] == nil {
		t.Fatalf("meta = %v", meta)
	}
}

func TestFallbackSummaryWithoutStructuredResult(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `echo '{"final":"Shipped the fix."}'`, "RUN-1", nil)
	result := stub.lastResult(t)
	if result["status"] != "completed" || result["summary"] != "Shipped the fix." {
		t.Fatalf("result = %v", result)
	}
}

func TestNonZeroExitReportsFailed(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `echo '{"text":"boom"}'; exit 1`, "RUN-1", nil)
	result := stub.lastResult(t)
	if result["status"] != "failed" || !strings.Contains(result["summary"].(string), "exited non-zero") {
		t.Fatalf("result = %v", result)
	}
}

func TestWatchdogKillsSilentAgent(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	start := time.Now()
	runWorker(t, stub, repo, root, `sleep 30`, "RUN-1",
		func(c *Config) { c.InactivityTimeout = 1 })
	if time.Since(start) > 10*time.Second {
		t.Fatal("watchdog took too long")
	}
	result := stub.lastResult(t)
	if result["status"] != "failed" || !strings.Contains(result["summary"].(string), "watchdog") {
		t.Fatalf("result = %v", result)
	}
}

func TestCancellationPollKillsAgent(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	stub.state = TaskState{Status: "rejected"}
	runWorker(t, stub, repo, root, `echo '{"text":"start"}'; sleep 30`, "RUN-1",
		func(c *Config) { c.CancelPollInterval = 1 })
	result := stub.lastResult(t)
	if result["status"] != "failed" || !strings.Contains(result["summary"].(string), "settled or claim moved") {
		t.Fatalf("result = %v", result)
	}
}

func TestHeartbeatPostsProgressAndGoneStopsEverything(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root,
		`echo '{"text":"milestone"}'; sleep 3; echo '{"final":"done"}'`, "RUN-1",
		func(c *Config) { c.HeartbeatInterval = 1 })
	stub.mu.Lock()
	sawHeartbeat := false
	for _, event := range stub.events {
		if strings.Contains(event, "working — milestone") {
			sawHeartbeat = true
		}
	}
	stub.mu.Unlock()
	if !sawHeartbeat {
		t.Fatalf("no heartbeat with snippet; events = %v", stub.events)
	}

	gone := newStubServer(t)
	gone.goneOnEvent = true
	start := time.Now()
	runWorker(t, gone, repo, root, `echo '{"text":"x"}'; sleep 30`, "RUN-2",
		func(c *Config) { c.HeartbeatInterval = 1 })
	if time.Since(start) > 15*time.Second {
		t.Fatal("gone heartbeat took too long to stop the agent")
	}
	if gone.resultCount() != 0 {
		t.Fatalf("no result must be reported once the task is gone; got %v", gone.results)
	}
}

func TestMissingCheckoutFailsFast(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	cfg := testConfig(stub.server.URL, repo, root, nil)
	task := testTask("RUN-1")
	task.Context.Project.Name = "other-proj"
	worker := &Worker{api: NewApi(cfg.Servers[0], cfg.Client), cfg: cfg, server: cfg.Servers[0],
		task: task, agent: fakeAgent{script: "true"}, logf: func(string, ...any) {}}
	worker.Run()
	result := stub.lastResult(t)
	if result["status"] != "failed" || !strings.Contains(result["summary"].(string), "No checkout configured") {
		t.Fatalf("result = %v", result)
	}
	if _, err := os.Stat(filepath.Join(testWorktreeRoot(root), "RUN-1")); !os.IsNotExist(err) {
		t.Fatal("no worktree must be created for an unknown project")
	}
}

func TestReclaimReusesWorktree(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `touch partial.txt; echo '{"final":"part one"}'`, "RUN-1", nil)
	if _, err := os.Stat(filepath.Join(testWorktreeRoot(root), "RUN-1", "partial.txt")); err != nil {
		t.Fatal("partial work missing after first run")
	}

	runWorker(t, stub, repo, root,
		`test -f partial.txt || exit 1; echo '{"final":"resumed"}'`, "RUN-1", nil)
	result := stub.lastResult(t)
	if result["status"] != "completed" || result["summary"] != "resumed" {
		t.Fatalf("resume result = %v (partial work lost?)", result)
	}
}

func TestPromptFoldsContextAndRules(t *testing.T) {
	repo, root := initRepo(t)
	cfg := testConfig("http://x", repo, root, nil)
	worker := &Worker{cfg: cfg, task: testTask("RUN-1")}
	prompt := worker.prompt()
	for _, want := range []string{"implement the thing", "earlier step: spec", "the spec",
		"http://a/spec.md", resultMarker, "metis/run-1"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt missing %q:\n%s", want, prompt)
		}
	}
}
