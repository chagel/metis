package main

import (
	"net/http"
	"os"
	"testing"
	"time"
)

func fakeDaemon(t *testing.T, cfg *Config) *Daemon {
	t.Helper()
	daemon, err := NewDaemon(cfg, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	daemon.agent = fakeAgent{script: `echo '{"final":"done"}'`}
	return daemon
}

func drainDaemon(t *testing.T, d *Daemon) {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for d.total > 0 {
		select {
		case name := <-d.done:
			d.finish(name)
		case <-deadline:
			t.Fatal("workers did not finish in time")
		}
	}
}

func TestHotReloadSwapsConfigWhileIdle(t *testing.T) {
	repo, root := initRepo(t)
	first := newStubServer(t)
	second := newStubServer(t)
	second.claimable = []*Task{testTask("RUN-9")}

	path := writeConfig(t, `{"server": "`+first.server.URL+`", "token": "t1", "workspaces_root": "`+root+
		`", "projects": {"proj": "`+repo+`"}}`)
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	daemon := fakeDaemon(t, cfg)
	daemon.WatchConfig(path)

	if started, _ := daemon.dispatch(); started != 0 {
		t.Fatal("first server has no tasks")
	}

	rewrite := `{"workspaces_root": "` + root + `", "servers": [{"name": "two", "server": "` + second.server.URL +
		`", "token": "t2", "projects": {"proj": "` + repo + `"}}]}`
	if err := os.WriteFile(path, []byte(rewrite), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now(), time.Now().Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}

	// A busy daemon must keep the config its workers were dispatched with.
	daemon.total = 1
	daemon.maybeReload()
	if daemon.targets[0].server.Name == "two" {
		t.Fatal("reload must wait until the daemon is idle")
	}
	daemon.total = 0

	daemon.maybeReload()
	// Reload rebuilds the agent from config; keep the test fake in play.
	daemon.agent = fakeAgent{script: `echo '{"final":"done"}'`}
	started, err := daemon.dispatch()
	if err != nil || started != 1 || daemon.targets[0].server.Name != "two" {
		t.Fatalf("reload not applied: started=%d targets=%v err=%v", started, daemon.describeTargets(), err)
	}
	drainDaemon(t, daemon)
	if second.lastResult(t)["status"] != "completed" {
		t.Fatalf("result = %v", second.lastResult(t))
	}

	// A broken edit must be ignored, keeping the previous config.
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now(), time.Now().Add(4*time.Second)); err != nil {
		t.Fatal(err)
	}
	daemon.maybeReload()
	if len(daemon.targets) != 1 || daemon.targets[0].server.Name != "two" {
		t.Fatalf("broken edit must keep the previous config; targets = %v", daemon.describeTargets())
	}
}

func TestDispatchSpansServers(t *testing.T) {
	repo, root := initRepo(t)
	empty := newStubServer(t)
	loaded := newStubServer(t)
	loaded.claimable = []*Task{testTask("RUN-7")}

	cfg := testConfig(empty.server.URL, repo, root, func(c *Config) {
		c.Servers = []*Server{
			{Name: "a-empty", Server: empty.server.URL, Token: "t1",
				Projects: map[string]string{"proj": repo}, MaxWorkers: 1},
			{Name: "b-loaded", Server: loaded.server.URL, Token: "t2",
				Projects: map[string]string{"proj": repo}, MaxWorkers: 1},
		}
	})
	daemon := fakeDaemon(t, cfg)

	started, err := daemon.dispatch()
	if err != nil || started != 1 {
		t.Fatalf("dispatch = %d, %v", started, err)
	}
	drainDaemon(t, daemon)
	if loaded.lastResult(t)["status"] != "completed" {
		t.Fatalf("result = %v", loaded.lastResult(t))
	}

	// Drained — both empty now.
	if started, err := daemon.dispatch(); started != 0 || err != nil {
		t.Fatalf("drained dispatch = %d, %v", started, err)
	}
}

func TestDispatchSurvivesOneServerDown(t *testing.T) {
	repo, root := initRepo(t)
	down := newStubServer(t)
	down.claimStatus = http.StatusInternalServerError
	loaded := newStubServer(t)
	loaded.claimable = []*Task{testTask("RUN-8")}

	cfg := testConfig(down.server.URL, repo, root, func(c *Config) {
		c.Servers = []*Server{
			{Name: "a-down", Server: down.server.URL, Token: "t1",
				Projects: map[string]string{"proj": repo}, MaxWorkers: 1},
			{Name: "b-loaded", Server: loaded.server.URL, Token: "t2",
				Projects: map[string]string{"proj": repo}, MaxWorkers: 1},
		}
	})
	daemon := fakeDaemon(t, cfg)

	started, err := daemon.dispatch()
	if err != nil || started != 1 {
		t.Fatalf("one server down must not block the other: started=%d err=%v", started, err)
	}
	drainDaemon(t, daemon)

	// Every server failing surfaces the error.
	loaded.claimStatus = http.StatusInternalServerError
	if started, err := daemon.dispatch(); err == nil || started != 0 {
		t.Fatalf("all servers failing must return an error; started=%d err=%v", started, err)
	}
}

func TestMaxWorkersRunTasksInParallel(t *testing.T) {
	repo, root := initRepo(t)
	stub := newStubServer(t)
	task2 := testTask("RUN-2")
	task2.TaskID = 2
	stub.claimable = []*Task{testTask("RUN-1"), task2}

	cfg := testConfig(stub.server.URL, repo, root, func(c *Config) {
		c.Servers[0].MaxWorkers = 2
	})
	daemon := fakeDaemon(t, cfg)
	// Each agent waits for the other's marker, so the pair only finishes
	// when both run at once — a serial daemon deadlocks into the drain
	// timeout. Concurrent Prepare on one checkout rides along.
	rendezvous := t.TempDir()
	daemon.agent = fakeAgent{script: `touch "` + rendezvous + `/$(basename "$PWD")"; ` +
		`while [ "$(ls "` + rendezvous + `" | wc -l)" -lt 2 ]; do sleep 0.1; done; ` +
		`echo '{"final":"done"}'`}

	started, err := daemon.dispatch()
	if err != nil || started != 2 {
		t.Fatalf("dispatch = %d, %v — want both slots filled", started, err)
	}
	drainDaemon(t, daemon)
	if stub.resultCount() != 2 {
		t.Fatalf("results = %d, want 2", stub.resultCount())
	}
}
