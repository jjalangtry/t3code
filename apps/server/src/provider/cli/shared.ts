import {
  type CanonicalItemType,
  type ProviderRuntimeEvent,
  type RuntimePlanStepStatus,
  type UserInputQuestion,
} from "@t3tools/contracts";

export const PROPOSED_PLAN_BLOCK_REGEX = /<proposed_plan>\s*([\s\S]*?)\s*<\/proposed_plan>/i;

export function extractProposedPlanMarkdown(text: string | undefined): string | undefined {
  const match = text ? PROPOSED_PLAN_BLOCK_REGEX.exec(text) : null;
  const planMarkdown = match?.[1]?.trim();
  return planMarkdown && planMarkdown.length > 0 ? planMarkdown : undefined;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

export function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

export function asArray(value: unknown): ReadonlyArray<unknown> | undefined {
  return Array.isArray(value) ? value : undefined;
}

export function classifyToolItemType(toolName: string): CanonicalItemType {
  const normalized = toolName.toLowerCase();
  if (
    normalized.includes("bash") ||
    normalized.includes("shell") ||
    normalized.includes("terminal") ||
    normalized.includes("command")
  ) {
    return "command_execution";
  }
  if (
    normalized.includes("edit") ||
    normalized.includes("write") ||
    normalized.includes("delete") ||
    normalized.includes("patch") ||
    normalized.includes("file")
  ) {
    return "file_change";
  }
  if (normalized.includes("mcp")) {
    return "mcp_tool_call";
  }
  if (normalized.includes("search") || normalized.includes("fetch")) {
    return "web_search";
  }
  if (normalized.includes("image")) {
    return "image_view";
  }
  if (normalized.includes("todo") || normalized.includes("plan")) {
    return "plan";
  }
  return "dynamic_tool_call";
}

export function titleForTool(itemType: CanonicalItemType): string {
  switch (itemType) {
    case "command_execution":
      return "Command run";
    case "file_change":
      return "File change";
    case "mcp_tool_call":
      return "MCP tool call";
    case "plan":
      return "Plan";
    default:
      return "Tool call";
  }
}

export function summarizeToolRequest(
  toolName: string,
  input: Record<string, unknown> | undefined,
): string | undefined {
  if (!input) return toolName;
  const commandCandidate = asString(input.command) ?? asString(input.cmd);
  if (commandCandidate && commandCandidate.trim().length > 0) {
    return `${toolName}: ${commandCandidate.trim().slice(0, 400)}`;
  }
  const pathCandidate = asString(input.path) ?? asString(input.file) ?? asString(input.filename);
  if (pathCandidate && pathCandidate.trim().length > 0) {
    return `${toolName}: ${pathCandidate.trim().slice(0, 400)}`;
  }
  const json = JSON.stringify(input);
  return `${toolName}: ${json.length > 400 ? `${json.slice(0, 397)}...` : json}`;
}

export function normalizePlanSteps(
  input: unknown,
): ReadonlyArray<{ readonly step: string; readonly status: RuntimePlanStepStatus }> | undefined {
  const todos = asArray(input);
  if (!todos || todos.length === 0) return undefined;

  const steps = todos
    .map((entry) => {
      if (!isRecord(entry)) return undefined;
      const step =
        asString(entry.content) ??
        asString(entry.step) ??
        asString(entry.title) ??
        asString(entry.name);
      if (!step || step.trim().length === 0) return undefined;
      const statusValue = asString(entry.status)?.toLowerCase();
      const status: RuntimePlanStepStatus =
        statusValue === "completed"
          ? "completed"
          : statusValue === "in_progress" || statusValue === "inprogress"
            ? "inProgress"
            : "pending";
      return {
        step: step.trim(),
        status,
      };
    })
    .filter((entry): entry is NonNullable<typeof entry> => entry !== undefined);

  return steps.length > 0 ? steps : undefined;
}

export function normalizeUserInputQuestions(
  input: unknown,
): ReadonlyArray<UserInputQuestion> | undefined {
  const questions = asArray(input);
  if (!questions || questions.length === 0) return undefined;

  const normalized = questions
    .map((entry, index) => {
      if (!isRecord(entry)) return undefined;
      const id = asString(entry.id) ?? `question_${index + 1}`;
      const header = asString(entry.header) ?? asString(entry.title) ?? `Question ${index + 1}`;
      const question =
        asString(entry.question) ??
        asString(entry.prompt) ??
        asString(entry.label) ??
        asString(entry.text);
      if (!question || question.trim().length === 0) return undefined;

      const options = (asArray(entry.options) ?? [])
        .map((option, optionIndex) => {
          if (!isRecord(option)) return undefined;
          const label =
            asString(option.label) ??
            asString(option.value) ??
            asString(option.name) ??
            `Option ${optionIndex + 1}`;
          const description = asString(option.description) ?? asString(option.detail) ?? label;
          if (label.trim().length === 0 || description.trim().length === 0) {
            return undefined;
          }
          return {
            label: label.trim(),
            description: description.trim(),
          };
        })
        .filter((option): option is NonNullable<typeof option> => option !== undefined);

      return {
        id: id.trim(),
        header: header.trim(),
        question: question.trim(),
        options,
      } satisfies UserInputQuestion;
    })
    .filter((entry): entry is NonNullable<typeof entry> => entry !== undefined);

  return normalized.length > 0 ? normalized : undefined;
}

export function parseNdjsonChunk(
  buffer: string,
  chunk: string,
): {
  readonly nextBuffer: string;
  readonly lines: ReadonlyArray<string>;
} {
  const combined = `${buffer}${chunk}`;
  const parts = combined.split(/\r?\n/);
  const nextBuffer = parts.pop() ?? "";
  const lines = parts.map((line) => line.trim()).filter((line) => line.length > 0);
  return { nextBuffer, lines };
}

export function maybeAppendProposedPlanEvent(
  events: ProviderRuntimeEvent[],
  eventFactory: () => ProviderRuntimeEvent,
  text: string | undefined,
): void {
  const planMarkdown = extractProposedPlanMarkdown(text);
  if (!planMarkdown) return;
  events.push({
    ...eventFactory(),
    type: "turn.proposed.completed",
    payload: {
      planMarkdown,
    },
  });
}
