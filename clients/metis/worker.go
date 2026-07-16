package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	resultMarker       = "METIS_RESULT:"
	summaryFallbackLen = 500
	snippetLen         = 120
	detailCap          = 65536
)

// bridgeAPI is the slice of Api the worker needs; tests stand up a real
// httptest server instead of mocking it.
type bridgeAPI interface {
	Event(id int64, text string) error
	Result(id int64, status, summary, detail string, artifacts []Artifact, agent, model string) error
	TaskState(id int64) (*TaskState, error)
}

// Worker runs one claimed task end to end: worktree, agent subprocess,
// heartbeats, cancellation polling, the inactivity watchdog, and the
// final report.
type Worker struct {
	api    bridgeAPI
	cfg    *Config
	server *Server
	task   *Task
	agent  Agent
	logf   func(string, ...any)
}

// label identifies the task across servers in logs: "dev/RUN-1".
func (w *Worker) label() string {
	return w.server.Name + "/" + w.task.Ref
}

type outcome struct {
	status    string
	summary   string
	detail    string
	artifacts []Artifact
	model     string
	session   string
	// exitedSilent: the agent process ended on its own without one
	// parsed event — on a resume, the signature of a dead session
	// pointer. Kills (watchdog, cancellation) never set it.
	exitedSilent bool
}

func (w *Worker) Run() {
	repo, ok := w.server.Checkout(w.task.Context.Project.Name)
	if !ok {
		w.report(&outcome{status: "failed", summary: fmt.Sprintf(
			"No checkout configured on %s for project %q.", w.cfg.Client, w.task.Context.Project.Name)})
		return
	}
	worktree := Worktree{Repo: repo, Root: w.cfg.WorktreeRoot(w.server), Ref: w.worktreeRef()}
	if err := worktree.Prepare(); err != nil {
		w.report(&outcome{status: "failed", summary: err.Error()})
		return
	}
	argv, resumed := w.command(worktree)
	result := w.driveAgent(worktree, argv)
	// A resume that dies without a single parsed event is a broken
	// session pointer (stale id, upgraded CLI), not a real task failure
	// — the fresh run with the full context bundle is the floor.
	if result != nil && resumed && result.exitedSilent {
		w.logf("task %s: resume produced nothing — starting fresh", w.label())
		result = w.driveAgent(worktree, w.freshCommand(worktree))
	}
	if result == nil {
		w.logf("task %s: gone — stopped", w.label())
		return
	}
	// The commit contract is enforced, not trusted: leftovers an agent
	// failed to commit (a sandboxed agent cannot commit at all) are
	// committed here so they reach later steps and survive gc. On a
	// completed step a leftover we cannot commit fails the step instead
	// of silently completing with doomed work; on a failed step the
	// sweep is best-effort — partial work is preserved for diagnosis.
	committed, err := worktree.CommitLeftovers("metis: work from step " + w.task.Ref)
	switch {
	case err != nil && result.status == "completed":
		result = &outcome{status: "failed", summary: fmt.Sprintf(
			"Step reported success but left work the daemon could not commit: %v", err)}
	case err != nil:
		w.logf("task %s: could not commit leftover work: %v", w.label(), err)
	case committed:
		w.logf("task %s: agent left uncommitted work — committed it", w.label())
	}
	if result.status == "completed" {
		if err := worktree.SaveSession(w.cfg.Agent, result.session, w.stepNumber()); err != nil {
			w.logf("task %s: could not save session pointer: %v", w.label(), err)
		}
	}
	if err := worktree.Settle(result.status); err != nil {
		w.logf("task %s: could not write meta: %v", w.label(), err)
	}
	w.report(result)
}

// command picks resume when this worktree already holds a completed
// session for the configured agent — the machine-local continuation of
// the run's earlier steps.
func (w *Worker) command(worktree Worktree) ([]string, bool) {
	session, step, ok := worktree.Session(w.cfg.Agent)
	if ok {
		mode := briefResumed
		if step >= w.stepNumber()-1 {
			mode = briefResumedCurrent
		}
		if argv := w.agent.Resume(session, w.prompt(worktree.Branch(), mode), w.cfg.AgentArgs); argv != nil {
			return argv, true
		}
	}
	return w.freshCommand(worktree), false
}

func (w *Worker) freshCommand(worktree Worktree) []string {
	return w.agent.Command(w.prompt(worktree.Branch(), briefFresh), w.cfg.AgentArgs)
}

// stepNumber is 1-based; older servers omit the claim field.
func (w *Worker) stepNumber() int {
	if w.task.Step > 0 {
		return w.task.Step
	}
	return 1
}

