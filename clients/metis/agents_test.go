package main

import (
	"reflect"
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
	if indexOf(cmd, "--model") < indexOf(cmd, "--permission-mode") {
		t.Fatal("user agent_args must come last so they can override defaults")
	}

	init := agent.Parse(`{"type":"system","subtype":"init","model":"claude-opus-4-8"}`)
	if init.Model != "claude-opus-4-8" {
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
	if !contains(list, item) {
		t.Fatalf("%v must include %q", list, item)
	}
}

func indexOf(list []string, item string) int {
	for i, candidate := range list {
		if candidate == item {
			return i
		}
	}
	return -1
}
