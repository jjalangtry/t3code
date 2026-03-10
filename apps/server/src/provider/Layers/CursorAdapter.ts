/**
 * CursorAdapterLive - Cursor CLI-backed provider adapter.
 *
 * Executes Cursor turns through `agent --print --output-format stream-json`
 * and projects the streamed CLI events into canonical provider runtime events.
 *
 * This implementation mirrors the Claude CLI adapter pattern: per-turn subprocess,
 * NDJSON stream parsing, local turn journaling, and canonical event emission.
 *
 * @module CursorAdapterLive
 */
import {
  type CanonicalItemType,
  EventId,
  type ProviderRuntimeEvent,
  type ProviderRuntimeTurnStatus,
  type ProviderSendTurnInput,
  type ProviderSession,
  type TurnId,
  ProviderItemId,
  RuntimeItemId,
  RuntimeRequestId,
  ThreadId,
  TurnId as TurnIdBrand,
} from "@t3tools/contracts";
import { Effect, Layer, Queue, Stream } from "effect";
import { spawn } from "node:child_process";

import {
  ProviderAdapterProcessError,
  ProviderAdapterRequestError,
  ProviderAdapterSessionClosedError,
  ProviderAdapterSessionNotFoundError,
  ProviderAdapterValidationError,
  type ProviderAdapterError,
} from "../Errors.ts";
import { CursorAdapter, type CursorAdapterShape } from "../Services/CursorAdapter.ts";
import { type EventNdjsonLogger, makeEventNdjsonLogger } from "./EventNdjsonLogger.ts";
import {
  asArray,
  asNumber,
  asString,
  classifyToolItemType,
  extractProposedPlanMarkdown,
  isRecord,
  normalizePlanSteps,
  normalizeUserInputQuestions,
  parseNdjsonChunk,
  summarizeToolRequest,
  titleForTool,
} from "../cli/shared.ts";

const PROVIDER = "cursor" as const;
// ── Types ──────────────────────────────────────────────────────────

interface CursorCliTurnProcess {
  readonly pid?: number;
  readonly stdout: NodeJS.ReadableStream;
  readonly stderr: NodeJS.ReadableStream;
  kill(signal?: NodeJS.Signals | number): void;
  on(event: "exit", listener: (code: number | null, signal: NodeJS.Signals | null) => void): this;
}

interface CursorToolInFlight {
  readonly index: number;
  readonly itemId: string;
  readonly itemType: CanonicalItemType;
  readonly toolName: string;
  readonly detail?: string;
}

interface CursorTurnState {
  readonly turnId: TurnId;
  assistantItemId: string;
  readonly startedAt: string;
  readonly child: CursorCliTurnProcess;
  readonly items: Array<unknown>;
  readonly inFlightTools: Map<number, CursorToolInFlight>;
  assistantText: string;
  emittedTextDelta: boolean;
  messageCompleted: boolean;
  interruptRequested: boolean;
  completed: boolean;
}

interface CursorSessionContext {
  session: ProviderSession;
  readonly binaryPath: string;
  readonly turns: Array<{
    readonly id: TurnId;
    readonly items: Array<unknown>;
  }>;
  turnState: CursorTurnState | undefined;
  providerThreadId: string | undefined;
  lastAssistantMessageId: string | undefined;
  stopped: boolean;
}

export interface CursorAdapterLiveOptions {
  readonly nativeEventLogPath?: string;
  readonly nativeEventLogger?: EventNdjsonLogger;
  readonly spawnTurnProcess?: (input: {
    readonly binaryPath: string;
    readonly args: ReadonlyArray<string>;
    readonly cwd?: string;
    readonly env: NodeJS.ProcessEnv;
  }) => CursorCliTurnProcess;
}

// ── Helpers ────────────────────────────────────────────────────────

function nowIso(): string {
  return new Date().toISOString();
}

function nextEventId() {
  return EventId.makeUnsafe(crypto.randomUUID());
}

function asRuntimeItemId(value: string): RuntimeItemId {
  return RuntimeItemId.makeUnsafe(value);
}

function toMessage(cause: unknown, fallback: string): string {
  if (cause instanceof Error && cause.message.length > 0) {
    return cause.message;
  }
  return fallback;
}

