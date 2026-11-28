/**
 * Metis Workflow Extension
 *
 * Adds tools that let the agent drive Metis workflows from the current chat:
 *
 *   metis_start_workflow  — start a named workflow on a project, seeded with
 *                           this conversation's context
 *   metis_create_workflow — author a new team workflow template (admin only)
 *   metis_update_workflow — edit an existing team workflow template (admin only)
 *   metis_get_workflow    — read a workflow's full step detail (live)
 *   metis_get_project     — read a project's detail + bound resources (live)
 *   metis_list_skills     — list built-in + team skills, with status (live)
 *   metis_propose_skill   — suggest a disabled skill for a recurring task (memory review)
 *   metis_create_skill    — create a team skill from SKILL.md (admin only)
 *   metis_update_skill    — edit a team skill / toggle enabled (admin only)
 *   metis_list_routines   — list the team's routines, with trigger + status (live)
 *   metis_create_routine  — create a scheduled/event routine (admin only)
 *   metis_update_routine  — edit a routine / enable-disable it (admin only)
 *   metis_remember        — record something learned about the operator
 *   metis_update_memory   — revise a memory (content, kind, confidence)
 *   metis_forget          — drop a memory that's wrong or stale
 *   metis_note_applied    — report which memories shaped this reply
 *   metis_note_correction — mark the previous reply as corrected by the operator
 *   metis_memory_report   — how memories fared lately (the nightly review reads it)
 *   metis_list_directions — the operator's directions and their current state
 *   metis_add_direction   — start following something the operator asks for
 *   metis_update_direction — record a direction's current view and open questions
 *   metis_record_hunch    — save finished work the operator will likely need
 *
 * These manage team skills as single SKILL.md rows. Multi-file skills (with
 * supporting assets) still go through the native file path: write
 * .pi/skills/<slug>/ and Metis ingests it at turn end. There is no delete tool.
 *
 * All of these are BIDIRECTIONAL: the tool calls `ctx.ui.input("metis:<op>",
 * <json>)` over pi's Extension UI sub-protocol — the sandbox→host callback
 * channel — which blocks until the Metis host (Agent::HostBridge) does the work
 * and answers with JSON. Reads return data; writes return an { ok, ... } result
 * the agent relays in its reply (including the link). Rails authorizes every op
 * server-side (admin for create/update, membership for start); the sandbox
 * never holds Metis credentials. No HTTP, no token, no egress — it rides pi's
 * RPC transport and works identically across every runtime.
 *
 * Placement:
 *   Project-local: .pi/extensions/metis-workflow/index.ts   ← this file
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
  details?: unknown;
};

function errorResult(text: string, details?: unknown): ToolResult {
  return { content: [{ type: "text", text }], isError: true, details };
}

// Call the Metis host over pi's Extension UI channel (Agent::HostBridge) and
// return the parsed JSON. Sentinels: undefined = host unreachable (no UI in
// this run mode), null = host cancelled / didn't answer.
async function hostCall(
  ctx: ExtensionContext | undefined,
  op: string,
  params: unknown,
): Promise<any | null | undefined> {
  if (!ctx?.hasUI) return undefined;
  const raw = await ctx.ui.input(`metis:${op}`, JSON.stringify(params));
  return raw == null ? null : JSON.parse(raw);
}

// A write op: round-trip to the host, then format the host's { ok, ... } result.
async function hostWrite(
  ctx: ExtensionContext | undefined,
  op: string,
  params: unknown,
  ok: (res: any) => string,
): Promise<ToolResult> {
  const res = await hostCall(ctx, op, params);
  if (res === undefined) return errorResult("Can't reach Metis from this run mode.");
  if (res === null) return errorResult("Metis didn't answer; nothing changed.");
  if (!res.ok) return errorResult(res.error ?? "Metis rejected the request.", res);
  return { content: [{ type: "text", text: ok(res) }], details: res };
}

// Render a workflow fetched from the host (Agent::HostBridge#get_workflow)
// into readable text for the model.
function formatWorkflow(wf: {
  name: string;
  description?: string | null;
  enabled?: boolean;
  default_project?: string | null;
  steps?: Array<{ name?: string; prompt?: string; gate?: string; run?: string }>;
}): string {
  const lines = [`# ${wf.name}${wf.enabled === false ? " (disabled)" : ""}`];
  if (wf.description) lines.push(wf.description);
  if (wf.default_project) lines.push(`Default project: ${wf.default_project}`);
  lines.push("", "Steps:");
  (wf.steps ?? []).forEach((s, i) => {
    const tags = [s.run ?? "cloud", s.gate === "approval" ? "approval gate" : null]
      .filter(Boolean)
      .join(", ");
    lines.push(`${i + 1}. ${s.name ?? "(unnamed)"} (${tags})`);
    if (s.prompt) lines.push(`   ${s.prompt}`);
  });
  return lines.join("\n");
}

// Render a project fetched from the host (Agent::HostBridge#get_project).
function formatProject(p: {
  name: string;
  about?: string | null;
  github_repo?: string | null;
  linear_project?: string | null;
}): string {
  const lines = [`# ${p.name}`];
  if (p.about) lines.push(p.about);
  if (p.github_repo) lines.push(`GitHub repo: ${p.github_repo}`);
  if (p.linear_project) lines.push(`Linear project: ${p.linear_project}`);
  if (!p.github_repo && !p.linear_project) lines.push("(no external resources bound)");
  return lines.join("\n");
}

// Render the skill list fetched from the host (Agent::SkillManager#list).
// status is "built-in" (repo, always active), "enabled", or "disabled" (team).
function formatSkills(
  skills: Array<{ slug: string; description?: string | null; source?: string; status?: string }>,
): string {
  if (skills.length === 0) return "No skills.";
  return skills
    .map((s) => `- ${s.slug} [${s.status ?? s.source}]${s.description ? ` — ${s.description}` : ""}`)
    .join("\n");
}

// Render the routine list fetched from the host (Agent::RoutineManager#list).
function formatRoutines(
  routines: Array<{
    name: string;
    trigger?: string;
    schedule?: string | null;
    event_type?: string | null;
    visibility?: string;
    enabled?: boolean;
  }>,
): string {
  if (routines.length === 0) return "No routines.";
  return routines
    .map((r) => {
      const when = r.trigger === "webhook" ? `on ${r.event_type}` : r.schedule;
      const status = r.enabled === false ? "disabled" : "enabled";
      return `- ${r.name} [${status}] — ${when} (${r.visibility})`;
    })
    .join("\n");
}

// Mirror UserMemory's enums (app/models/user_memory.rb).
const literals = (values: string[], options?: object) => Type.Union(values.map((v) => Type.Literal(v)), options);
const memoryKind = (options?: object) => literals(["preference", "correction", "fact", "goal", "commitment", "experience"], options);
const memorySource = (options?: object) => literals(["stated", "inferred"], options);
const memoryConfidence = (options?: object) => literals(["low", "medium", "high"], options);

const StepSchema = Type.Object({
  name: Type.String({
    description: 'Short step name, e.g. "Implement".',
  }),
  prompt: Type.String({
    description:
      "What the agent should do in this step. Required and non-empty — the " +
      "run's input is restated into every step's prompt.",
  }),
  gate: Type.Optional(
    Type.Union([Type.Literal("auto"), Type.Literal("approval")], {
      description:
        '"approval" pauses the run for a human to approve before the next ' +
        'step; "auto" (default) continues automatically.',
    }),
  ),
  run: Type.Optional(
    Type.Union([Type.Literal("cloud"), Type.Literal("local")], {
      description:
        '"cloud" (default) runs the step as a normal cloud turn; "local" ' +
        "delegates it to the operator's own machine via the bridge.",
    }),
  ),
});

export default function metisWorkflowExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: "metis_start_workflow",
    label: "Start Metis Workflow",
    description:
      "Spin off a new Metis workflow run from this chat. Metis creates a " +
      "separate conversation seeded with this chat's context and QUEUES the " +
      "named workflow — the operator reviews the seeded context and starts it " +
      "themselves. Returns the queued run's link. Use when the operator asks to " +
      "start, kick off, queue, or run a named workflow (e.g. \"start the ship " +
      "workflow on project metis to do this\").",
    promptSnippet: "Start a named Metis workflow run from this chat",
    promptGuidelines: [
      "Use metis_start_workflow only when the operator explicitly asks to start, kick off, or run a named workflow.",
      "Pass `workflow` as the operator named it (e.g. \"ship\"). Pass `project` if they named one; omit it to use this chat's project.",
      "Put a short, self-contained summary of what the run should accomplish — the spec you concluded together — in `note`.",
      "Pass `model` (and optionally `provider`) only if the operator names one to run the workflow on; omit to inherit this chat's model. An unknown model is rejected with the available options.",
      "This returns the result directly. On success, tell the operator the run is queued for their review and give them the returned link to start it. On failure, relay the error.",
    ],
    parameters: Type.Object({
      workflow: Type.String({
        description: "Name of the workflow to run, e.g. \"ship\".",
      }),
      project: Type.Optional(
        Type.String({
          description:
            "Project name to run on, e.g. \"metis\". Omit to use this chat's project.",
        }),
      ),
      note: Type.Optional(
        Type.String({
          description:
            "Short summary of the task/spec for the run to carry into its first step.",
        }),
      ),
      model: Type.Optional(
        Type.String({
          description:
            "Model to run the workflow on (pi model key or its label, e.g. \"anthropic/claude-opus-4-8\"). Omit to inherit this chat's model.",
        }),
      ),
      provider: Type.Optional(
        Type.String({
          description:
            "Provider for the model, only needed to disambiguate when the same model key exists under multiple providers.",
        }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "start_workflow",
        params,
        (r) =>
          `Queued the "${r.workflow}" workflow on ${r.project}` +
          `${r.model ? ` (model: ${r.model})` : ""}. It won't run until ` +
          `the operator reviews the seeded context and starts it: ${r.url}`,
      );
    },
  });

  pi.registerTool({
    name: "metis_create_workflow",
    label: "Create Metis Workflow",
    description:
      "Author a new reusable Metis workflow template for this team. A workflow " +
      "is an ordered list of steps, each with a name and a prompt; a step can " +
      "pause for human approval before the next, or be delegated to the " +
      "operator's machine. Only team admins can author workflows. Use when the " +
      "operator asks to create, define, or set up a new named workflow.",
    promptSnippet: "Create a new Metis workflow template",
    promptGuidelines: [
      "Use metis_create_workflow only when the operator explicitly asks to create or define a new workflow.",
      "Give every step a clear `name` and a self-contained `prompt`. A blank prompt is rejected.",
      "Set `gate: approval` on a step that should pause for a human before the next step runs.",
      "Set `run: local` only when the operator wants that step delegated to their own machine; otherwise omit it (cloud).",
      "Pass `project` only if the operator named a default project for the workflow.",
      "This returns the result directly. On success, confirm it and give the operator the returned link. On failure (e.g. not a team admin), relay the error.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description: 'Name for the new workflow, e.g. "Ship".',
      }),
      description: Type.Optional(
        Type.String({
          description: "Short description of what the workflow does.",
        }),
      ),
      project: Type.Optional(
        Type.String({
          description:
            "Default project name to run this workflow on. Omit if none.",
        }),
      ),
      steps: Type.Array(StepSchema, {
        description: "Ordered steps the run executes, at least one.",
      }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "create_workflow",
        params,
        (r) => `Created the "${r.name}" workflow. Review or edit it: ${r.url}`,
      );
    },
  });

  pi.registerTool({
    name: "metis_update_workflow",
    label: "Update Metis Workflow",
    description:
      "Edit an existing Metis workflow template for this team, found by name. " +
      "Pass only the fields to change: `steps` replaces the whole step list, " +
      "`description` and `project` update those. Only team admins can edit " +
      "workflows. Use when the operator asks to change, edit, or update a " +
      "named workflow.",
    promptSnippet: "Edit an existing Metis workflow template",
    promptGuidelines: [
      "Use metis_update_workflow only when the operator explicitly asks to change an existing workflow.",
      "Identify the workflow by its `name` (case-insensitive). This tool does not rename a workflow.",
      "Pass `steps` only to replace the entire step list — include every step you want kept, in order. Prefer metis_get_workflow first so you resupply the current steps faithfully.",
      "Omit fields you aren't changing; omitted fields are left as they are.",
      "This returns the result directly. On success, confirm it and give the operator the returned link. On failure (e.g. not a team admin, or no such workflow), relay the error.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description:
          'Name of the existing workflow to edit, e.g. "Ship" (case-insensitive).',
      }),
      description: Type.Optional(
        Type.String({ description: "New description, if changing it." }),
      ),
      project: Type.Optional(
        Type.String({
          description: "New default project name, if changing it.",
        }),
      ),
      steps: Type.Optional(
        Type.Array(StepSchema, {
          description:
            "Full replacement step list, in order. Omit to leave steps unchanged.",
        }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "update_workflow",
        params,
        (r) => `Updated the "${r.name}" workflow. Review it: ${r.url}`,
      );
    },
  });

  pi.registerTool({
    name: "metis_get_workflow",
    label: "Get Metis Workflow",
    description:
      "Read a team workflow's full definition by name — every step's name, " +
      "prompt, gate, and run target. Returns live data from Metis. Use when " +
      "the operator asks what a workflow does, or before metis_update_workflow " +
      "so you can resupply its steps faithfully (update replaces the whole list).",
    promptSnippet: "Read a Metis workflow's full step detail",
    promptGuidelines: [
      "Use metis_get_workflow to read a workflow's full steps before describing it or editing it.",
      "Identify the workflow by name (case-insensitive).",
      "Unlike the other metis_* tools, this one returns the data directly — act on its result.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description: 'Workflow name, e.g. "Ship" (case-insensitive).',
      }),
    }),

    // Bidirectional: hostCall round-trips to the Metis host (HostBridge),
    // which returns the workflow as JSON. ctx.hasUI is true in pi's rpc mode
    // (Metis's only mode); the helper degrades elsewhere.
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const { name } = params;
      const wf = await hostCall(ctx, "get_workflow", { name });
      if (wf === undefined) return errorResult("Can't reach Metis from this run mode.");
      if (wf === null) {
        return errorResult(`No workflow named "${name}" on this team (or Metis didn't answer).`);
      }
      return { content: [{ type: "text", text: formatWorkflow(wf) }], details: wf };
    },
  });

  pi.registerTool({
    name: "metis_get_project",
    label: "Get Metis Project",
    description:
      "Read a team project's full detail by name — its description and the " +
      "external resources it's bound to (GitHub repo as owner/name, Linear " +
      "project id). Returns live data from Metis. Use before acting on a " +
      "project's repo or Linear so you target the exact bound identifiers " +
      "instead of guessing from the conversation.",
    promptSnippet: "Read a Metis project's detail and bound resources",
    promptGuidelines: [
      "Use metis_get_project when the operator references a saved project and you need its bound GitHub repo or Linear project to act.",
      "Identify the project by name (case-insensitive).",
      "Prefer the returned github_repo / linear_project over inferring identifiers from the chat.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description: 'Project name, e.g. "Metis" (case-insensitive).',
      }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const { name } = params;
      const project = await hostCall(ctx, "get_project", { name });
      if (project === undefined) return errorResult("Can't reach Metis from this run mode.");
      if (project === null) {
        return errorResult(`No project named "${name}" on this team (or Metis didn't answer).`);
      }
      return { content: [{ type: "text", text: formatProject(project) }], details: project };
    },
  });

  pi.registerTool({
    name: "metis_list_skills",
    label: "List Metis Skills",
    description:
      "List all skills available to this team: the built-in repo skills (always " +
      "active) and the team's DB skills. Each row carries a status — \"built-in\", " +
      "\"enabled\", or \"disabled\". Disabled team skills are NOT staged into the " +
      "workspace, so this is the only way to see them. Use before creating or " +
      "editing a skill.",
    promptSnippet: "List built-in and team skills with status",
    promptGuidelines: [
      "Use metis_list_skills to discover what skills exist — built-in vs team, and which team skills are disabled (those don't appear as files in .pi/skills/).",
      "Built-in skills are read-only. Manage team skills with metis_create_skill / metis_update_skill.",
    ],
    parameters: Type.Object({}),

    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const skills = await hostCall(ctx, "list_skills", {});
      if (skills === undefined) return errorResult("Can't reach Metis from this run mode.");
      if (skills === null) return errorResult("Metis didn't answer.");
      return { content: [{ type: "text", text: formatSkills(skills) }], details: skills };
    },
  });

  pi.registerTool({
    name: "metis_create_skill",
    label: "Create Metis Skill",
    description:
      "Create a new team skill from a single SKILL.md. The content must have " +
      "YAML frontmatter with `name` and `description`, then the markdown body. " +
      "Only team admins can create. For a skill with supporting files, write " +
      ".pi/skills/<slug>/ on disk instead. Use metis_list_skills first to avoid " +
      "a slug collision (built-in slugs are reserved).",
    promptSnippet: "Create a team skill from SKILL.md",
    promptGuidelines: [
      "Use metis_create_skill only when the operator explicitly asks to create or define a new skill.",
      "Pass a kebab-case `slug` and the full SKILL.md `content` (frontmatter name + description, then the body). Omit `enabled` to default it on.",
      "This returns the result directly. On failure (not a team admin, slug taken, or reserved built-in slug), relay the error.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Kebab-case slug, e.g. \"code-review\"." }),
      content: Type.String({ description: "Full SKILL.md content (YAML frontmatter + body)." }),
      enabled: Type.Optional(
        Type.Boolean({ description: "Whether the skill is active. Defaults to true." }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "create_skill",
        params,
        (r) => `Created the "${r.slug}" skill${r.enabled ? "" : " (disabled)"}.`,
      );
    },
  });

  pi.registerTool({
    name: "metis_propose_skill",
    label: "Propose Metis Skill",
    description:
      "Suggest a team skill for a task the operator keeps asking for. It is created " +
      "disabled and only the operator sees it until they enable it. The content must " +
      "have YAML frontmatter with `name` and `description`, then the markdown body.",
    promptSnippet: "Suggest a disabled team skill for a recurring task",
    promptGuidelines: [
      "Use metis_propose_skill only in the nightly memory review, at most once per review, when the report shows the same kind of task coming back.",
      "Check metis_list_skills first and don't propose one that duplicates an existing skill.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Kebab-case slug, e.g. \"weekly-investor-update\"." }),
      content: Type.String({ description: "Full SKILL.md content (YAML frontmatter + body)." }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "propose_skill", params, (r) => `Proposed the "${r.slug}" skill (disabled until the operator enables it).`);
    },
  });

  pi.registerTool({
    name: "metis_update_skill",
    label: "Update Metis Skill",
    description:
      "Edit an existing team skill by slug. Pass `content` to replace its " +
      "SKILL.md, and/or `enabled` to enable/disable it — both optional, so this " +
      "doubles as the enable/disable control. Only team admins can edit. " +
      "Built-in skills can't be edited.",
    promptSnippet: "Edit a team skill or toggle enabled",
    promptGuidelines: [
      "Use metis_update_skill only when the operator explicitly asks to change, enable, or disable an existing team skill.",
      "Identify the skill by its exact slug. Pass `content` only to replace SKILL.md; pass `enabled` only to toggle. Omit what you aren't changing.",
      "This returns the result directly. On failure (not a team admin, or no such team skill), relay the error.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Slug of the team skill to edit." }),
      content: Type.Optional(
        Type.String({ description: "New full SKILL.md content. Omit to leave it unchanged." }),
      ),
      enabled: Type.Optional(
        Type.Boolean({ description: "true to enable, false to disable. Omit to leave unchanged." }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "update_skill",
        params,
        (r) => `Updated the "${r.slug}" skill${r.enabled === false ? " (disabled)" : ""}.`,
      );
    },
  });

  pi.registerTool({
    name: "metis_list_routines",
    label: "List Metis Routines",
    description:
      "List the team's routines — saved prompts that fire on a schedule or a " +
      "webhook event. Each row shows its trigger (cron or event type), " +
      "visibility, and whether it's enabled. Use before creating or editing a " +
      "routine, or when the operator asks what runs automatically.",
    promptSnippet: "List the team's routines with trigger and status",
    promptGuidelines: [
      "Use metis_list_routines to see what routines exist and their triggers before creating or editing one.",
      "This returns the data directly — act on its result.",
    ],
    parameters: Type.Object({}),

    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      const routines = await hostCall(ctx, "list_routines", {});
      if (routines === undefined) return errorResult("Can't reach Metis from this run mode.");
      if (routines === null) return errorResult("Metis didn't answer.");
      return { content: [{ type: "text", text: formatRoutines(routines) }], details: routines };
    },
  });

  pi.registerTool({
    name: "metis_create_routine",
    label: "Create Metis Routine",
    description:
      "Create a routine: a saved prompt that fires on its own, either on a cron " +
      "schedule or when a webhook event arrives. Each fire runs the prompt as a " +
      "normal agent turn (it can use connectors, skills, or start a workflow). " +
      "Anyone can create a personal routine; team routines need a team admin. A new routine starts DISABLED — tell the " +
      "operator to enable it (in the routines UI or with metis_update_routine).",
    promptSnippet: "Create a scheduled or event-driven routine",
    promptGuidelines: [
      "Use metis_create_routine only when the operator explicitly asks to set up something that runs automatically or on a schedule/event.",
      "For a schedule, pass `trigger: \"schedule\"`, a 5-field `cron`, and a `timezone` (IANA, e.g. \"America/New_York\").",
      "For an event, pass `trigger: \"webhook\"` and an `event_type` (e.g. \"pull_request.opened\", or \"pull_request.*\" for a family).",
      "Write a clear, self-contained `prompt`. It may use {{date}}, {{team}}, {{user}}, and on events {{event_type}} / {{event_payload}}.",
      "Pass `model` (and optionally `provider`) only if the operator names one to run the routine on; omit to inherit the deployment default. An unknown model is rejected with the available options.",
      "It starts disabled; on success, tell the operator that and give them the returned link to review and enable it. Relay any error (e.g. a team routine without admin rights, invalid cron).",
    ],
    parameters: Type.Object({
      name: Type.String({ description: 'Name for the routine, e.g. "Morning digest".' }),
      prompt: Type.String({ description: "The instruction the agent runs each time it fires." }),
      trigger: Type.Union([Type.Literal("schedule"), Type.Literal("webhook")], {
        description: '"schedule" for cron, "webhook" for an event trigger.',
      }),
      cron: Type.Optional(
        Type.String({ description: 'A 5-field cron expression, e.g. "0 9 * * *". Required for schedule.' }),
      ),
      timezone: Type.Optional(
        Type.String({ description: 'IANA time zone for the cron, e.g. "America/New_York". Defaults to UTC.' }),
      ),
      event_type: Type.Optional(
        Type.String({ description: 'Webhook event type, e.g. "pull_request.opened" or "pull_request.*". Required for webhook.' }),
      ),
      visibility: Type.Optional(
        Type.Union([Type.Literal("personal"), Type.Literal("team")], {
          description: '"personal" (only the owner sees and manages it and its runs) or "team" (every member sees it; admins manage it). Defaults to personal.',
        }),
      ),
      project: Type.Optional(
        Type.String({ description: "Project name to give the runs repo/standards context. Omit if none." }),
      ),
      cooldown_seconds: Type.Optional(
        Type.Number({ description: "Minimum gap between fires for bursty events. Defaults to 0." }),
      ),
      model: Type.Optional(
        Type.String({
          description:
            "Model each fire runs on (pi model key or its label, e.g. \"anthropic/claude-opus-4-8\"). Omit to inherit the deployment default.",
        }),
      ),
      provider: Type.Optional(
        Type.String({
          description:
            "Provider for the model, only needed to disambiguate when the same model key exists under multiple providers.",
        }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "create_routine",
        params,
        (r) =>
          `Created the "${r.name}" routine${r.enabled ? "" : " (disabled — enable it to start)"}. ` +
          `Review it: ${r.url}`,
      );
    },
  });

  pi.registerTool({
    name: "metis_update_routine",
    label: "Update Metis Routine",
    description:
      "Edit an existing routine, found by name. Pass only the fields to change; " +
      "`enabled` doubles as the enable/disable control. Only team admins can " +
      "edit. Use metis_list_routines first to see what exists.",
    promptSnippet: "Edit a routine or enable/disable it",
    promptGuidelines: [
      "Use metis_update_routine only when the operator explicitly asks to change, enable, or disable an existing routine.",
      "Identify the routine by its `name` (case-insensitive). This tool does not rename it.",
      "Pass only the fields you're changing; omit the rest. Pass `enabled: true` to turn a routine on.",
      "This returns the result directly. Relay any error (e.g. not a team admin, or no such routine).",
    ],
    parameters: Type.Object({
      name: Type.String({ description: "Name of the routine to edit (case-insensitive)." }),
      prompt: Type.Optional(Type.String({ description: "New instruction. Omit to leave unchanged." })),
      trigger: Type.Optional(
        Type.Union([Type.Literal("schedule"), Type.Literal("webhook")], {
          description: "Change the trigger kind. Supply the matching cron/event_type too.",
        }),
      ),
      cron: Type.Optional(Type.String({ description: "New cron expression." })),
      timezone: Type.Optional(Type.String({ description: "New IANA time zone." })),
      event_type: Type.Optional(Type.String({ description: "New webhook event type." })),
      visibility: Type.Optional(
        Type.Union([Type.Literal("personal"), Type.Literal("team")], {
          description: "Move between personal (yours alone) and team (admins only).",
        }),
      ),
      project: Type.Optional(
        Type.String({ description: 'Project name, or "" to unbind it.' }),
      ),
      cooldown_seconds: Type.Optional(Type.Number({ description: "New cooldown in seconds." })),
      model: Type.Optional(
        Type.String({ description: "New model (pi model key or label). Omit to leave unchanged." }),
      ),
      provider: Type.Optional(
        Type.String({ description: "Provider for the model, to disambiguate a key across providers." }),
      ),
      enabled: Type.Optional(
        Type.Boolean({ description: "true to enable, false to disable. Omit to leave unchanged." }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "update_routine",
        params,
        (r) => `Updated the "${r.name}" routine${r.enabled === false ? " (disabled)" : ""}. Review it: ${r.url}`,
      );
    },
  });

  pi.registerTool({
    name: "metis_remember",
    label: "Remember",
    description:
      "Record something you learned about the operator so every future conversation " +
      "in this team can use it. One short fact per memory (max 500 characters).",
    promptSnippet: "Record something learned about the operator",
    promptGuidelines: [
      "Use metis_remember when the operator corrects you, states a preference, shares a lasting fact about their work, sets a goal, or when you promise a follow-up, or notice a pattern in their choices.",
      "Don't record one-off task details, secrets, credentials, or sensitive personal data.",
      "Use source \"stated\" only for what the operator said outright; anything you concluded yourself is \"inferred\", usually at \"low\" confidence.",
      "Check the memories already listed in your context first; update an existing one instead of adding a near-duplicate.",
    ],
    parameters: Type.Object({
      content: Type.String({ description: "The memory, one short fact in plain words, without a subject: \"Co-founded Pipi Hosting\", not \"The operator co-founded…\"." }),
      kind: memoryKind({
        description: "preference (how they like things), correction (something they corrected), fact (about them or their work), goal (something they're pursuing), commitment (a follow-up you promised), experience (a lesson about working with them).",
      }),
      source: Type.Optional(
        memorySource({
          description: "\"stated\" if the operator said it outright, \"inferred\" if you concluded it. Defaults to inferred.",
        }),
      ),
      confidence: Type.Optional(
        memoryConfidence({
          description: "How sure you are. Defaults to high for stated, low for inferred.",
        }),
      ),
      reason: Type.Optional(Type.String({ description: "Why, in one line. Shown to the operator in their memory history." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "remember", params, (r) => `Remembered as #${r.id} (${r.kind}, ${r.source}/${r.confidence}).`);
    },
  });

  pi.registerTool({
    name: "metis_update_memory",
    label: "Update Memory",
    description: "Revise one of your memories about the operator, by id. Pass only what changes.",
    promptSnippet: "Revise a memory about the operator",
    promptGuidelines: [
      "Use metis_update_memory to raise confidence as evidence repeats, to correct a memory, or when the operator's current request shows a memory is out of date.",
      "New wording is a new claim: pass source \"stated\" only if the operator said the new wording outright; otherwise it becomes \"inferred\".",
    ],
    parameters: Type.Object({
      id: Type.Number({ description: "The memory id, as listed in your context." }),
      content: Type.Optional(Type.String({ description: "New wording." })),
      kind: Type.Optional(memoryKind()),
      source: Type.Optional(memorySource({ description: "Only with new content. Defaults to inferred." })),
      confidence: Type.Optional(memoryConfidence()),
      reason: Type.Optional(Type.String({ description: "Why, in one line. Shown to the operator in their memory history." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "update_memory", params, (r) => `Updated memory #${r.id} (${r.kind}, ${r.source}/${r.confidence}).`);
    },
  });

  pi.registerTool({
    name: "metis_forget",
    label: "Forget Memory",
    description: "Delete one of your memories about the operator, by id.",
    promptSnippet: "Forget a memory about the operator",
    promptGuidelines: [
      "Use metis_forget when a memory is wrong or stale, or when the operator asks you to forget something.",
    ],
    parameters: Type.Object({
      id: Type.Number({ description: "The memory id, as listed in your context." }),
      reason: Type.Optional(Type.String({ description: "Why, in one line. Shown to the operator in their memory history." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "forget_memory", params, (r) => `Forgot memory #${r.id}.`);
    },
  });

  pi.registerTool({
    name: "metis_note_applied",
    label: "Note Applied Memories",
    description: "Report which of your memories about the operator shaped this reply.",
    promptSnippet: "Report which memories shaped this reply",
    promptGuidelines: [
      "Call metis_note_applied once per reply that a memory actually shaped, with those memory ids. Skip it when none did.",
    ],
    parameters: Type.Object({
      ids: Type.Array(Type.Number(), { description: "Ids of the memories that shaped this reply." }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "note_memory_applied", params, (r) => `Noted ${r.noted} applied memor${r.noted === 1 ? "y" : "ies"}.`);
    },
  });

  pi.registerTool({
    name: "metis_note_correction",
    label: "Note Correction",
    description: "Mark your previous reply in this conversation as corrected by the operator, with a one-line note of what was wrong.",
    promptSnippet: "Mark the previous reply as corrected",
    promptGuidelines: [
      "Call metis_note_correction when the operator's message corrects, redoes or rejects your previous reply. Not for new requests or follow-up questions.",
    ],
    parameters: Type.Object({
      note: Type.String({ description: "What was wrong with the previous reply, in one line." }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "note_memory_correction", params, () => "Noted the correction.");
    },
  });

  pi.registerTool({
    name: "metis_memory_report",
    label: "Memory Report",
    description:
      "How your memories about the operator fared since the last review: for each memory, " +
      "how many replies used it and how many of those were corrected, cancelled or forked; " +
      "corrections on replies that used no memory; memories the operator edited or deleted; totals.",
    promptSnippet: "See how memories fared since the last review",
    promptGuidelines: [
      "Use metis_memory_report during the nightly memory review, or when the operator asks what you've learned about them.",
      "This returns the data directly — act on its result.",
    ],
    parameters: Type.Object({}),

    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "memory_report", {}, (r) => JSON.stringify(r, null, 2));
    },
  });

  pi.registerTool({
    name: "metis_list_directions",
    label: "List Directions",
    description:
      "The directions the operator asked you to follow, each with its brief, status, your current view, " +
      "open questions and when it was last explored.",
    promptSnippet: "List the operator's directions",
    promptGuidelines: [
      "Use metis_list_directions during a foresight run, or when the operator asks what you're following for them.",
    ],
    parameters: Type.Object({}),

    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "list_directions", {}, (r) => JSON.stringify(r.directions, null, 2));
    },
  });

  pi.registerTool({
    name: "metis_add_direction",
    label: "Add Direction",
    description:
      "Start following something for the operator, like \"keep me current on proactive agents\". " +
      "The nightly foresight run explores it and records hunches from it.",
    promptSnippet: "Follow a topic for the operator",
    promptGuidelines: [
      "Use metis_add_direction only when the operator asks you to follow, track or keep them current on something.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "A short name, e.g. \"Proactive agents\"." }),
      brief: Type.Optional(Type.String({ description: "What to follow and why, in the operator's terms." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "add_direction", params, (r) => `Now following "${r.title}" (#${r.id}).`);
    },
  });

  pi.registerTool({
    name: "metis_update_direction",
    label: "Update Direction",
    description: "Record what you now understand about a direction after exploring it: your current view and open questions.",
    promptSnippet: "Update a direction's view",
    promptGuidelines: [
      "Use metis_update_direction in a foresight run after researching a direction. Rewrite the view in full; it replaces the old one.",
    ],
    parameters: Type.Object({
      id: Type.Number({ description: "The direction id from metis_list_directions." }),
      view: Type.Optional(Type.String({ description: "Your current understanding, a few short paragraphs." })),
      open_questions: Type.Optional(Type.Array(Type.String(), { description: "What's still unclear, up to 10." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "update_direction", params, (r) => `Updated direction #${r.id}.`);
    },
  });

  pi.registerTool({
    name: "metis_record_hunch",
    label: "Record Hunch",
    description:
      "Save a hunch: finished work the operator will probably need soon (a draft, a summary, a review, a plan), " +
      "with why now and the sources behind it. It appears on their Hunches page to continue in chat, mark useful, or dismiss.",
    promptSnippet: "Save finished work the operator will likely need",
    promptGuidelines: [
      "Use metis_record_hunch in a foresight run, at most 3 times, only for work you'd rate at least medium impact and can back with sources.",
      "Put the finished work in body, not a plan to do it.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "What it is, e.g. \"Draft reply to the Acme renewal thread\"." }),
      body: Type.String({ description: "The finished work, in Markdown." }),
      why_now: Type.String({ description: "Why the operator will need this soon." }),
      evidence: Type.Array(
        Type.Object({ title: Type.Optional(Type.String()), url: Type.String() }),
        { description: "Sources behind it, each with a url." },
      ),
      impact: literals(["medium", "high"], { description: "How much it should help." }),
      confidence: literals(["low", "medium", "high"], { description: "How sure you are they'll need it." }),
      direction_id: Type.Optional(Type.Number({ description: "The direction it came from, if any." })),
      memory_id: Type.Optional(Type.Number({ description: "The goal or commitment memory it came from, if any." })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(ctx, "record_hunch", params, (r) => `Recorded hunch #${r.id}.`);
    },
  });
}
