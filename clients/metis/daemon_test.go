package main

import (
	"net/http"
	"testing"
)

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
