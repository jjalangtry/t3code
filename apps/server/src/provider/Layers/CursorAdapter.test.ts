import { ThreadId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";
import { Effect, Random } from "effect";

import { ProviderAdapterValidationError } from "../Errors.ts";
import { CursorAdapter } from "../Services/CursorAdapter.ts";
import { makeCursorAdapterLive, type CursorAdapterLiveOptions } from "./CursorAdapter.ts";
import {
  type CliSpawnInvocation,
  FakeCliChildProcess,
  makeDeterministicRandomService,
} from "./cliAdapterTestUtils.ts";

interface Harness {
  readonly layer: ReturnType<typeof makeCursorAdapterLive>;
  readonly getLastProcess: () => FakeCliChildProcess | undefined;
  readonly getLastSpawnInvocation: () => CliSpawnInvocation | undefined;
  readonly processes: FakeCliChildProcess[];
  readonly spawnInvocations: CliSpawnInvocation[];
}

function makeHarness(config?: {
  readonly nativeEventLogPath?: string;
  readonly nativeEventLogger?: CursorAdapterLiveOptions["nativeEventLogger"];
}): Harness {
  const processes: FakeCliChildProcess[] = [];
  const spawnInvocations: CliSpawnInvocation[] = [];

  const adapterOptions: CursorAdapterLiveOptions = {
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
    layer: makeCursorAdapterLive(adapterOptions),
    getLastProcess: () => processes[processes.length - 1],
    getLastSpawnInvocation: () => spawnInvocations[spawnInvocations.length - 1],
    processes,
    spawnInvocations,
  };
}

const THREAD_ID = ThreadId.makeUnsafe("thread-cursor-1");

describe("CursorAdapterLive", () => {
  it.effect("returns validation error for non-cursor provider on startSession", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* CursorAdapter;
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
          provider: "cursor",
          operation: "startSession",
          issue: "Expected provider 'cursor' but received 'codex'.",
        }),
      );
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });

  it.effect("interrupts active Cursor turns via SIGTERM", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* CursorAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "cursor",
        model: "auto",
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

  it.effect("passes Cursor session options through to the CLI process", () => {
    const harness = makeHarness();
    return Effect.gen(function* () {
      const adapter = yield* CursorAdapter;

      const session = yield* adapter.startSession({
        threadId: THREAD_ID,
        provider: "cursor",
        runtimeMode: "full-access",
        cwd: "/tmp/cursor-project",
        model: "auto",
        providerOptions: {
          cursor: {
            binaryPath: "/opt/cursor-agent",
          },
        },
        resumeCursor: {
          sessionId: "cursor-session-1",
        },
      });

      yield* adapter.sendTurn({
        threadId: session.threadId,
        input: "hello",
        attachments: [],
        interactionMode: "plan",
        model: "cursor/gpt-5",
      });

      const spawn = harness.getLastSpawnInvocation();
      assert.notStrictEqual(spawn, undefined);
      if (!spawn) {
        return;
      }

      assert.equal(spawn.binaryPath, "/opt/cursor-agent");
      assert.equal(spawn.cwd, "/tmp/cursor-project");
      assert.deepEqual(
        spawn.args.slice(0, 7),
        [
          "--print",
          "--output-format",
          "stream-json",
          "--model",
          "cursor/gpt-5",
          "--resume",
          "cursor-session-1",
        ],
      );
      assert.equal(spawn.args.includes("--append-system-prompt"), true);
      assert.equal(spawn.args.at(-1), "hello");
    }).pipe(
      Effect.provideService(Random.Random, makeDeterministicRandomService()),
      Effect.provide(harness.layer),
    );
  });
});
