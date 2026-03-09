import { EventEmitter } from "node:events";
import { Readable } from "node:stream";

export interface CliSpawnInvocation {
  readonly binaryPath: string;
  readonly args: ReadonlyArray<string>;
  readonly cwd?: string;
  readonly env: NodeJS.ProcessEnv;
}

export class FakeCliChildProcess extends EventEmitter {
  readonly pid = 12345;
  readonly stdout: Readable;
  readonly stderr: Readable;

  public killCalls: Array<string | number | undefined> = [];

  constructor() {
    super();
    this.stdout = new Readable({
      read() {},
    });
    this.stderr = new Readable({
      read() {},
    });
  }

  emitLine(obj: Record<string, unknown>): void {
    this.stdout.push(`${JSON.stringify(obj)}\n`);
  }

  emitStderr(text: string): void {
    this.stderr.push(text);
  }

  exit(code: number | null, signal: NodeJS.Signals | null = null): void {
    this.stdout.push(null);
    this.stderr.push(null);
    this.emit("exit", code, signal);
  }

  kill(signal?: NodeJS.Signals | number): void {
    this.killCalls.push(signal);
  }
}

export function makeDeterministicRandomService(seed = 0x1234_5678): {
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
