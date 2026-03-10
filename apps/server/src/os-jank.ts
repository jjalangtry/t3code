import * as OS from "node:os";
import { Effect, Path } from "effect";
import { readPathFromLoginShell, resolveLoginShell } from "@t3tools/shared/shell";

export function fixPath(): void {
  if (process.platform === "win32") return;

  try {
    const shell = resolveLoginShell({ platform: process.platform, shellEnv: process.env.SHELL });
    if (!shell) return;
    const result = readPathFromLoginShell(shell);
    if (result) {
      process.env.PATH = result;
    }
  } catch {
    // Silently ignore — keep default PATH
  }
}

export const expandHomePath = Effect.fn(function* (input: string) {
  const { join } = yield* Path.Path;
  if (input === "~") {
    return OS.homedir();
  }
  if (input.startsWith("~/") || input.startsWith("~\\")) {
    return join(OS.homedir(), input.slice(2));
  }
  return input;
});

export const resolveStateDir = Effect.fn(function* (raw: string | undefined) {
  const { join, resolve } = yield* Path.Path;
  if (!raw || raw.trim().length === 0) {
    return join(OS.homedir(), ".t3", "userdata");
  }
  return resolve(yield* expandHomePath(raw.trim()));
});
