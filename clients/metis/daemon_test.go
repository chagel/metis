package main

import (
	"net/http"
	"os"
	"testing"
	"time"
)

func TestHotReloadSwapsConfigBetweenTasks(t *testing.T) {
	repo, root := initRepo(t)
	first := newStubServer(t)
	second := newStubServer(t)
	second.claimable = testTask("RUN-9")

	path := writeConfig(t, `{"server": "`+first.server.URL+`", "token": "t1", "projects": {"proj": "`+repo+`"}}`)
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg.WorkspacesRoot = root
	daemon, err := NewDaemon(cfg, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	daemon.WatchConfig(path)

	if task, _, _ := daemon.nextTask(); task != nil {
		t.Fatal("first server has no tasks")
	}

	rewrite := `{"servers": [{"name": "two", "server": "` + second.server.URL +
		`", "token": "t2", "projects": {"proj": "` + repo + `"}}]}`
	if err := os.WriteFile(path, []byte(rewrite), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now(), time.Now().Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	daemon.maybeReload()
	task, from, err := daemon.nextTask()
	if err != nil || task == nil || from.server.Name != "two" {
		t.Fatalf("reload not applied: task=%v from=%v err=%v", task, from, err)
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

func TestNextTaskSpansServers(t *testing.T) {
	repo, root := initRepo(t)
	empty := newStubServer(t)
	loaded := newStubServer(t)
	loaded.claimable = testTask("RUN-7")

	cfg := testConfig(empty.server.URL, repo, root, func(c *Config) {
		c.Servers = []*Server{
			{Name: "a-empty", Server: empty.server.URL, Token: "t1", Projects: map[string]string{"proj": repo}},
			{Name: "b-loaded", Server: loaded.server.URL, Token: "t2", Projects: map[string]string{"proj": repo}},
		}
	})
	daemon, err := NewDaemon(cfg, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}

	task, from, err := daemon.nextTask()
	if err != nil || task == nil {
		t.Fatalf("nextTask = %v, %v", task, err)
	}
	if task.Ref != "RUN-7" || from.server.Name != "b-loaded" {
		t.Fatalf("claimed %s from %s, want RUN-7 from b-loaded", task.Ref, from.server.Name)
	}

	// Drained — both empty now.
	task, _, err = daemon.nextTask()
	if task != nil || err != nil {
		t.Fatalf("drained nextTask = %v, %v", task, err)
	}
}

func TestNextTaskSurvivesOneServerDown(t *testing.T) {
	repo, root := initRepo(t)
	down := newStubServer(t)
	down.claimStatus = http.StatusInternalServerError
	loaded := newStubServer(t)
	loaded.claimable = testTask("RUN-8")

	cfg := testConfig(down.server.URL, repo, root, func(c *Config) {
		c.Servers = []*Server{
			{Name: "a-down", Server: down.server.URL, Token: "t1", Projects: map[string]string{"proj": repo}},
			{Name: "b-loaded", Server: loaded.server.URL, Token: "t2", Projects: map[string]string{"proj": repo}},
		}
	})
	daemon, err := NewDaemon(cfg, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}

	task, from, err := daemon.nextTask()
	if err != nil || task == nil || from.server.Name != "b-loaded" {
		t.Fatalf("one server down must not block the other: task=%v from=%v err=%v", task, from, err)
	}

	// Every server failing surfaces the error.
	loaded.claimStatus = http.StatusInternalServerError
	if _, _, err := daemon.nextTask(); err == nil {
		t.Fatal("all servers failing must return an error")
	}
}