function buildUserPrompt(input: ProviderSendTurnInput): string {
  const fragments: string[] = [];
  if (input.input && input.input.trim().length > 0) {
    fragments.push(input.input.trim());
  }
  for (const attachment of input.attachments ?? []) {
    if (attachment.type === "image") {
      fragments.push(
        `Attached image: ${attachment.name} (${attachment.mimeType}, ${attachment.sizeBytes} bytes).`,
      );
    }
  }
  return fragments.join("\n\n");
}

function readCursorResumeState(resumeCursor: unknown): {
  readonly resume?: string;
  readonly turnCount?: number;
} {
  if (!isRecord(resumeCursor)) {
    return {};
  }
  const resume = asString(resumeCursor.resume) ?? asString(resumeCursor.sessionId);
  const turnCount = asNumber(resumeCursor.turnCount);
  return {
    ...(resume ? { resume } : {}),
    ...(turnCount !== undefined && Number.isInteger(turnCount) && turnCount >= 0
      ? { turnCount }
      : {}),
  };
}

function turnStatusFromCursorResult(line: Record<string, unknown>): ProviderRuntimeTurnStatus {
  const subtype = asString(line.subtype);
  if (subtype === "success") {
    return "completed";
  }
  const errors = `${asString(line.result) ?? ""} ${JSON.stringify(line.errors ?? [])}`.toLowerCase();
  if (errors.includes("interrupt")) {
    return "interrupted";
  }
  if (errors.includes("cancel")) {
    return "cancelled";
  }
  return "failed";
}

function extractAssistantText(message: Record<string, unknown>): string {
  const content = asArray(message.content);
  if (!content) return "";
  const fragments: string[] = [];
  for (const entry of content) {
    if (!isRecord(entry)) continue;
    if (entry.type === "text" && typeof entry.text === "string") {
      fragments.push(entry.text);
    }
  }
  return fragments.join("");
}

