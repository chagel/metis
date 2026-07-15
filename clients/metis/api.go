package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// ErrGone is the server's "stop work now": the run was cancelled or the
// claim was reclaimed — a 410 from events or result.
var ErrGone = errors.New("task is no longer live")

type PriorStep struct {
	Name      string `json:"name"`
	Content   string `json:"content"`
	Artifacts []struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	} `json:"artifacts"`
}

type Task struct {
	TaskID  int64  `json:"task_id"`
	Ref     string `json:"ref"`
	RunID   int64  `json:"run_id"`
	RunRef  string `json:"run_ref"`
	Step    int    `json:"step"`
	Name    string `json:"name"`
	Prompt  string `json:"prompt"`
	Context struct {
		Input   string `json:"input"`
		Project struct {
			Name  string `json:"name"`
			About string `json:"about"`
		} `json:"project"`
		PriorSteps []PriorStep `json:"prior_steps"`
	} `json:"context"`
}

type TaskState struct {
	Status    string `json:"status"`
	ClaimedBy string `json:"claimed_by"`
}

type Artifact map[string]any

// Api is a thin client over one server's bridge REST surface.
type Api struct {
	server *Server
	client string
	http   *http.Client
}

func NewApi(server *Server, client string) *Api {
	return &Api{server: server, client: client, http: &http.Client{Timeout: 30 * time.Second}}
}

// Claim returns nil when the queue is empty for this project (204/409).
func (a *Api) Claim(project string) (*Task, error) {
	resp, err := a.do(http.MethodGet, "/api/bridge/tasks/next?project="+url.QueryEscape(project), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		task := &Task{}
		return task, json.NewDecoder(resp.Body).Decode(task)
	case http.StatusNoContent, http.StatusConflict:
		return nil, nil
	default:
		return nil, statusError(resp)
	}
}

func (a *Api) TaskState(id int64) (*TaskState, error) {
	resp, err := a.do(http.MethodGet, fmt.Sprintf("/api/bridge/tasks/%d", id), nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, statusError(resp)
	}
	state := &TaskState{}
	return state, json.NewDecoder(resp.Body).Decode(state)
}

func (a *Api) Event(id int64, text string) error {
	return a.post(fmt.Sprintf("/api/bridge/tasks/%d/events", id),
		map[string]any{"kind": "log", "text": text})
}

func (a *Api) Result(id int64, status, summary, detail string, artifacts []Artifact, agent, model string) error {
	body := map[string]any{"status": status, "summary": summary}
	if detail != "" {
		body["detail"] = detail
	}
	if len(artifacts) > 0 {
		body["artifacts"] = artifacts
	}
	if agent != "" {
		body["agent"] = agent
	}
	if model != "" {
		body["model"] = model
	}
	return a.post(fmt.Sprintf("/api/bridge/tasks/%d/result", id), body)
}

func (a *Api) post(path string, body map[string]any) error {
	resp, err := a.do(http.MethodPost, path, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	return statusError(resp)
}

func (a *Api) do(method, path string, body map[string]any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, a.server.Server+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.server.Token)
	req.Header.Set("X-Bridge-Client", a.client)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return a.http.Do(req)
}

func statusError(resp *http.Response) error {
	switch resp.StatusCode {
	case http.StatusGone:
		return ErrGone
	case http.StatusUnauthorized:
		return errors.New("bridge token rejected — regenerate it in /settings/account")
	default:
		return fmt.Errorf("%s → HTTP %d", resp.Request.URL.Path, resp.StatusCode)
	}
}
