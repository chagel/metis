package main

import (
	"os/exec"
	"sort"
	"strings"
	"time"
)

// Daemon is the poll loop: claim per configured project (alphabetical,
// so behavior is deterministic), work one task at a time, sweep
// worktrees hourly.
type Daemon struct {
	cfg    *Config
	api    *Api
	agent  Agent
	logf   func(string, ...any)
	lastGC time.Time
}

func NewDaemon(cfg *Config, logf func(string, ...any)) (*Daemon, error) {
	agent, err := AgentFor(cfg.Agent)
	if err != nil {
		return nil, err
	}
	return &Daemon{cfg: cfg, api: NewApi(cfg), agent: agent, logf: logf}, nil
}

func (d *Daemon) Run(once bool) error {
	names := d.projectNames()
	d.logf("metis-bridge %s — %s polling %s for %s", version, d.cfg.Client, d.cfg.Server, strings.Join(names, ", "))
	for {
		task, err := d.nextTask(names)
		switch {
		case err != nil:
			if once {
				return err
			}
			d.logf("claim failed: %v", err)
			time.Sleep(time.Duration(d.cfg.PollInterval) * time.Second)
		case task != nil:
			worker := &Worker{api: d.api, cfg: d.cfg, task: task, agent: d.agent, logf: d.logf}
			worker.Run()
		case once:
			d.logf("queue empty")
		default:
			time.Sleep(time.Duration(d.cfg.PollInterval) * time.Second)
		}
		if time.Since(d.lastGC) > time.Hour {
			d.GC()
		}
		if once {
			return nil
		}
	}
}

func (d *Daemon) GC() {
	d.lastGC = time.Now()
	GCWorktrees(d.cfg.WorkspacesRoot, d.repoFor, time.Duration(d.cfg.GCTTL)*time.Second, time.Now().UTC(), d.logf)
}

func (d *Daemon) nextTask(names []string) (*Task, error) {
	for _, project := range names {
		task, err := d.api.Claim(project)
		if err != nil {
			return nil, err
		}
		if task != nil {
			return task, nil
		}
	}
	return nil, nil
}

func (d *Daemon) projectNames() []string {
	names := make([]string, 0, len(d.cfg.Projects))
	for name := range d.cfg.Projects {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// repoFor finds which configured checkout a worktree ref belongs to, so
// gc can deregister it with git before removing the directory.
func (d *Daemon) repoFor(ref string) string {
	for _, repo := range d.cfg.Projects {
		out, err := exec.Command("git", "-C", repo, "worktree", "list", "--porcelain").Output()
		if err == nil && strings.Contains(string(out), "/"+ref+"\n") {
			return repo
		}
	}
	return ""
}
