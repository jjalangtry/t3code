import { ThreadId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";
import { Effect, Fiber, Random, Stream } from "effect";

import { ProviderAdapterValidationError } from "../Errors.ts";
import { ClaudeCodeAdapter } from "../Services/ClaudeCodeAdapter.ts";
import {
  makeClaudeCodeAdapterLive,
  type ClaudeCodeAdapterLiveOptions,
} from "./ClaudeCodeAdapter.ts";
import {
  type CliSpawnInvocation,
  FakeCliChildProcess,
  makeDeterministicRandomService,
} from "./cliAdapterTestUtils.ts";

interface Harness {
  readonly layer: ReturnType<typeof makeClaudeCodeAdapterLive>;
  readonly getLastProcess: () => FakeCliChildProcess | undefined;
  readonly getLastSpawnInvocation: () => CliSpawnInvocation | undefined;
  readonly processes: FakeCliChildProcess[];
  readonly spawnInvocations: CliSpawnInvocation[];
}

function makeHarness(config?: {
  readonly nativeEventLogPath?: string;
  readonly nativeEventLogger?: ClaudeCodeAdapterLiveOptions["nativeEventLogger"];
}): Harness {
  const processes: FakeCliChildProcess[] = [];
  const spawnInvocations: CliSpawnInvocation[] = [];

  const adapterOptions: ClaudeCodeAdapterLiveOptions = {
    spawnTurnProcess: (input) => {
      spawnInvocations.push(input);
      const proc = new FakeCliChildProcess();
      processes.push(proc);
      return proc as any;
    },
    ...(config?.nativeEventLogger ? { nativeEventLogger: config.nativeEventLogger } : {}),
    ...(config?.nativeEventLogPath ? { nativeEventLogPath: config.nativeEventLogPath } : {}),
  };

  return {
    layer: makeClaudeCodeAdapterLive(adapterOptions),
    getLastProcess: () => processes[processes.length - 1],
    getLastSpawnInvocation: () => spawnInvocations[spawnInvocations.length - 1],
    processes,
    spawnInvocations,
  };
}

const THREAD_ID = ThreadId.makeUnsafe("thread-claude-1");

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

  it.effect("interrupts active Claude turns via SIGTERM", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        runtimeMode: "full-access",
      });

      const turn = yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
      });

      const proc = harness.getLastProcess();
      assert.notStrictEqual(proc, undefined);
      if (!proc) {
        return;
      }

      yield* adapter.interruptTurn(session.threadId, turn.turnId);
      assert.deepEqual(proc.killCalls, ["SIGTERM"]);
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect(
    "supports rollbackThread by trimming in-memory turns and preserving earlier turns",
    () => {
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

        const firstCompletedFiber = yield* Stream.filter(
          adapter.streamEvents,
          (event) => event.type === "turn.completed",
        ).pipe(Stream.runHead, Effect.forkChild);

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

        const secondCompletedFiber = yield* Stream.filter(
          adapter.streamEvents,
          (event) => event.type === "turn.completed",
        ).pipe(Stream.runHead, Effect.forkChild);

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
    },
  );

  it.effect("passes Claude session options through to the CLI process environment and args", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const previousMaxThinkingTokens = process.env.MAX_THINKING_TOKENS;
      process.env.MAX_THINKING_TOKENS = "0";
      try {
        const adapter = yield* ClaudeCodeAdapter;

        const session = yield* adapter.startSession({
          threadId: THREAD_ID,
          provider: "claudeCode",
          runtimeMode: "full-access",
          cwd: "/tmp/claude-project",
          model: "claude-sonnet-4-6",
          modelOptions: {
            claudeCode: {
              thinking: true,
            },
          },
          providerOptions: {
            claudeCode: {
              binaryPath: "/opt/claude",
              permissionMode: "acceptEdits",
              maxThinkingTokens: 4096,
            },
          },
          resumeCursor: {
            sessionId: "resume-session-1",
          },
        });

        yield* adapter.sendTurn({
          threadId: session.threadId,
          input: "hello",
          attachments: [],
          interactionMode: "plan",
          model: "claude-opus-4-6",
        });

        const spawn = harness.getLastSpawnInvocation();
        assert.notStrictEqual(spawn, undefined);
        if (!spawn) {
          return;
        }

        assert.equal(spawn.binaryPath, "/opt/claude");
        assert.equal(spawn.cwd, "/tmp/claude-project");
        assert.deepEqual(spawn.args.slice(0, 5), [
          "-p",
          "--verbose",
          "--output-format",
          "stream-json",
          "--include-partial-messages",
        ]);
        assert.deepEqual(spawn.args.slice(5, 10), [
          "--permission-mode",
          "plan",
          "--model",
          "claude-opus-4-6",
          "--resume",
        ]);
        assert.equal(spawn.args[10], "resume-session-1");
        assert.equal(spawn.args.includes("--append-system-prompt"), true);
        assert.equal(spawn.env.MAX_THINKING_TOKENS, "4096");
      } finally {
        if (previousMaxThinkingTokens === undefined) {
          delete process.env.MAX_THINKING_TOKENS;
        } else {
          process.env.MAX_THINKING_TOKENS = previousMaxThinkingTokens;
        }
      }
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("disables Claude thinking when the model options turn it off", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* ClaudeCodeAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "claudeCode",
        runtimeMode: "full-access",
        modelOptions: {
          claudeCode: {
            thinking: false,
          },
        },
      });

      yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
      });

      const spawn = harness.getLastSpawnInvocation();
      assert.notStrictEqual(spawn, undefined);
      if (!spawn) {
        return;
      }
      assert.equal(spawn.env.MAX_THINKING_TOKENS, "0");
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
      assert.equal(
        nativeEvents.some((record) => record.event?.provider === "claudeCode"),
        true,
      );
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });
});
