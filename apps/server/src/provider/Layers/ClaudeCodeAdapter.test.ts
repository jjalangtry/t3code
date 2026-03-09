import { ThreadId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";
import { Effect, Fiber, Random, Stream } from "effect";
import { EventEmitter, Readable } from "node:stream";

import {
  ProviderAdapterValidationError,
} from "../Errors.ts";
import { ClaudeCodeAdapter } from "../Services/ClaudeCodeAdapter.ts";
import {
  makeClaudeCodeAdapterLive,
  type ClaudeCodeAdapterLiveOptions,
} from "./ClaudeCodeAdapter.ts";

/**
 * Fake child process that can be driven from tests by writing NDJSON lines.
 */
class FakeChildProcess extends EventEmitter {
  readonly pid = 12345;
  readonly stdout: Readable;
  readonly stderr: Readable;

  private _stdoutPush: (chunk: string | null) => void;
  private _stderrPush: (chunk: string | null) => void;
  public killCalls: Array<string | number | undefined> = [];

  constructor() {
    super();
    let stdoutPush: (chunk: string | null) => void = () => {};
    let stderrPush: (chunk: string | null) => void = () => {};
    this.stdout = new Readable({
      read() {},
    });
    this.stderr = new Readable({
      read() {},
    });
    this._stdoutPush = (chunk) => this.stdout.push(chunk);
    this._stderrPush = (chunk) => this.stderr.push(chunk);
  }

  /** Write an NDJSON line to stdout (simulates Claude CLI output). */
  emitLine(obj: Record<string, unknown>): void {
    this._stdoutPush(`${JSON.stringify(obj)}\n`);
  }

  /** Write stderr output. */
  emitStderr(text: string): void {
    this._stderrPush(text);
  }

  /** Simulate process exit. */
  exit(code: number | null, signal: NodeJS.Signals | null = null): void {
    this._stdoutPush(null);
    this._stderrPush(null);
    this.emit("exit", code, signal);
  }

  kill(signal?: NodeJS.Signals | number): void {
    this.killCalls.push(signal);
  }
}

interface Harness {
  readonly layer: ReturnType<typeof makeClaudeCodeAdapterLive>;
  readonly getLastProcess: () => FakeChildProcess | undefined;
  readonly processes: FakeChildProcess[];
}

function makeHarness(config?: {
  readonly nativeEventLogPath?: string;
  readonly nativeEventLogger?: ClaudeCodeAdapterLiveOptions["nativeEventLogger"];
}): Harness {
  const processes: FakeChildProcess[] = [];

  const adapterOptions: ClaudeCodeAdapterLiveOptions = {
    spawnTurnProcess: (_input) => {
      const proc = new FakeChildProcess();
      processes.push(proc);
      return proc as any;
    },
    ...(config?.nativeEventLogger
      ? { nativeEventLogger: config.nativeEventLogger }
      : {}),
    ...(config?.nativeEventLogPath
      ? { nativeEventLogPath: config.nativeEventLogPath }
      : {}),
  };

  return {
    layer: makeClaudeCodeAdapterLive(adapterOptions),
    getLastProcess: () => processes[processes.length - 1],
    processes,
  };
}

function makeDeterministicRandomService(seed = 0x1234_5678): {
  nextIntUnsafe: () => number;
  nextDoubleUnsafe: () => number;
} {
  let state = seed >>> 0;
  const nextIntUnsafe = (): number => {
    state = (Math.imul(1_664_525, state) + 1_013_904_223) >>> 0;
    return state;
  };

  return {
    nextIntUnsafe,
    nextDoubleUnsafe: () => nextIntUnsafe() / 0x1_0000_0000,
  };
}

const THREAD_ID = ThreadId.makeUnsafe("thread-claude-1");
const RESUME_THREAD_ID = ThreadId.makeUnsafe("thread-claude-resume");

describe("ClaudeCodeAdapterLive", () => {
  it.effect("returns validation error for non-claudeCode provider on startSession", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;
      const result = yield* adapter
        .startSession({ threadId: THREAD_ID, provider: "codex", runtimeMode: "full-access" })
        .pipe(Effect.result);

      assert.equal(result._tag, "Failure");
      if (result._tag !== "Failure") {
        return;
      }
      assert.deepEqual(
        result.failure,
        new ProviderAdapterValidationError({
          provider: "claudeCode",
          operation: "startSession",
          issue: "Expected provider 'claudeCode' but received 'codex'.",
        }),
      );
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("maps Claude CLI stream events to canonical provider runtime events", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const runtimeEventsFiber = yield* Stream.take(adapter.streamEvents, 11).pipe(
        Stream.runCollect,
        Effect.forkChild,
      );

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        model: "claude-sonnet-4-6",
        runtimeMode: "full-access",
      });

      const turn = yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
      });

      const proc = harness.getLastProcess()!;

      // Emit a content delta
      proc.emitLine({
        type: "stream_event",
        session_id: "cli-session-1",
        event: {
          type: "content_block_delta",
          index: 0,
          delta: {
            type: "text_delta",
            text: "Hi",
          },
        },
      });

      // Emit a tool start
      proc.emitLine({
        type: "stream_event",
        session_id: "cli-session-1",
        event: {
          type: "content_block_start",
          index: 1,
          content_block: {
            type: "tool_use",
            id: "tool-1",
            name: "Bash",
            input: {
              command: "ls",
            },
          },
        },
      });

      // Emit tool stop
      proc.emitLine({
        type: "stream_event",
        session_id: "cli-session-1",
        event: {
          type: "content_block_stop",
          index: 1,
        },
      });

      // Emit assistant message
      proc.emitLine({
        type: "assistant",
        session_id: "cli-session-1",
        message: {
          id: "assistant-message-1",
          content: [{ type: "text", text: "Hi" }],
        },
      });

      // Emit result
      proc.emitLine({
        type: "result",
        subtype: "success",
        is_error: false,
        errors: [],
        session_id: "cli-session-1",
      });
      proc.exit(0);

      const runtimeEvents = Array.from(yield* Fiber.join(runtimeEventsFiber));
      assert.deepEqual(
        runtimeEvents.map((event) => event.type),
        [
          "session.started",
          "session.configured",
          "session.state.changed",
          "turn.started",
          "thread.started",
          "content.delta",
          "item.started",
          "item.completed",
          "item.updated",
          "item.completed",
          "turn.completed",
        ],
      );

      const turnStarted = runtimeEvents[3];
      assert.equal(turnStarted?.type, "turn.started");
      if (turnStarted?.type === "turn.started") {
        assert.equal(String(turnStarted.turnId), String(turn.turnId));
      }

      const deltaEvent = runtimeEvents.find((event) => event.type === "content.delta");
      assert.equal(deltaEvent?.type, "content.delta");
      if (deltaEvent?.type === "content.delta") {
        assert.equal(deltaEvent.payload.delta, "Hi");
        assert.equal(String(deltaEvent.turnId), String(turn.turnId));
      }

      const toolStarted = runtimeEvents.find((event) => event.type === "item.started");
      assert.equal(toolStarted?.type, "item.started");
      if (toolStarted?.type === "item.started") {
        assert.equal(toolStarted.payload.itemType, "command_execution");
      }

      const turnCompleted = runtimeEvents[runtimeEvents.length - 1];
      assert.equal(turnCompleted?.type, "turn.completed");
      if (turnCompleted?.type === "turn.completed") {
        assert.equal(String(turnCompleted.turnId), String(turn.turnId));
        assert.equal(turnCompleted.payload.state, "completed");
      }
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("emits item.updated and item.completed when assistant message arrives without prior deltas", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const runtimeEventsFiber = yield* Stream.take(adapter.streamEvents, 8).pipe(
        Stream.runCollect,
        Effect.forkChild,
      );

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        runtimeMode: "full-access",
      });

      yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
      });

      const proc = harness.getLastProcess()!;

      // Emit assistant message directly (no prior content_block_delta)
      proc.emitLine({
        type: "assistant",
        session_id: "cli-session-fallback",
        message: {
          id: "assistant-message-fallback",
          content: [{ type: "text", text: "Fallback hello" }],
        },
      });

      proc.emitLine({
        type: "result",
        subtype: "success",
        is_error: false,
        errors: [],
        session_id: "cli-session-fallback",
      });
      proc.exit(0);

      const runtimeEvents = Array.from(yield* Fiber.join(runtimeEventsFiber));
      assert.deepEqual(
        runtimeEvents.map((event) => event.type),
        [
          "session.started",
          "session.configured",
          "session.state.changed",
          "turn.started",
          "thread.started",
          "item.updated",
          "item.completed",
          "turn.completed",
        ],
      );

      const itemUpdated = runtimeEvents.find((event) => event.type === "item.updated");
      assert.equal(itemUpdated?.type, "item.updated");
      if (itemUpdated?.type === "item.updated") {
        assert.equal(itemUpdated.payload.itemType, "assistant_message");
      }
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("supports rollbackThread by trimming in-memory turns and preserving earlier turns", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        runtimeMode: "full-access",
      });

      // First turn
      const firstTurn = yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "first",
        attachments: [],
      });

      const firstCompletedFiber = yield* Stream.filter(adapter.streamEvents, (event) => event.type === "turn.completed").pipe(
        Stream.runHead,
        Effect.forkChild,
      );

      const proc1 = harness.getLastProcess()!;
      proc1.emitLine({
        type: "result",
        subtype: "success",
        is_error: false,
        errors: [],
        session_id: "cli-session-rollback",
      });
      proc1.exit(0);

      const firstCompleted = yield* Fiber.join(firstCompletedFiber);
      assert.equal(firstCompleted._tag, "Some");
      if (firstCompleted._tag === "Some" && firstCompleted.value.type === "turn.completed") {
        assert.equal(String(firstCompleted.value.turnId), String(firstTurn.turnId));
      }

      // Second turn
      const secondTurn = yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "second",
        attachments: [],
      });

      const secondCompletedFiber = yield* Stream.filter(adapter.streamEvents, (event) => event.type === "turn.completed").pipe(
        Stream.runHead,
        Effect.forkChild,
      );

      const proc2 = harness.getLastProcess()!;
      proc2.emitLine({
        type: "result",
        subtype: "success",
        is_error: false,
        errors: [],
        session_id: "cli-session-rollback",
      });
      proc2.exit(0);

      const secondCompleted = yield* Fiber.join(secondCompletedFiber);
      assert.equal(secondCompleted._tag, "Some");
      if (secondCompleted._tag === "Some" && secondCompleted.value.type === "turn.completed") {
        assert.equal(String(secondCompleted.value.turnId), String(secondTurn.turnId));
      }

      const threadBeforeRollback = yield* adapter.readThread(session.threadId);
      assert.equal(threadBeforeRollback.turns.length, 2);

      const rolledBack = yield* adapter.rollbackThread(session.threadId, 1);
      assert.equal(rolledBack.turns.length, 1);
      assert.equal(rolledBack.turns[0]?.id, firstTurn.turnId);

      const threadAfterRollback = yield* adapter.readThread(session.threadId);
      assert.equal(threadAfterRollback.turns.length, 1);
      assert.equal(threadAfterRollback.turns[0]?.id, firstTurn.turnId);
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("writes provider-native observability records when enabled", () => {
    const nativeEvents: Array<{
      event?: {
        provider?: string;
        method?: string;
      };
    }> = [];
    const harness = makeHarness({
      nativeEventLogger: {
        filePath: "memory://claude-native-events",
        write: (event) => {
          nativeEvents.push(event as (typeof nativeEvents)[number]);
          return Effect.void;
        },
        close: () => Effect.void,
      },
    });
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        runtimeMode: "full-access",
      });
      yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
      });

      const turnCompletedFiber = yield* Stream.filter(
        adapter.streamEvents,
        (event) => event.type === "turn.completed",
      ).pipe(Stream.runHead, Effect.forkChild);

      const proc = harness.getLastProcess()!;
      proc.emitLine({
        type: "stream_event",
        session_id: "cli-session-native-log",
        event: {
          type: "content_block_delta",
          index: 0,
          delta: {
            type: "text_delta",
            text: "hi",
          },
        },
      });

      proc.emitLine({
        type: "result",
        subtype: "success",
        is_error: false,
        errors: [],
        session_id: "cli-session-native-log",
      });
      proc.exit(0);

      const turnCompleted = yield* Fiber.join(turnCompletedFiber);
      assert.equal(turnCompleted._tag, "Some");

      assert.equal(nativeEvents.length > 0, true);
      assert.equal(nativeEvents.some((record) => record.event?.provider === "claudeCode"), true);
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });
});
