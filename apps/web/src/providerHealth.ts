import type { ProviderKind, ServerProviderStatus } from "@t3tools/contracts";

import type { AppSettings } from "./appSettings";

function providerLabel(provider: ProviderKind): string {
  switch (provider) {
    case "codex":
      return "Codex";
    case "claudeCode":
      return "Claude Code";
    case "cursor":
      return "Cursor";
  }
}

function binaryPathOverrideForProvider(
  provider: ProviderKind,
  settings: Pick<AppSettings, "codexBinaryPath" | "claudeBinaryPath" | "cursorBinaryPath">,
): string | null {
  const configuredPath =
    provider === "codex"
      ? settings.codexBinaryPath
      : provider === "claudeCode"
        ? settings.claudeBinaryPath
        : settings.cursorBinaryPath;
  const trimmed = configuredPath.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function resolveEffectiveProviderStatus(
  provider: ProviderKind,
  statuses: ReadonlyArray<ServerProviderStatus>,
  settings: Pick<AppSettings, "codexBinaryPath" | "claudeBinaryPath" | "cursorBinaryPath">,
): ServerProviderStatus | null {
  const status = statuses.find((entry) => entry.provider === provider) ?? null;
  const binaryPathOverride = binaryPathOverrideForProvider(provider, settings);

  if (!status || !binaryPathOverride || status.available) {
    return status;
  }

  return {
    ...status,
    available: true,
    status: "warning",
    authStatus: "unknown",
    message: `${providerLabel(provider)} will use the configured binary override (${binaryPathOverride}). Server health checks only verify the default PATH binary.`,
  };
}

export function resolveProviderAvailability(
  provider: ProviderKind,
  statuses: ReadonlyArray<ServerProviderStatus>,
  settings: Pick<AppSettings, "codexBinaryPath" | "claudeBinaryPath" | "cursorBinaryPath">,
  fallbackAvailable: boolean,
): boolean {
  return (
    resolveEffectiveProviderStatus(provider, statuses, settings)?.available ?? fallbackAvailable
  );
}
