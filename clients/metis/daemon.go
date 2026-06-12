package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// target pairs one configured server with its api client and the
// deterministic order its projects are polled in.
type target struct {
	server   *Server
	api      *Api
	projects []string
}

// Daemon is the poll loop: claim per server per project (both
// alphabetical, so behavior is deterministic), work one task at a time,
// sweep worktrees hourly. When watching a config path, edits hot-reload
// between tasks — never mid-task.
type Daemon struct {
	cfg        *Config
	targets    []*target
	agent      Agent
	logf       func(string, ...any)
	lastGC     time.Time
	configPath string
	configSeen time.Time
}

func NewDaemon(cfg *Config, logf func(string, ...any)) (*Daemon, error) {
	agent, err := AgentFor(cfg.Agent)
	if err != nil {
		return nil, err
	}
	return &Daemon{cfg: cfg, agent: agent, targets: buildTargets(cfg), logf: logf}, nil
}

func buildTargets(cfg *Config) []*target {
	servers := append([]*Server{}, cfg.Servers...)
	sort.Slice(servers, func(i, j int) bool { return servers[i].Name < servers[j].Name })
	targets := make([]*target, 0, len(servers))
	for _, server := range servers {
		names := make([]string, 0, len(server.Projects))
		for name := range server.Projects {
			names = append(names, name)
		}
		sort.Strings(names)
		targets = append(targets, &target{
			server: server, api: NewApi(server, cfg.Client), projects: names})
	}
	return targets
}

// WatchConfig arms hot-reload for path; the current mtime is the
// baseline.
func (d *Daemon) WatchConfig(path string) {
	d.configPath = path
	if info, err := os.Stat(path); err == nil {
		d.configSeen = info.ModTime()
	}
}

// maybeReload swaps in an edited config between tasks. An invalid edit
// is logged once and the daemon keeps running on the previous config —
// the same refuse-to-crash-loop posture as `metis install`.
func (d *Daemon) maybeReload() {
	if d.configPath == "" {
		return
	}
	info, err := os.Stat(d.configPath)
	if err != nil || info.ModTime().Equal(d.configSeen) {
		return
	}
	d.configSeen = info.ModTime()
	cfg, err := LoadConfig(d.configPath)
	var agent Agent
	if err == nil {
		agent, err = AgentFor(cfg.Agent)
	}
	if err != nil {
		d.logf("config reload skipped: %v — still running on the previous config", err)
		return
	}
	d.agent = agent
	d.cfg = cfg
	d.targets = buildTargets(cfg)
	d.logf("config reloaded — polling %s", strings.Join(d.describeTargets(), "; "))
}

func (d *Daemon) Run(once bool) error {
	d.logf("metis %s — %s polling %s", version, d.cfg.Client, strings.Join(d.describeTargets(), "; "))
	for {
		d.maybeReload()
		task, from, err := d.nextTask()
		switch {
		case err != nil:
			if once {
				return err
			}
			d.logf("claim failed: %v", err)
			time.Sleep(time.Duration(d.cfg.PollInterval) * time.Second)
		case task != nil:
			worker := &Worker{api: from.api, cfg: d.cfg, server: from.server,
				task: task, agent: d.agent, logf: d.logf}
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
	for _, t := range d.targets {
		GCWorktrees(d.cfg.WorktreeRoot(t.server), repoFinder(t.server),
			time.Duration(d.cfg.GCTTL)*time.Second, time.Now().UTC(), d.logf)
	}
}

// nextTask claims across servers; a claim error on one server must not
// stop the others (dev being down is no reason to ignore prod). The
// error is returned only when every server failed.
func (d *Daemon) nextTask() (*Task, *target, error) {
	var firstErr error
	failures := 0
	for _, t := range d.targets {
		for _, project := range t.projects {
			task, err := t.api.Claim(project)
			if err != nil {
				d.logf("claim %s/%s: %v", t.server.Name, project, err)
				if firstErr == nil {
					firstErr = fmt.Errorf("%s: %w", t.server.Name, err)
				}
				failures++
				break // next server — this one is unreachable or rejecting
			}
			if task != nil {
				return task, t, nil
			}
		}
	}
	if failures == len(d.targets) {
		return nil, nil, firstErr
	}
	return nil, nil, nil
}

func (d *Daemon) describeTargets() []string {
	described := make([]string, 0, len(d.targets))
	for _, t := range d.targets {
		described = append(described, fmt.Sprintf("%s (%s)", t.server.Name, strings.Join(t.projects, ", ")))
	}
	return described
}

// repoFinder reports which of a server's checkouts a worktree ref
// belongs to, so gc can deregister it with git before removing the
// directory. Each repo's worktree list is fetched once per sweep.
func repoFinder(server *Server) func(ref string) string {
	lists := map[string]string{}
	return func(ref string) string {
		for _, repo := range server.Projects {
			list, ok := lists[repo]
			if !ok {
				out, _ := exec.Command("git", "-C", repo, "worktree", "list", "--porcelain").Output()
				list = string(out)
				lists[repo] = list
			}
			if strings.Contains(list, "/"+ref+"\n") {
				return repo
			}
		}
		return ""
	}
}
