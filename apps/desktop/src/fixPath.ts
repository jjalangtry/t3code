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
    // Keep inherited PATH if shell lookup fails.
  }
}