// worktreeRef keys the worktree and branch by run, so consecutive
// delegated steps of one run share repo state on this machine; the task
// ref is the fallback for servers that predate run_ref.
func (w *Worker) worktreeRef() string {
	if w.task.RunRef != "" {
		return w.task.RunRef
	}
	return w.task.Ref
}

// driveAgent reads the agent's event stream with three clocks: a
// heartbeat post (progress is the server-side liveness signal), a
// cancellation poll (the active upgrade of stop-on-410), and the
// inactivity watchdog — semantic, not wall-clock: a session still
// emitting events is never killed for running long. A nil return means
// the task died server-side and the result must not be reported.
func (w *Worker) driveAgent(worktree Worktree, argv []string) *outcome {
	w.logf("task %s: running %s in %s", w.label(), argv[0], worktree.Path())

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = worktree.Path()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		return &outcome{status: "failed", summary: err.Error()}
	}
	cmd.Stdout = writeEnd
	cmd.Stderr = writeEnd
	if err := cmd.Start(); err != nil {
		writeEnd.Close()
		readEnd.Close()
		return &outcome{status: "failed", summary: "could not start agent: " + err.Error()}
	}
	writeEnd.Close()
	defer readEnd.Close()

	lines := make(chan string, 64)
	go func() {
		defer close(lines)
		reader := bufio.NewReaderSize(readEnd, 1<<20)
		for {
			line, err := reader.ReadString('\n')
			if line != "" {
				lines <- strings.TrimRight(line, "\n")
			}
			if err != nil {
				return
			}
		}
	}()

	finalText := ""
	model := ""
	session := ""
	activity := false
	lastSnippet := "starting " + w.cfg.Agent
	lastActivity := time.Now()
	heartbeat := time.NewTicker(time.Duration(w.cfg.HeartbeatInterval) * time.Second)
	defer heartbeat.Stop()
	cancelPoll := time.NewTicker(time.Duration(w.cfg.CancelPollInterval) * time.Second)
	defer cancelPoll.Stop()
	inactivity := time.Duration(w.cfg.InactivityTimeout) * time.Second
	watchdog := time.NewTicker(max(time.Second, inactivity/10))
	defer watchdog.Stop()

	for {
		select {
		case line, open := <-lines:
			if !open {
				var result *outcome
				if err := cmd.Wait(); err != nil {
					result = &outcome{status: "failed", summary: w.failureSummary(finalText),
						detail: strings.TrimSpace(finalText), exitedSilent: !activity}
				} else {
					result = w.conclude(finalText)
				}
				result.model = model
				result.session = session
				return result
			}
			lastActivity = time.Now()
			event := w.agent.Parse(line)
			if event != (ParsedEvent{}) {
				activity = true
			}
			if snippet := lastLine(event.Text); snippet != "" {
				lastSnippet = snippet
			}
			if event.Model != "" {
				model = event.Model
			}
			if event.SessionID != "" {
				session = event.SessionID
			}
			if event.HasFinal {
				finalText = event.Final
			}
		case <-watchdog.C:
			if time.Since(lastActivity) > inactivity {
				w.kill(cmd, lines)
				return &outcome{status: "failed", summary: fmt.Sprintf(
					"Agent went silent for %d minutes; killed by the watchdog.", w.cfg.InactivityTimeout/60)}
			}
		case <-heartbeat.C:
			err := w.api.Event(w.task.TaskID, "working — "+lastSnippet)
			if errors.Is(err, ErrGone) {
				w.kill(cmd, lines)
				return nil
			}
			if err != nil {
				// A blip must not kill the run, but a silent one makes the
				// eventual 410 post-mortem impossible to read.
				w.logf("task %s: heartbeat failed: %v", w.label(), err)
			}
		case <-cancelPoll.C:
			state, err := w.api.TaskState(w.task.TaskID)
			// A flaky status poll must not kill a healthy run.
			if err == nil && (state.Status != "running" || state.ClaimedBy != w.cfg.Client) {
				w.kill(cmd, lines)
				return &outcome{status: "failed", summary: "stopped: task settled or claim moved"}
			}
		}
	}
}

