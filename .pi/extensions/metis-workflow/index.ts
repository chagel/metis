/**
 * Metis Workflow Extension
 *
 * Adds one tool that lets the agent spin off a Metis workflow run from the
 * current chat:
 *
 *   metis_start_workflow — start a named workflow on a project, seeded with
 *                          this conversation's context
 *
 * How it works: the tool itself only returns an acknowledgement. Metis is
 * watching the turn's event stream (ChatJob) and, when it sees this tool call,
 * acts server-side — it resolves the workflow + project, creates a new
 * conversation + WorkflowRun, seeds the run with this chat's transcript, and
 * posts a link back into the chat (Agent::WorkflowHandoff). The agent cannot
 * see the run's outcome from here; Metis's posted note is the source of truth.
 *
 * Placement:
 *   Project-local: .pi/extensions/metis-workflow/index.ts   ← this file
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function metisWorkflowExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: "metis_start_workflow",
    label: "Start Metis Workflow",
    description:
      "Spin off a new Metis workflow run from this chat. Metis creates a " +
      "separate conversation, seeds it with this chat's context, and runs the " +
      "named workflow's steps independently. Use when the operator asks to " +
      "start, kick off, or run a named workflow (e.g. \"start the ship workflow " +
      "on project metis to do this\").",
    promptSnippet: "Start a named Metis workflow run from this chat",
    promptGuidelines: [
      "Use metis_start_workflow only when the operator explicitly asks to start, kick off, or run a named workflow.",
      "Pass `workflow` as the operator named it (e.g. \"ship\"). Pass `project` if they named one; omit it to use this chat's project.",
      "Put a short, self-contained summary of what the run should accomplish — the spec you concluded together — in `note`.",
      "This hands off to a separate run you cannot observe from here. After calling it, tell the operator the run has started and to follow the link Metis posts into the chat.",
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
              `the run from this chat's context and will post a link to it here. ` +
              `You can't follow its progress from this chat — let the operator ` +
              `know it has started.`,
          },
        ],
        details: { workflow, project: project ?? null },
      };
    },
  });
}
