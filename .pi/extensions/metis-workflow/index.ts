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
 *   metis_list_skills     — list team skills incl. disabled ones (live)
 *   metis_set_skill_enabled — enable/disable a team skill (admin only)
 *   metis_delete_skill    — delete a team skill row (admin only)
 *
 * Creating/editing skills is NOT here — that stays on the native file path
 * (write .pi/skills/<slug>/SKILL.md; Metis ingests it at turn end). These tools
 * only cover the DB-only operations files can't express.
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

// Render the team skill list fetched from the host (Agent::SkillManager#list).
function formatSkills(
  skills: Array<{ slug: string; description?: string | null; enabled?: boolean }>,
): string {
  if (skills.length === 0) return "No team skills.";
  return skills
    .map((s) => `- ${s.slug}${s.enabled === false ? " (disabled)" : ""}${s.description ? ` — ${s.description}` : ""}`)
    .join("\n");
}

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
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "start_workflow",
        params,
        (r) =>
          `Queued the "${r.workflow}" workflow on ${r.project}. It won't run until ` +
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
      "List this team's skills, including disabled ones (which are NOT staged " +
      "into the workspace, so you can't see them as files). Returns each skill's " +
      "slug, description, and enabled state. Use to see what skills exist before " +
      "enabling, disabling, or deleting one.",
    promptSnippet: "List the team's skills (including disabled)",
    promptGuidelines: [
      "Use metis_list_skills to discover team skills — especially disabled ones, which don't appear as files in .pi/skills/.",
      "To create or edit a skill, write .pi/skills/<slug>/SKILL.md instead — that's the native path; these tools are only for listing and DB-only changes.",
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
    name: "metis_set_skill_enabled",
    label: "Enable/Disable Metis Skill",
    description:
      "Enable or disable a team skill by slug. A disabled skill is not staged " +
      "into the workspace and pi won't auto-discover it. Only team admins can " +
      "do this. Use metis_list_skills first to find the slug and current state.",
    promptSnippet: "Enable or disable a team skill",
    promptGuidelines: [
      "Use metis_set_skill_enabled only when the operator explicitly asks to enable, disable, turn on, or turn off a named skill.",
      "Identify the skill by its exact slug (kebab-case). Pass enabled: true to enable, false to disable.",
      "This returns the result directly. On failure (e.g. not a team admin, or no such skill), relay the error.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Skill slug, e.g. \"code-review\"." }),
      enabled: Type.Boolean({ description: "true to enable, false to disable." }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "set_skill_enabled",
        params,
        (r) => `Skill "${r.slug}" is now ${r.enabled ? "enabled" : "disabled"}.`,
      );
    },
  });

  pi.registerTool({
    name: "metis_delete_skill",
    label: "Delete Metis Skill",
    description:
      "Permanently delete a team skill (the DB row and its files) by slug. " +
      "Removing files from the workspace does NOT delete a skill — only this " +
      "does. Only team admins can delete. This cannot be undone.",
    promptSnippet: "Delete a team skill",
    promptGuidelines: [
      "Use metis_delete_skill only when the operator explicitly asks to delete or remove a named skill. Confirm the slug first — deletion is permanent.",
      "Identify the skill by its exact slug (kebab-case).",
      "This returns the result directly. On failure (e.g. not a team admin, or no such skill), relay the error.",
    ],
    parameters: Type.Object({
      slug: Type.String({ description: "Skill slug to delete, e.g. \"code-review\"." }),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return hostWrite(
        ctx,
        "delete_skill",
        params,
        (r) => `Deleted the "${r.slug}" skill.`,
      );
    },
  });
}