// The agent is asked to end with a METIS_RESULT: json line; honour it
// when present, fall back to its final message otherwise. The final
// message minus the marker line rides along as the detail — the full
// report later workflow steps read.
func (w *Worker) conclude(finalText string) *outcome {
	lines := strings.Split(finalText, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(trimmed, resultMarker) {
			continue
		}
		var structured struct {
			Status    string     `json:"status"`
			Summary   string     `json:"summary"`
			Artifacts []Artifact `json:"artifacts"`
		}
		if json.Unmarshal([]byte(strings.TrimPrefix(trimmed, resultMarker)), &structured) != nil {
			break
		}
		status := "completed"
		if structured.Status == "failed" {
			status = "failed"
		}
		detail := strings.TrimSpace(strings.Join(lines[:i], "\n") + "\n" + strings.Join(lines[i+1:], "\n"))
		return &outcome{status: status, summary: structured.Summary, detail: detail, artifacts: structured.Artifacts}
	}
	return &outcome{status: "completed", summary: fallbackSummary(finalText), detail: strings.TrimSpace(finalText)}
}

func (w *Worker) failureSummary(finalText string) string {
	tail := strings.TrimSpace(finalText)
	if len(tail) > summaryFallbackLen {
		tail = tail[len(tail)-summaryFallbackLen:]
	}
	return strings.TrimSpace("Agent exited non-zero. " + tail)
}

func (w *Worker) report(result *outcome) {
	summary := truncate(result.summary, 2000)
	detail := truncate(strings.TrimSpace(result.detail), detailCap)
	err := w.api.Result(w.task.TaskID, result.status, summary, detail,
		result.artifacts, w.cfg.Agent, result.model)
	switch {
	case errors.Is(err, ErrGone):
		w.logf("task %s: result discarded (task no longer live)", w.label())
	case err != nil:
		w.logf("task %s: could not report result: %v", w.label(), err)
	default:
		w.logf("task %s: reported %s", w.label(), result.status)
	}
}

// brief is how much re-briefing the step prompt carries: a fresh run
// gets the full prior-steps bundle; a resumed session gets the
// continuity note, and drops the bundle only when it already saw the
// immediately prior step — re-briefing those only burns context.
type brief int

const (
	briefFresh          brief = iota
	briefResumed              // resumed, but the session missed steps — keep the bundle
	briefResumedCurrent       // resumed and current — the session saw the prior steps
)

func (w *Worker) prompt(branch string, mode brief) string {
	sections := []string{w.task.Prompt}
	if mode != briefFresh {
		sections = append(sections, "## Session continuity\n"+
			"This conversation continues the session that worked this run's earlier steps "+
			"in this same worktree — your earlier context and decisions still apply.")
	}
	if input := w.task.Context.Input; input != "" {
		sections = append(sections, "## Run subject\n"+input)
	}
	if mode != briefResumedCurrent {
		for _, step := range w.task.Context.PriorSteps {
			body := fmt.Sprintf("## Context from earlier step: %s\n%s", step.Name, step.Content)
			urls := []string{}
			for _, artifact := range step.Artifacts {
				if artifact.URL != "" {
					urls = append(urls, artifact.URL)
				}
			}
			if len(urls) > 0 {
				body += "\nArtifacts: " + strings.Join(urls, " ")
			}
			sections = append(sections, body)
		}
	}
	sections = append(sections, fmt.Sprintf(`## Unattended run rules
You run unattended in a dedicated git worktree on a branch named
%s — work here, never switch branches of the main checkout.
Every step of this workflow run shares that branch: earlier steps'
commits are already on it, and later steps build on yours.
Follow the repo's own conventions and run its tests.
Commit your work to this branch as you finish. If your sandbox
blocks git commits, that is not a failure: leave everything in the
working tree — it is committed automatically when the step ends.
When the task is fully done, print a full closing report (what you
changed, where, and how the next step should build on it), then
exactly one final line:
%s {"status":"completed","summary":"<one or two sentences>","artifacts":[{"type":"pr","url":"…"}]}
Use "status":"failed" with a precise reason when you cannot finish.`,
		branch, resultMarker))
	return strings.Join(sections, "\n\n")
}

// kill terminates the agent's whole process group (an agent may spawn
// children) and drains the line reader so its goroutine can finish.
func (w *Worker) kill(cmd *exec.Cmd, lines chan string) {
	go func() {
		for range lines {
		}
	}()
	if cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
	}
}

func lastLine(text string) string {
	trimmed := strings.TrimSpace(text)
	line := strings.TrimSpace(trimmed[strings.LastIndexByte(trimmed, '\n')+1:])
	return truncate(line, snippetLen)
}

func fallbackSummary(finalText string) string {
	text := truncate(strings.TrimSpace(finalText), summaryFallbackLen)
	if text == "" {
		return "Agent finished without a summary."
	}
	return text
}

func truncate(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}
