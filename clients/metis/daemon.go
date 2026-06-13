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
// alphabetical, so behavior is deterministic), work up to each server's
// max_workers tasks concurrently, sweep worktrees hourly. When watching
// a config path, edits hot-reload while idle — never mid-task.
type Daemon struct {
	cfg        *Config
	targets    []*target
	agent      Agent
	logf       func(string, ...any)
	lastGC     time.Time
	configPath string
	configSeen time.Time
	running    map[string]int
	total      int
	done       chan string
}

func NewDaemon(cfg *Config, logf func(string, ...any)) (*Daemon, error) {
	agent, err := AgentFor(cfg.Agent)
	if err != nil {
		return nil, err
	}
	return &Daemon{cfg: cfg, agent: agent, targets: buildTargets(cfg), logf: logf,
		running: map[string]int{}, done: make(chan string, 64)}, nil
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

// maybeReload swaps in an edited config while the daemon is idle. An
// invalid edit is logged once and the daemon keeps running on the
// previous config — the same refuse-to-crash-loop posture as
// `metis install`. The idle guard keeps in-flight workers on the
// targets they were dispatched with and the slot accounting honest
// across the target rebuild.
func (d *Daemon) maybeReload() {
	if d.configPath == "" || d.total > 0 {
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
		d.reap()
		d.maybeReload()
		started, err := d.dispatch()
		switch {
		case err != nil:
			if once {
				return err
			}
			d.logf("claim failed: %v", err)
		case once && started == 0:
			d.logf("queue empty")
		}
		if once {
			d.drain()
		}
		if time.Since(d.lastGC) > time.Hour {
			d.GC()
		}
		if once {
			return nil
		}
		if started == 0 {
			d.idle()
		}
	}
}

// dispatch fills every server's free worker slots in deterministic
// order, claiming until each is full or its queue is empty. A claim
// error on one server must not stop the others (dev being down is no
// reason to ignore prod) — the error is returned only when every server
// failed and nothing was started.
func (d *Daemon) dispatch() (int, error) {
	started := 0
	var firstErr error
	failures := 0
	for _, t := range d.targets {
		if err := d.fill(t, &started); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", t.server.Name, err)
			}
			failures++
		}
	}
	if failures == len(d.targets) && started == 0 {
		return 0, firstErr
	}
	return started, nil
}

func (d *Daemon) fill(t *target, started *int) error {
	for d.running[t.server.Name] < t.server.MaxWorkers {
		task, err := d.claim(t)
		if err != nil {
			return err
		}
		if task == nil {
			return nil
		}
		d.running[t.server.Name]++
		d.total++
		*started++
		worker := &Worker{api: t.api, cfg: d.cfg, server: t.server,
			task: task, agent: d.agent, logf: d.logf}
		go func(name string) {
			worker.Run()
			d.done <- name
		}(t.server.Name)
	}
	return nil
}

func (d *Daemon) claim(t *target) (*Task, error) {
	for _, project := range t.projects {
		task, err := t.api.Claim(project)
		if err != nil {
			d.logf("claim %s/%s: %v", t.server.Name, project, err)
			return nil, err
		}
		if task != nil {
			return task, nil
		}
	}
	return nil, nil
}

// reap collects finished workers without blocking; idle additionally
// waits for one to finish or the poll interval to elapse, whichever
// comes first — a freed slot refills immediately, an empty queue is
// re-polled on the interval.
func (d *Daemon) reap() {
	for {
		select {
		case name := <-d.done:
			d.finish(name)
		default:
			return
		}
	}
}

func (d *Daemon) idle() {
	select {
	case name := <-d.done:
		d.finish(name)
	case <-time.After(time.Duration(d.cfg.PollInterval) * time.Second):
	}
}

func (d *Daemon) drain() {
	for d.total > 0 {
		d.finish(<-d.done)
	}
}

func (d *Daemon) finish(server string) {
	d.running[server]--
	d.total--
}

func (d *Daemon) GC() {
	d.lastGC = time.Now()
	for _, t := range d.targets {
		GCWorktrees(d.cfg.WorktreeRoot(t.server), repoFinder(t.server),
			time.Duration(d.cfg.GCTTL)*time.Second, time.Now().UTC(), d.logf)
	}
}

func (d *Daemon) describeTargets() []string {
	described := make([]string, 0, len(d.targets))
	for _, t := range d.targets {
		workers := ""
		if t.server.MaxWorkers > 1 {
			workers = fmt.Sprintf(" ×%d", t.server.MaxWorkers)
		}
		described = append(described, fmt.Sprintf("%s (%s)%s", t.server.Name, strings.Join(t.projects, ", "), workers))
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