function spawnCursorTurnProcess(input: {
  readonly binaryPath: string;
  readonly args: ReadonlyArray<string>;
  readonly cwd?: string;
  readonly env: NodeJS.ProcessEnv;
}): CursorCliTurnProcess {
  const child = spawn(input.binaryPath, [...input.args], {
    cwd: input.cwd,
    env: input.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return child as unknown as CursorCliTurnProcess;
}

// ── Adapter implementation ─────────────────────────────────────────

function makeCursorAdapter(options?: CursorAdapterLiveOptions) {
  return Effect.gen(function* () {
    const nativeEventLogger =
      options?.nativeEventLogger ??
      (options?.nativeEventLogPath !== undefined
        ? yield* makeEventNdjsonLogger(options.nativeEventLogPath, {
            stream: "native",
          })
        : undefined);
    const spawnTurn = options?.spawnTurnProcess ?? spawnCursorTurnProcess;

    const sessions = new Map<ThreadId, CursorSessionContext>();
    const runtimeEventQueue = yield* Queue.unbounded<ProviderRuntimeEvent>();

    const offerRuntimeEvent = (event: ProviderRuntimeEvent): void => {
      void Effect.runFork(Queue.offer(runtimeEventQueue, event).pipe(Effect.asVoid));
    };

    const logNativeLine = (
      context: CursorSessionContext,
      turnId: TurnId | undefined,
      method: string,
      payload: unknown,
    ): void => {
      if (!nativeEventLogger) return;
      void Effect.runFork(
        nativeEventLogger.write(
          {
            observedAt: nowIso(),
            event: {
              id: crypto.randomUUID(),
              kind: "notification",
              provider: PROVIDER,
              createdAt: nowIso(),
              method,
              ...(context.providerThreadId ? { providerThreadId: context.providerThreadId } : {}),
              ...(turnId ? { turnId } : {}),
              payload,
            },
          },
          null,
        ),
      );
    };

    const emitRuntimeError = (
      context: CursorSessionContext,
      message: string,
      extra?: {
        readonly turnId?: TurnId | undefined;
        readonly detail?: unknown;
      },
    ): void => {
      offerRuntimeEvent({
        type: "runtime.error",
        eventId: nextEventId(),
        provider: PROVIDER,
        createdAt: nowIso(),
        threadId: context.session.threadId,
        ...(extra?.turnId ? { turnId: extra.turnId } : {}),
        payload: {
          class: "provider_error",
          message,
          ...(extra?.detail !== undefined ? { detail: extra.detail } : {}),
        },
      });
    };

    const emitRuntimeWarning = (
      context: CursorSessionContext,
      message: string,
      detail?: unknown,
    ): void => {
      offerRuntimeEvent({
        type: "runtime.warning",
        eventId: nextEventId(),
        provider: PROVIDER,
        createdAt: nowIso(),
        threadId: context.session.threadId,
        ...(context.turnState ? { turnId: context.turnState.turnId } : {}),
        payload: {
          message,
          ...(detail !== undefined ? { detail } : {}),
        },
      });
    };

    const snapshotThread = (context: CursorSessionContext) => ({
      threadId: context.session.threadId,
      turns: context.turns.map((turn) => ({
        id: turn.id,
        items: [...turn.items],
      })),
    });

    const updateSessionReady = (
      context: CursorSessionContext,
      opts?: { readonly lastError?: string },
    ): void => {
      const turnCount = context.turns.length;
      context.session = {
        ...context.session,
        status: "ready",
        activeTurnId: undefined,
        updatedAt: nowIso(),
        ...(context.providerThreadId
          ? {
              resumeCursor: {
                threadId: context.session.threadId,
                resume: context.providerThreadId,
                ...(context.lastAssistantMessageId
                  ? { resumeSessionAt: context.lastAssistantMessageId }
                  : {}),
                turnCount,
              },
            }
          : {}),
        ...(opts?.lastError ? { lastError: opts.lastError } : {}),
      };
    };

    const completeTurn = (
      context: CursorSessionContext,
      status: ProviderRuntimeTurnStatus,
      resultLine?: Record<string, unknown>,
      errorMessage?: string,
    ): void => {
      const turnState = context.turnState;
      if (!turnState || turnState.completed) return;
      turnState.completed = true;

      if (turnState.assistantText.length > 0 && !turnState.messageCompleted) {
        offerRuntimeEvent({
          type: "item.completed",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId: turnState.turnId,
          itemId: asRuntimeItemId(turnState.assistantItemId),
          payload: {
            itemType: "assistant_message",
            status: "completed",
            title: "Assistant message",
          },
          providerRefs: {
            providerTurnId: String(turnState.turnId),
            providerItemId: ProviderItemId.makeUnsafe(turnState.assistantItemId),
          },
        });
      }

      context.turns.push({
        id: turnState.turnId,
        items: [...turnState.items],
      });
      updateSessionReady(context, {
        ...(status === "failed" && errorMessage ? { lastError: errorMessage } : {}),
      });

      offerRuntimeEvent({
        type: "turn.completed",
        eventId: nextEventId(),
        provider: PROVIDER,
        createdAt: nowIso(),
        threadId: context.session.threadId,
        turnId: turnState.turnId,
        payload: {
          state: status,
          ...(asString(resultLine?.stop_reason) ? { stopReason: asString(resultLine?.stop_reason) } : {}),
          ...(resultLine?.usage !== undefined ? { usage: resultLine.usage } : {}),
          ...(isRecord(resultLine?.modelUsage) ? { modelUsage: resultLine.modelUsage } : {}),
          ...(typeof resultLine?.total_cost_usd === "number"
            ? { totalCostUsd: resultLine.total_cost_usd }
            : {}),
          ...(errorMessage ? { errorMessage } : {}),
        },
        providerRefs: {
          providerTurnId: String(turnState.turnId),
        },
      });

      const proposedPlanMarkdown = extractProposedPlanMarkdown(turnState.assistantText);
      if (proposedPlanMarkdown) {
        offerRuntimeEvent({
          type: "turn.proposed.completed",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId: turnState.turnId,
          payload: {
            planMarkdown: proposedPlanMarkdown,
          },
          providerRefs: {
            providerTurnId: String(turnState.turnId),
          },
        });
      }

      context.turnState = undefined;
    };

    const ensureProviderThreadId = (context: CursorSessionContext, sessionId: string | undefined): void => {
      if (!sessionId || context.providerThreadId === sessionId) return;
      context.providerThreadId = sessionId;
      context.session = {
        ...context.session,
        resumeCursor: {
          threadId: context.session.threadId,
          resume: sessionId,
          ...(context.lastAssistantMessageId ? { resumeSessionAt: context.lastAssistantMessageId } : {}),
          turnCount: context.turns.length,
        },
        updatedAt: nowIso(),
      };
      offerRuntimeEvent({
        type: "thread.started",
        eventId: nextEventId(),
        provider: PROVIDER,
        createdAt: nowIso(),
        threadId: context.session.threadId,
        ...(context.turnState ? { turnId: context.turnState.turnId } : {}),
        payload: {
          providerThreadId: sessionId,
        },
      });
    };

    const handleToolStart = (
      context: CursorSessionContext,
      toolIndex: number,
      block: Record<string, unknown>,
    ): void => {
      const turnState = context.turnState;
      if (!turnState) return;
      const toolName = asString(block.name) ?? "Tool";
      const itemType = classifyToolItemType(toolName);
      const input = isRecord(block.input) ? block.input : undefined;
      const itemId = asString(block.id) ?? crypto.randomUUID();
      const detail = summarizeToolRequest(toolName, input);
      const inFlight: CursorToolInFlight = {
        index: toolIndex,
        itemId,
        itemType,
        toolName,
        ...(detail ? { detail } : {}),
      };
      turnState.inFlightTools.set(toolIndex, inFlight);
      offerRuntimeEvent({
        type: "item.started",
        eventId: nextEventId(),
        provider: PROVIDER,
        createdAt: nowIso(),
        threadId: context.session.threadId,
        turnId: turnState.turnId,
        itemId: asRuntimeItemId(itemId),
        payload: {
          itemType,
          status: "inProgress",
          title: titleForTool(itemType),
          ...(detail ? { detail } : {}),
          ...(input ? { data: { toolName, input } } : {}),
        },
        providerRefs: {
          providerTurnId: String(turnState.turnId),
          providerItemId: ProviderItemId.makeUnsafe(itemId),
        },
      });

      const plan = normalizePlanSteps(input?.todos);
      if (plan) {
        offerRuntimeEvent({
          type: "turn.plan.updated",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId: turnState.turnId,
          payload: {
            plan: [...plan],
          },
          providerRefs: {
            providerTurnId: String(turnState.turnId),
          },
        });
      }

      const questions = normalizeUserInputQuestions(input?.questions);
      if (questions) {
        const requestId = RuntimeRequestId.makeUnsafe(crypto.randomUUID());
        offerRuntimeEvent({
          type: "user-input.requested",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId: turnState.turnId,
          requestId,
          payload: {
            questions: [...questions],
          },
          providerRefs: {
            providerTurnId: String(turnState.turnId),
            providerRequestId: String(requestId),
          },
        });
      }
    };

    const handleCliMessage = (context: CursorSessionContext, line: Record<string, unknown>): void => {
      const messageType = asString(line.type) ?? "unknown";
      const turnId = context.turnState?.turnId;
      logNativeLine(context, turnId, `cursor.cli/${messageType}`, line);

      ensureProviderThreadId(context, asString(line.session_id) ?? asString(line.conversation_id));

      if (messageType === "system") {
        const subtype = asString(line.subtype);
        if (subtype === "init") {
          offerRuntimeEvent({
            type: "session.configured",
            eventId: nextEventId(),
            provider: PROVIDER,
            createdAt: nowIso(),
            threadId: context.session.threadId,
            payload: {
              config: line,
            },
          });
        }
        return;
      }

      if (messageType === "stream_event") {
        const event = isRecord(line.event) ? line.event : undefined;
        const eventType = asString(event?.type);
        if (!event || !eventType) return;

        if (eventType === "content_block_start") {
          const block = isRecord(event.content_block) ? event.content_block : undefined;
          if (
            block &&
            (block.type === "tool_use" || block.type === "server_tool_use" || block.type === "mcp_tool_use")
          ) {
            handleToolStart(context, asNumber(event.index) ?? 0, block);
          }
          return;
        }

        if (eventType === "content_block_stop") {
          const turnState = context.turnState;
          if (!turnState) return;
          const tool = turnState.inFlightTools.get(asNumber(event.index) ?? -1);
          if (!tool) return;
          turnState.inFlightTools.delete(tool.index);
          offerRuntimeEvent({
            type: "item.completed",
            eventId: nextEventId(),
            provider: PROVIDER,
            createdAt: nowIso(),
            threadId: context.session.threadId,
            turnId: turnState.turnId,
            itemId: asRuntimeItemId(tool.itemId),
            payload: {
              itemType: tool.itemType,
              status: "completed",
              title: titleForTool(tool.itemType),
              ...(tool.detail ? { detail: tool.detail } : {}),
            },
            providerRefs: {
              providerTurnId: String(turnState.turnId),
              providerItemId: ProviderItemId.makeUnsafe(tool.itemId),
            },
          });
          return;
        }

        if (eventType === "content_block_delta") {
          const turnState = context.turnState;
          const delta = isRecord(event.delta) ? event.delta : undefined;
          const text = asString(delta?.text);
          if (!turnState || !text || text.length === 0) return;
          turnState.assistantText += text;
          turnState.emittedTextDelta = true;
          offerRuntimeEvent({
            type: "content.delta",
            eventId: nextEventId(),
            provider: PROVIDER,
            createdAt: nowIso(),
            threadId: context.session.threadId,
            turnId: turnState.turnId,
            itemId: asRuntimeItemId(turnState.assistantItemId),
            payload: {
              streamKind:
                asString(delta?.type)?.includes("thinking") === true
                  ? "reasoning_text"
                  : "assistant_text",
              delta: text,
            },
            providerRefs: {
              providerTurnId: String(turnState.turnId),
              providerItemId: ProviderItemId.makeUnsafe(turnState.assistantItemId),
            },
          });
          return;
        }

        if (eventType === "message_delta" && event.usage !== undefined) {
          offerRuntimeEvent({
            type: "thread.token-usage.updated",
            eventId: nextEventId(),
            provider: PROVIDER,
            createdAt: nowIso(),
            threadId: context.session.threadId,
            ...(context.turnState ? { turnId: context.turnState.turnId } : {}),
            payload: {
              usage: event.usage,
            },
          });
        }
        return;
      }

      if (messageType === "assistant") {
        const turnState = context.turnState;
        const message = isRecord(line.message) ? line.message : undefined;
        if (!turnState || !message) return;
        const messageId = asString(message.id);
        if (messageId && turnState.assistantItemId !== messageId) {
          turnState.assistantItemId = messageId;
        }
        turnState.items.push(message);
        const assistantText = extractAssistantText(message);
        if (assistantText.length > 0) {
          const previousText = turnState.assistantText;
          turnState.assistantText = assistantText;

          const delta = assistantText.startsWith(previousText)
            ? assistantText.slice(previousText.length)
            : assistantText;
          if (delta.length > 0) {
            turnState.emittedTextDelta = true;
            offerRuntimeEvent({
              type: "content.delta",
              eventId: nextEventId(),
              provider: PROVIDER,
              createdAt: nowIso(),
              threadId: context.session.threadId,
              turnId: turnState.turnId,
              itemId: asRuntimeItemId(turnState.assistantItemId),
              payload: {
                streamKind: "assistant_text",
                delta,
              },
              providerRefs: {
                providerTurnId: String(turnState.turnId),
                providerItemId: ProviderItemId.makeUnsafe(turnState.assistantItemId),
              },
            });
          }
        }
        context.lastAssistantMessageId = messageId;
        context.session = {
          ...context.session,
          updatedAt: nowIso(),
          ...(context.providerThreadId
            ? {
                resumeCursor: {
                  threadId: context.session.threadId,
                  resume: context.providerThreadId,
                  ...(messageId ? { resumeSessionAt: messageId } : {}),
                  turnCount: context.turns.length,
                },
              }
            : {}),
        };
        offerRuntimeEvent({
          type: "item.updated",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId: turnState.turnId,
          itemId: asRuntimeItemId(turnState.assistantItemId),
          payload: {
            itemType: "assistant_message",
            status: "inProgress",
            title: "Assistant message",
            data: message,
          },
          providerRefs: {
            providerTurnId: String(turnState.turnId),
            providerItemId: ProviderItemId.makeUnsafe(turnState.assistantItemId),
          },
        });
        return;
      }

      if (messageType === "rate_limit_event") {
        offerRuntimeEvent({
          type: "account.rate-limits.updated",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          ...(context.turnState ? { turnId: context.turnState.turnId } : {}),
          payload: {
            rateLimits: line.rate_limit_info ?? line,
          },
        });
        return;
      }

      if (messageType === "result") {
        const status = turnStatusFromCursorResult(line);
        const errorMessage =
          status === "completed"
            ? undefined
            : asString(line.result) ??
              (asArray(line.errors)?.find((entry): entry is string => typeof entry === "string") ??
                "Cursor turn failed.");
        if (status === "failed" && errorMessage) {
          emitRuntimeError(context, errorMessage, {
            turnId: context.turnState?.turnId,
            detail: line,
          });
        }
        completeTurn(context, status, line, errorMessage);
      }
    };

    const attachTurnProcess = (
      context: CursorSessionContext,
      turnInput: ProviderSendTurnInput,
      child: CursorCliTurnProcess,
    ): void => {
      const turnState = context.turnState;
      if (!turnState) return;

      let stdoutBuffer = "";
      let stderrBuffer = "";

      child.stdout.on("data", (chunk) => {
        const parsed = parseNdjsonChunk(stdoutBuffer, Buffer.from(chunk).toString("utf8"));
        stdoutBuffer = parsed.nextBuffer;
        for (const line of parsed.lines) {
          try {
            const decoded = JSON.parse(line) as unknown;
            if (isRecord(decoded)) {
              handleCliMessage(context, decoded);
            } else {
              emitRuntimeWarning(context, "Ignored non-object Cursor CLI stream event.", line);
            }
          } catch (cause) {
            emitRuntimeWarning(context, "Failed to parse Cursor CLI stream line.", {
              line,
              cause: toMessage(cause, "Invalid JSON"),
            });
          }
        }
      });

      child.stderr.on("data", (chunk) => {
        stderrBuffer += Buffer.from(chunk).toString("utf8");
      });

      child.on("exit", (code, signal) => {
        if (stdoutBuffer.trim().length > 0) {
          try {
            const decoded = JSON.parse(stdoutBuffer.trim()) as unknown;
            if (isRecord(decoded)) {
              handleCliMessage(context, decoded);
            }
          } catch {
            // Ignore trailing partials.
          }
        }

        const activeTurn = context.turnState;
        if (!activeTurn || activeTurn.turnId !== turnState.turnId || activeTurn.completed) {
          return;
        }

        if (activeTurn.interruptRequested) {
          completeTurn(context, "interrupted", undefined, "Turn interrupted.");
          return;
        }

        if (code === 0) {
          completeTurn(context, "completed");
          return;
        }

        const stderrMessage = stderrBuffer.trim();
        const message =
          stderrMessage.length > 0
            ? stderrMessage
            : `Cursor CLI exited unexpectedly (${code ?? "unknown"}${signal ? `, ${signal}` : ""}).`;
        emitRuntimeError(context, message, {
          turnId: turnState.turnId,
          detail: {
            code,
            signal,
            stderr: stderrMessage,
            interactionMode: turnInput.interactionMode,
          },
        });
        completeTurn(context, "failed", undefined, message);
      });
    };

    const requireSession = (threadId: ThreadId): Effect.Effect<CursorSessionContext, ProviderAdapterError> => {
      const context = sessions.get(threadId);
      if (!context) {
        return Effect.fail(
          new ProviderAdapterSessionNotFoundError({
            provider: PROVIDER,
            threadId,
          }),
        );
      }
      if (context.stopped || context.session.status === "closed") {
        return Effect.fail(
          new ProviderAdapterSessionClosedError({
            provider: PROVIDER,
            threadId,
          }),
        );
      }
      return Effect.succeed(context);
    };

    // ── Adapter methods ────────────────────────────────────────────

    const startSession: CursorAdapterShape["startSession"] = (input) =>
      Effect.gen(function* () {
        if (input.provider !== undefined && input.provider !== PROVIDER) {
          return yield* new ProviderAdapterValidationError({
            provider: PROVIDER,
            operation: "startSession",
            issue: `Expected provider '${PROVIDER}' but received '${input.provider}'.`,
          });
        }

        const providerOptions = input.providerOptions?.cursor;
        const resumeState = readCursorResumeState(input.resumeCursor);
        const session: ProviderSession = {
          provider: PROVIDER,
          status: "ready",
          runtimeMode: input.runtimeMode,
          ...(input.cwd ? { cwd: input.cwd } : {}),
          ...(input.model ? { model: input.model } : {}),
          threadId: input.threadId,
          ...(resumeState.resume
            ? {
                resumeCursor: {
                  threadId: input.threadId,
                  resume: resumeState.resume,
                  turnCount: resumeState.turnCount ?? 0,
                },
              }
            : {}),
          createdAt: nowIso(),
          updatedAt: nowIso(),
        };

        const context: CursorSessionContext = {
          session,
          binaryPath: providerOptions?.binaryPath ?? "agent",
          turns: [],
          turnState: undefined,
          providerThreadId: resumeState.resume,
          lastAssistantMessageId: undefined,
          stopped: false,
        };
        sessions.set(input.threadId, context);

        offerRuntimeEvent({
          type: "session.started",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: input.threadId,
          payload: input.resumeCursor !== undefined ? { resume: input.resumeCursor } : {},
          providerRefs: {},
        });
        offerRuntimeEvent({
          type: "session.configured",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: input.threadId,
          payload: {
            config: {
              ...(input.cwd ? { cwd: input.cwd } : {}),
              ...(input.model ? { model: input.model } : {}),
              binaryPath: context.binaryPath,
            },
          },
          providerRefs: {},
        });
        offerRuntimeEvent({
          type: "session.state.changed",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: input.threadId,
          payload: {
            state: "ready",
          },
          providerRefs: {},
        });

        return { ...session };
      });

    const sendTurn: CursorAdapterShape["sendTurn"] = (input) =>
      Effect.gen(function* () {
        const context = yield* requireSession(input.threadId);
        if (context.turnState) {
          return yield* new ProviderAdapterValidationError({
            provider: PROVIDER,
            operation: "sendTurn",
            issue: `Thread '${input.threadId}' already has an active turn '${context.turnState.turnId}'.`,
          });
        }

        const prompt = buildUserPrompt(input);
        if (prompt.trim().length === 0) {
          return yield* new ProviderAdapterValidationError({
            provider: PROVIDER,
            operation: "sendTurn",
            issue: "Cursor CLI requires a non-empty prompt.",
          });
        }

        const turnId = TurnIdBrand.makeUnsafe(crypto.randomUUID());
        const selectedModel = input.model ?? context.session.model;

        const isFullAccess = context.session.runtimeMode === "full-access";

        const args = [
          "--print",
          "--output-format",
          "stream-json",
          "--stream-partial-output",
          "--trust",
          ...(isFullAccess ? ["--force"] : []),
          ...(selectedModel && selectedModel !== "auto" ? ["--model", selectedModel] : []),
          ...(context.providerThreadId ? ["--resume", context.providerThreadId] : []),
          ...(input.interactionMode === "plan" ? ["--mode", "plan"] : []),
          prompt,
        ];

        const child = yield* Effect.try({
          try: () =>
            spawnTurn({
              binaryPath: context.binaryPath,
              args,
              ...(context.session.cwd ? { cwd: context.session.cwd } : {}),
              env: process.env,
            }),
          catch: (cause) =>
            new ProviderAdapterProcessError({
              provider: PROVIDER,
              threadId: input.threadId,
              detail: toMessage(cause, "Failed to start Cursor CLI turn process."),
              cause,
            }),
        });

        const turnState: CursorTurnState = {
          turnId,
          assistantItemId: crypto.randomUUID(),
          startedAt: nowIso(),
          child,
          items: [],
          inFlightTools: new Map(),
          assistantText: "",
          emittedTextDelta: false,
          messageCompleted: false,
          interruptRequested: false,
          completed: false,
        };
        context.turnState = turnState;
        context.session = {
          ...context.session,
          status: "running",
          activeTurnId: turnId,
          updatedAt: nowIso(),
          ...(selectedModel ? { model: selectedModel } : {}),
        };

        offerRuntimeEvent({
          type: "turn.started",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          turnId,
          payload: {
            ...(selectedModel ? { model: selectedModel } : {}),
          },
          providerRefs: {
            providerTurnId: String(turnId),
          },
        });

        attachTurnProcess(context, input, child);

        return {
          threadId: context.session.threadId,
          turnId,
          ...(context.session.resumeCursor !== undefined
            ? { resumeCursor: context.session.resumeCursor }
            : {}),
        };
      });

    const interruptTurn: CursorAdapterShape["interruptTurn"] = (threadId, _turnId) =>
      Effect.gen(function* () {
        const context = yield* requireSession(threadId);
        if (!context.turnState) return;
        context.turnState.interruptRequested = true;
        context.turnState.child.kill("SIGTERM");
      });

    const readThread: CursorAdapterShape["readThread"] = (threadId) =>
      Effect.gen(function* () {
        const context = yield* requireSession(threadId);
        return snapshotThread(context);
      });

    const rollbackThread: CursorAdapterShape["rollbackThread"] = (threadId, numTurns) =>
      Effect.gen(function* () {
        const context = yield* requireSession(threadId);
        if (context.turnState) {
          return yield* new ProviderAdapterRequestError({
            provider: PROVIDER,
            method: "thread/rollback",
            detail: "Cannot roll back while a Cursor turn is active.",
          });
        }
        const nextLength = Math.max(0, context.turns.length - numTurns);
        context.turns.splice(nextLength);
        context.session = {
          ...context.session,
          updatedAt: nowIso(),
          ...(context.providerThreadId
            ? {
                resumeCursor: {
                  threadId: context.session.threadId,
                  resume: context.providerThreadId,
                  ...(context.lastAssistantMessageId
                    ? { resumeSessionAt: context.lastAssistantMessageId }
                    : {}),
                  turnCount: context.turns.length,
                },
              }
            : {}),
        };
        return snapshotThread(context);
      });

    const respondToRequest: CursorAdapterShape["respondToRequest"] = (threadId, requestId, _decision) =>
      Effect.fail(
        new ProviderAdapterRequestError({
          provider: PROVIDER,
          method: "request/respond",
          detail: `Cursor CLI approval response is not available for thread '${threadId}' and request '${requestId}' in this build.`,
        }),
      );

    const respondToUserInput: CursorAdapterShape["respondToUserInput"] = (threadId, requestId, _answers) =>
      Effect.fail(
        new ProviderAdapterRequestError({
          provider: PROVIDER,
          method: "user-input/respond",
          detail: `Cursor CLI structured user-input response is not available for thread '${threadId}' and request '${requestId}' in this build.`,
        }),
      );

    const stopSessionInternal = (context: CursorSessionContext, emitExitEvent: boolean): void => {
      if (context.stopped) return;
      context.stopped = true;
      if (context.turnState && !context.turnState.completed) {
        context.turnState.interruptRequested = true;
        context.turnState.child.kill("SIGTERM");
      }
      context.session = {
        ...context.session,
        status: "closed",
        activeTurnId: undefined,
        updatedAt: nowIso(),
      };
      if (emitExitEvent) {
        offerRuntimeEvent({
          type: "session.exited",
          eventId: nextEventId(),
          provider: PROVIDER,
          createdAt: nowIso(),
          threadId: context.session.threadId,
          payload: {
            reason: "Session stopped",
            exitKind: "graceful",
          },
        });
      }
      sessions.delete(context.session.threadId);
    };

    const stopSession: CursorAdapterShape["stopSession"] = (threadId) =>
      Effect.gen(function* () {
        const context = yield* requireSession(threadId);
        stopSessionInternal(context, true);
      });

    const listSessions: CursorAdapterShape["listSessions"] = () =>
      Effect.sync(() => Array.from(sessions.values(), ({ session }) => ({ ...session })));

    const hasSession: CursorAdapterShape["hasSession"] = (threadId) =>
      Effect.sync(() => {
        const context = sessions.get(threadId);
        return context !== undefined && !context.stopped;
      });

    const stopAll: CursorAdapterShape["stopAll"] = () =>
      Effect.sync(() => {
        for (const [, context] of sessions) {
          stopSessionInternal(context, true);
        }
      });

    yield* Effect.addFinalizer(() =>
      Effect.sync(() => {
        for (const [, context] of sessions) {
          stopSessionInternal(context, false);
        }
      }).pipe(Effect.tap(() => Queue.shutdown(runtimeEventQueue))),
    );

    return {
      provider: PROVIDER,
      capabilities: {
        sessionModelSwitch: "restart-session",
      },
      startSession,
      sendTurn,
      interruptTurn,
      readThread,
      rollbackThread,
      respondToRequest,
      respondToUserInput,
      stopSession,
      listSessions,
      hasSession,
      stopAll,
      streamEvents: Stream.fromQueue(runtimeEventQueue),
    } satisfies CursorAdapterShape;
  });
}

export const CursorAdapterLive = Layer.effect(CursorAdapter, makeCursorAdapter());

export function makeCursorAdapterLive(options?: CursorAdapterLiveOptions) {
  return Layer.effect(CursorAdapter, makeCursorAdapter(options));
}
