package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// textParts is the content-part array shape shared by claude's and pi's
// message events.
type textParts []struct {
	Text string `json:"text"`
}

func (p textParts) join() string {
	texts := make([]string, 0, len(p))
	for _, part := range p {
		texts = append(texts, part.Text)
	}
	return strings.Join(texts, "")
}

// ParsedEvent is one line of an agent's stream: Text is activity for the
// heartbeat snippet; Final (when HasFinal) is the agent's final message.
type ParsedEvent struct {
	Text     string
	Final    string
	HasFinal bool
	Model    string
}

// Agent is the adapter seam: each coding agent is a command builder plus
// a stream-line parser over its native headless JSON mode. A generic ACP
// adapter joins here the first time an agent without a native stream is
// needed.
type Agent interface {
	Command(prompt string, extraArgs []string) []string
	Parse(line string) ParsedEvent
}

func AgentFor(name string) (Agent, error) {
	switch name {
	case "claude":
		return claudeAgent{}, nil
	case "pi":
		return piAgent{}, nil
	case "codex":
		return codexAgent{}, nil
	default:
		return nil, fmt.Errorf("unknown agent %q (supported: claude, pi, codex)", name)
	}
}

var claudeBlocked = []string{"-p", "--print", "--output-format", "--input-format", "--resume", "--continue", "--session-id"}

type claudeAgent struct{}

// bypassPermissions: the run is unattended — nobody can answer a prompt,
// and acceptEdits alone cannot run the git commands that are the job
// (dogfooded). Tighten per-deployment via agent_args (later flags win).
// --strict-mcp-config: the inner agent must not inherit the user's own
// MCP servers — dogfooding surfaced it discovering the user's production
// Metis bridge tools.
func (claudeAgent) Command(prompt string, extraArgs []string) []string {
	return append([]string{"claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
		"--permission-mode", "bypassPermissions", "--strict-mcp-config"},
		filterArgs(extraArgs, claudeBlocked)...)
}

// stream-json: {"type":"assistant",...} carries turn text;
// {"type":"result","result":"…"} is the final message.
func (claudeAgent) Parse(line string) ParsedEvent {
	var event struct {
		Type    string `json:"type"`
		Result  string `json:"result"`
		Model   string `json:"model"`
		Message struct {
			Model   string    `json:"model"`
			Content textParts `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ParsedEvent{}
	}
	switch event.Type {
	case "system":
		return ParsedEvent{Model: event.Model}
	case "assistant":
		return ParsedEvent{Text: event.Message.Content.join(), Model: event.Message.Model}
	case "result":
		return ParsedEvent{Text: event.Result, Final: event.Result, HasFinal: true}
	default:
		return ParsedEvent{}
	}
}

var piBlocked = []string{"-p", "--print", "--mode", "--session", "--session-id", "--continue", "-c", "--resume", "-r", "--fork"}

type piAgent struct{}

func (piAgent) Command(prompt string, extraArgs []string) []string {
	args := append([]string{"pi", "-p", "--mode", "json"}, filterArgs(extraArgs, piBlocked)...)
	return append(args, prompt)
}

// --mode json: one event per line; an assistant message_end carries that
// turn's full text — the last one is the final message.
func (piAgent) Parse(line string) ParsedEvent {
	var event struct {
		Type    string `json:"type"`
		Message struct {
			Role     string    `json:"role"`
			Provider string    `json:"provider"`
			Model    string    `json:"model"`
			Content  textParts `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ParsedEvent{}
	}
	if event.Type != "message_end" || event.Message.Role != "assistant" {
		return ParsedEvent{}
	}
	text := event.Message.Content.join()
	model := event.Message.Model
	if model != "" && event.Message.Provider != "" {
		model = event.Message.Provider + "/" + model
	}
	return ParsedEvent{Text: text, Final: text, HasFinal: true, Model: model}
}

var codexBlocked = []string{"--json", "--output-schema", "--skip-git-repo-check", "-C", "--cd", "resume"}

type codexAgent struct{}

// --skip-git-repo-check: a fresh worktree path is never in codex's
// trusted-directory list, and exec mode has no way to answer the trust
// prompt.
func (codexAgent) Command(prompt string, extraArgs []string) []string {
	args := append([]string{"codex", "exec", "--json", "--full-auto", "--skip-git-repo-check"},
		filterArgs(extraArgs, codexBlocked)...)
	return append(args, prompt)
}

// exec --json: one event per line; item.completed/agent_message carries
// that turn's text — the last one is the final message.
func (codexAgent) Parse(line string) ParsedEvent {
	var event struct {
		Type string `json:"type"`
		Item struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"item"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ParsedEvent{}
	}
	if event.Type != "item.completed" {
		return ParsedEvent{}
	}
	if event.Item.Type == "agent_message" {
		return ParsedEvent{Text: event.Item.Text, Final: event.Item.Text, HasFinal: true}
	}
	return ParsedEvent{Text: event.Item.Text}
}

// filterArgs strips user-supplied flags that would break the stream
// protocol or leak into another session. A blocked flag also drops its
// value ("--flag value" and "--flag=value" forms).
func filterArgs(args, blocked []string) []string {
	kept := []string{}
	skipValue := false
	for _, arg := range args {
		if skipValue {
			skipValue = false
			continue
		}
		flag, _, hasValue := strings.Cut(arg, "=")
		if slices.Contains(blocked, flag) {
			skipValue = !hasValue
			continue
		}
		kept = append(kept, arg)
	}
	return kept
}
