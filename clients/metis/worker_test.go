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
	claimable   []*Task
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
		if len(stub.claimable) == 0 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		task := stub.claimable[0]
		stub.claimable = stub.claimable[1:]
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

// fakeAgent runs a shell script emitting {"text":…} / {"final":…} /
// {"session":…} lines; resumeScript (when set) is what a Resume runs.
type fakeAgent struct{ script, resumeScript string }

func (f fakeAgent) Command(_ string, _ []string) []string {
	return []string{"/bin/sh", "-c", f.script}
}

func (f fakeAgent) Resume(_, _ string, _ []string) []string {
	if f.resumeScript == "" {
		return nil
	}
	return []string{"/bin/sh", "-c", f.resumeScript}
}

func (f fakeAgent) Parse(line string) ParsedEvent {
	var event struct {
		Text    string  `json:"text"`
		Final   *string `json:"final"`
		Model   string  `json:"model"`
		Session string  `json:"session"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ParsedEvent{}
	}
	if event.Final != nil {
		return ParsedEvent{Text: *event.Final, Final: *event.Final, HasFinal: true, Model: event.Model}
	}
	return ParsedEvent{Text: event.Text, Model: event.Model, SessionID: event.Session}
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
			Projects: map[string]string{"proj": repo}, MaxWorkers: 1}},
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
	task.Context.Input = "ship feature 42"
	task.Context.Project.Name = "proj"
	task.Context.PriorSteps = []PriorStep{{Name: "spec", Content: "the spec",
		Artifacts: []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		}{{Name: "spec.md", URL: "http://a/spec.md"}}}}
	return task
}

func runTask(t *testing.T, stub *stubServer, cfg *Config, task *Task, agent Agent) {
	t.Helper()
	server := cfg.Servers[0]
	worker := &Worker{api: NewApi(server, cfg.Client), cfg: cfg, server: server,
		task: task, agent: agent, logf: func(string, ...any) {}}
	worker.Run()
}

func runWorker(t *testing.T, stub *stubServer, repo, root, script, ref string, mutate func(*Config)) *Config {
	t.Helper()
	cfg := testConfig(stub.server.URL, repo, root, mutate)
	runTask(t, stub, cfg, testTask(ref), fakeAgent{script: script})
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
	if result["detail"] != "All done" {
		t.Fatalf("the final message minus the marker must ride as detail: %v", result)
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
	runTask(t, stub, cfg, task, fakeAgent{script: "true"})
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
	prompt := worker.prompt("metis/ship-r1", briefFresh)
	for _, want := range []string{"implement the thing", "## Run subject\nship feature 42",
		"earlier step: spec", "the spec", "http://a/spec.md", resultMarker, "metis/ship-r1",
		"Commit all your work"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt missing %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "Session continuity") {
		t.Fatal("a fresh prompt must not claim session continuity")
	}
}

func TestResumedPromptSlimsPriorStepsOnlyWhenSessionIsCurrent(t *testing.T) {
	repo, root := initRepo(t)
	cfg := testConfig("http://x", repo, root, nil)
	worker := &Worker{cfg: cfg, task: testTask("RUN-1")}

	slim := worker.prompt("metis/run-r1", briefResumedCurrent)
	if strings.Contains(slim, "earlier step: spec") {
		t.Fatalf("a current session already saw the prior steps:\n%s", slim)
	}
	for _, want := range []string{"Session continuity", "## Run subject", "Commit all your work"} {
		if !strings.Contains(slim, want) {
			t.Fatalf("slim prompt missing %q:\n%s", want, slim)
		}
	}

	stale := worker.prompt("metis/run-r1", briefResumed)
	if !strings.Contains(stale, "earlier step: spec") || !strings.Contains(stale, "Session continuity") {
		t.Fatalf("a resumed-but-stale session still needs the full bundle:\n%s", stale)
	}
}

func runStep(t *testing.T, stub *stubServer, cfg *Config, runRef, ref string, number int, agent fakeAgent) {
	t.Helper()
	task := testTask(ref)
	task.RunRef = runRef
	task.Step = number
	runTask(t, stub, cfg, task, agent)
}

func TestRunSessionResumesAcrossSteps(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	cfg := testConfig(stub.server.URL, repo, root, nil)
	step := func(ref string, number int, agent fakeAgent) {
		runStep(t, stub, cfg, "SHIP-R2", ref, number, agent)
	}
	step("SHIP-3", 1, fakeAgent{script: `echo '{"session":"sess-1"}'; echo '{"final":"implemented"}'`})

	worktree := Worktree{Repo: repo, Root: testWorktreeRoot(root), Ref: "SHIP-R2"}
	id, seen, ok := worktree.Session("claude")
	if !ok || id != "sess-1" || seen != 1 {
		t.Fatalf("session pointer = %q step %d ok %v", id, seen, ok)
	}

	step("SHIP-4", 2, fakeAgent{script: `echo '{"final":"fresh — resume was skipped"}'`,
		resumeScript: `echo '{"final":"resumed"}'`})
	if result := stub.lastResult(t); result["summary"] != "resumed" {
		t.Fatalf("the second step must resume the saved session: %v", result)
	}
}

func TestBrokenResumeFallsBackToFresh(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	cfg := testConfig(stub.server.URL, repo, root, nil)
	worktree := Worktree{Repo: repo, Root: testWorktreeRoot(root), Ref: "RUN-8"}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	if err := worktree.SaveSession("claude", "gone-id", 1); err != nil {
		t.Fatal(err) // e.g. the CLI's own retention swept the transcript
	}
	runTask(t, stub, cfg, testTask("RUN-8"), fakeAgent{script: `echo '{"final":"fresh"}'`,
		resumeScript: `exit 1`})

	result := stub.lastResult(t)
	if result["status"] != "completed" || result["summary"] != "fresh" {
		t.Fatalf("a dead session pointer must fall back to a fresh run: %v", result)
	}
}

func TestKilledResumeDoesNotRetryFresh(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	stub.state = TaskState{Status: "rejected"} // task settled server-side
	cfg := testConfig(stub.server.URL, repo, root, func(c *Config) { c.CancelPollInterval = 1 })
	worktree := Worktree{Repo: repo, Root: testWorktreeRoot(root), Ref: "RUN-12"}
	if err := worktree.Prepare(); err != nil {
		t.Fatal(err)
	}
	if err := worktree.SaveSession("claude", "sess-x", 1); err != nil {
		t.Fatal(err)
	}
	runTask(t, stub, cfg, testTask("RUN-12"), fakeAgent{script: `echo '{"final":"fresh — must not run"}'`,
		resumeScript: `sleep 30`})

	result := stub.lastResult(t)
	if !strings.Contains(result["summary"].(string), "settled or claim moved") {
		t.Fatalf("a killed resume is not a dead pointer — no fresh retry: %v", result)
	}
	if stub.resultCount() != 1 {
		t.Fatalf("exactly one result must be reported, got %d", stub.resultCount())
	}
}

func TestCompletedStepCommitsLeftovers(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `touch leftover.txt; echo '{"final":"done"}'`, "RUN-13", nil)
	if result := stub.lastResult(t); result["status"] != "completed" {
		t.Fatalf("result = %v", result)
	}
	worktree := filepath.Join(testWorktreeRoot(root), "RUN-13")
	status, _ := exec.Command("git", "-C", worktree, "status", "--porcelain").Output()
	if strings.TrimSpace(string(status)) != "" {
		t.Fatalf("a completed step must leave a clean worktree:\n%s", status)
	}
	subject, _ := exec.Command("git", "-C", worktree, "log", "-1", "--format=%s").Output()
	if !strings.Contains(string(subject), "leftover work from step RUN-13") {
		t.Fatalf("head commit = %q, want the daemon's leftover commit", subject)
	}
}

func TestCleanAndSelfCommittedStepsAddNoLeftoverCommit(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `echo '{"final":"analysis only"}'`, "RUN-14", nil)
	count, _ := exec.Command("git", "-C", filepath.Join(testWorktreeRoot(root), "RUN-14"),
		"rev-list", "--count", "HEAD").Output()
	if strings.TrimSpace(string(count)) != "1" {
		t.Fatalf("a clean step must add no commit, history = %s", count)
	}

	runWorker(t, stub, repo, root, `git config user.email t@t; git config user.name t; `+
		`touch impl.txt; git add impl.txt; git commit -qm impl; echo '{"final":"built"}'`, "RUN-15", nil)
	subject, _ := exec.Command("git", "-C", filepath.Join(testWorktreeRoot(root), "RUN-15"),
		"log", "-1", "--format=%s").Output()
	if strings.TrimSpace(string(subject)) != "impl" {
		t.Fatalf("head = %q — an agent that committed its own work needs no leftover commit", subject)
	}
}

func TestFailedStepSavesNoSessionPointer(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	runWorker(t, stub, repo, root, `echo '{"session":"s9"}'; exit 1`, "RUN-9", nil)
	worktree := Worktree{Repo: repo, Root: testWorktreeRoot(root), Ref: "RUN-9"}
	if _, _, ok := worktree.Session("claude"); ok {
		t.Fatal("a failed step must not become the session the next step resumes")
	}
}

func TestRunScopedWorktreeSharesStateAcrossSteps(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	cfg := testConfig(stub.server.URL, repo, root, nil)
	step := func(ref, script string) {
		runStep(t, stub, cfg, "SHIP-R1", ref, 0, fakeAgent{script: script})
	}
	step("SHIP-1", `git config user.email t@t; git config user.name t; `+
		`touch impl.txt; git add impl.txt; git commit -qm impl; echo '{"final":"implemented"}'`)
	step("SHIP-2", `test -f impl.txt || exit 1; echo '{"final":"reviewed"}'`)

	result := stub.lastResult(t)
	if result["status"] != "completed" || result["summary"] != "reviewed" {
		t.Fatalf("the second step must see the first step's work: %v", result)
	}
	worktree := filepath.Join(testWorktreeRoot(root), "SHIP-R1")
	branch, _ := exec.Command("git", "-C", worktree, "branch", "--show-current").Output()
	if strings.TrimSpace(string(branch)) != "metis/ship-r1" {
		t.Fatalf("branch = %q", branch)
	}
	if _, err := os.Stat(filepath.Join(testWorktreeRoot(root), "SHIP-1")); !os.IsNotExist(err) {
		t.Fatal("no per-task worktree must be created when the server sends run_ref")
	}
}
