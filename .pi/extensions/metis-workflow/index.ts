/**
 * Metis Workflow Extension
 *
 * Adds tools that let the agent drive Metis workflows from the current chat:
 *
 *   metis_start_workflow  — start a named workflow on a project, seeded with
 *                           this conversation's context
 *   metis_create_workflow — author a new team workflow template (admin only)
 *   metis_update_workflow — edit an existing team workflow template (admin only)
 *
 * How it works: each tool itself only returns an acknowledgement. Metis is
 * watching the turn's event stream (ChatJob) and, when it sees one of these
 * tool calls, acts server-side — resolving/validating and persisting, then
 * posting a note back into the chat (Agent::WorkflowHandoff for runs,
 * Agent::WorkflowAuthoring for templates). The agent cannot see the outcome
 * from here; Metis's posted note is the source of truth.
 *
 * Placement:
 *   Project-local: .pi/extensions/metis-workflow/index.ts   ← this file
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

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
      "themselves. Use when the operator asks to start, kick off, queue, or run " +
      "a named workflow (e.g. \"start the ship workflow on project metis to do this\").",
    promptSnippet: "Start a named Metis workflow run from this chat",
    promptGuidelines: [
      "Use metis_start_workflow only when the operator explicitly asks to start, kick off, or run a named workflow.",
      "Pass `workflow` as the operator named it (e.g. \"ship\"). Pass `project` if they named one; omit it to use this chat's project.",
      "Put a short, self-contained summary of what the run should accomplish — the spec you concluded together — in `note`.",
      "This queues a separate run you cannot observe from here. After calling it, tell the operator the run is queued for their review and to follow the link Metis posts into the chat to start it.",
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

    async execute(_toolCallId, params) {
      const { workflow, project } = params;
      const where = project ? ` on project ${project}` : "";
      return {
        content: [
          {
            type: "text",
            text:
              `Requested a "${workflow}" workflow run${where}. Metis is creating ` +
              `the run from this chat's context and will queue it, then post a link ` +
              `here. It won't start until the operator reviews and starts it — let ` +
              `them know it's queued for their review.`,
          },
        ],
        details: { workflow, project: project ?? null },
      };
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
      "This authors the template server-side; you cannot see the result. After calling it, tell the operator Metis will post a link to review and edit it, and that it requires team-admin rights.",
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

    async execute(_toolCallId, params) {
      const { name } = params;
      return {
        content: [
          {
            type: "text",
            text:
              `Requested a new "${name}" workflow. Metis is validating and ` +
              `saving it, then will post a link here to review and edit it. ` +
              `It won't appear if you lack team-admin rights — let the operator know.`,
          },
        ],
        details: { name },
      };
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
      "Pass `steps` only to replace the entire step list — include every step you want kept, in order.",
      "Omit fields you aren't changing; omitted fields are left as they are.",
      "This edits the template server-side; you cannot see the result. After calling it, tell the operator Metis will post a link to review it, and that it requires team-admin rights.",
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

    async execute(_toolCallId, params) {
      const { name } = params;
      return {
        content: [
          {
            type: "text",
            text:
              `Requested an edit to the "${name}" workflow. Metis is validating ` +
              `and saving it, then will post a link here to review it. It won't ` +
              `change if you lack team-admin rights or no such workflow exists — ` +
              `let the operator know.`,
          },
        ],
        details: { name },
      };
    },
  });
}
