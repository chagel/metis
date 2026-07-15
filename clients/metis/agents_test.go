package main

import (
	"reflect"
	"slices"
	"testing"
)

func TestFilterArgsStripsProtocolBreakingFlags(t *testing.T) {
	got := filterArgs(
		[]string{"--model", "opus", "--output-format", "text", "--resume", "abc", "--allowedTools", "Bash", "--mode=json"},
		append(claudeBlocked, "--mode"))
	want := []string{"--model", "opus", "--allowedTools", "Bash"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filterArgs = %v, want %v", got, want)
	}
}

func TestClaudeCommandAndParse(t *testing.T) {
	agent := claudeAgent{}
	cmd := agent.Command("do it", []string{"--model", "opus"})
	if cmd[0] != "claude" || cmd[1] != "-p" {
		t.Fatalf("command prefix = %v", cmd[:2])
	}
	assertIncludes(t, cmd, "stream-json")
	// The inner agent must not inherit the user's MCP servers.
	assertIncludes(t, cmd, "--strict-mcp-config")
	assertIncludes(t, cmd, "--model")
	if slices.Index(cmd, "--model") < slices.Index(cmd, "--permission-mode") {
		t.Fatal("user agent_args must come last so they can override defaults")
	}

	resume := agent.Resume("sess-1", "go on", nil)
	if !slices.Contains(resume, "--resume") || !slices.Contains(resume, "sess-1") {
		t.Fatalf("resume argv = %v", resume)
	}
	if cwd := agent.Resume("", "go on", nil); !slices.Contains(cwd, "--continue") {
		t.Fatalf("id-less resume must fall back to the cwd session: %v", cwd)
	}

	init := agent.Parse(`{"type":"system","subtype":"init","model":"claude-opus-4-8","session_id":"sess-1"}`)
	if init.Model != "claude-opus-4-8" || init.SessionID != "sess-1" {
		t.Fatalf("init parse = %+v", init)
	}
	text := agent.Parse(`{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}`)
	if text.Text != "hi" || text.HasFinal {
		t.Fatalf("assistant parse = %+v", text)
	}
	final := agent.Parse(`{"type":"result","result":"all done","is_error":false}`)
	if final.Final != "all done" || !final.HasFinal {
		t.Fatalf("result parse = %+v", final)
	}
	if junk := agent.Parse("not json"); junk != (ParsedEvent{}) {
		t.Fatalf("junk parse = %+v", junk)
	}
}

func TestPiCommandAndParse(t *testing.T) {
	agent := piAgent{}
	cmd := agent.Command("do it", nil)
	want := []string{"pi", "-p", "--mode", "json"}
	if !reflect.DeepEqual(cmd[:4], want) {
		t.Fatalf("command prefix = %v", cmd[:4])
	}
	if cmd[len(cmd)-1] != "do it" {
		t.Fatal("prompt must be the last argument")
	}
	resume := agent.Resume("ignored", "go on", nil)
	if !slices.Contains(resume, "--continue") || resume[len(resume)-1] != "go on" {
		t.Fatalf("pi resume must be cwd-scoped --continue with the prompt last: %v", resume)
	}

	final := agent.Parse(`{"type":"message_end","message":{"role":"assistant","provider":"anthropic","model":"claude-fable-5","content":[{"type":"text","text":"done"}]}}`)
	if final.Final != "done" || !final.HasFinal {
		t.Fatalf("assistant message_end parse = %+v", final)
	}
	if final.Model != "anthropic/claude-fable-5" {
		t.Fatalf("model = %q, want provider/model", final.Model)
	}
	user := agent.Parse(`{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}`)
	if user != (ParsedEvent{}) {
		t.Fatalf("user message_end parse = %+v", user)
	}
}

func TestCodexCommandAndParse(t *testing.T) {
	agent := codexAgent{}
	cmd := agent.Command("do it", []string{"--model", "gpt-5.5"})
	want := []string{"codex", "exec", "--json", "--full-auto", "--skip-git-repo-check"}
	if !reflect.DeepEqual(cmd[:5], want) {
		t.Fatalf("command prefix = %v", cmd[:5])
	}
	if cmd[len(cmd)-1] != "do it" {
		t.Fatal("prompt must be the last argument")
	}
	assertIncludes(t, cmd, "--model")

	if argv := agent.Resume("", "go on", nil); argv != nil {
		t.Fatalf("codex sessions are global — an id-less resume must be refused: %v", argv)
	}
	resume := agent.Resume("thread-7", "go on", nil)
	want = []string{"codex", "exec", "resume", "thread-7"}
	if !reflect.DeepEqual(resume[:4], want) {
		t.Fatalf("resume prefix = %v", resume[:4])
	}
	if resume[len(resume)-1] != "go on" {
		t.Fatal("prompt must be the last argument")
	}

	started := agent.Parse(`{"type":"thread.started","thread_id":"thread-7"}`)
	if started.SessionID != "thread-7" {
		t.Fatalf("thread.started parse = %+v", started)
	}
	final := agent.Parse(`{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"ready"}}`)
	if final.Final != "ready" || !final.HasFinal {
		t.Fatalf("agent_message parse = %+v", final)
	}
	activity := agent.Parse(`{"type":"item.completed","item":{"type":"command_execution","text":"ls"}}`)
	if activity.Text != "ls" || activity.HasFinal {
		t.Fatalf("command_execution parse = %+v", activity)
	}
	if usage := agent.Parse(`{"type":"turn.completed","usage":{}}`); usage != (ParsedEvent{}) {
		t.Fatalf("turn.completed parse = %+v", usage)
	}
}

func TestAgentForRejectsUnknown(t *testing.T) {
	if _, err := AgentFor("cursor"); err == nil {
		t.Fatal("expected error for unknown agent")
	}
}

func assertIncludes(t *testing.T, list []string, item string) {
	t.Helper()
	if !slices.Contains(list, item) {
		t.Fatalf("%v must include %q", list, item)
	}
}
