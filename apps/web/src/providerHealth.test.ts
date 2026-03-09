import { describe, expect, it } from "vitest";

import { getAppSettingsSnapshot } from "./appSettings";
import { resolveEffectiveProviderStatus, resolveProviderAvailability } from "./providerHealth";

describe("providerHealth", () => {
  it("keeps server availability when no binary override is configured", () => {
    const settings = getAppSettingsSnapshot();
    const statuses = [
      {
        provider: "cursor" as const,
        status: "error" as const,
        available: false,
        authStatus: "unknown" as const,
        checkedAt: "2026-03-09T00:00:00.000Z",
        message: "Cursor CLI (`cursor-agent`) is not installed or not on PATH.",
      },
    ];

    expect(resolveProviderAvailability("cursor", statuses, settings, true)).toBe(false);
    expect(resolveEffectiveProviderStatus("cursor", statuses, settings)).toEqual(statuses[0]);
  });

  it("treats a configured binary override as available with a warning", () => {
    const settings = {
      ...getAppSettingsSnapshot(),
      cursorBinaryPath: "/opt/cursor-agent",
    };
    const statuses = [
      {
        provider: "cursor" as const,
        status: "error" as const,
        available: false,
        authStatus: "unknown" as const,
        checkedAt: "2026-03-09T00:00:00.000Z",
        message: "Cursor CLI (`cursor-agent`) is not installed or not on PATH.",
      },
    ];

    expect(resolveProviderAvailability("cursor", statuses, settings, false)).toBe(true);
    expect(resolveEffectiveProviderStatus("cursor", statuses, settings)).toEqual({
      ...statuses[0],
      available: true,
      status: "warning",
      authStatus: "unknown",
      message:
        "Cursor will use the configured binary override (/opt/cursor-agent). Server health checks only verify the default PATH binary.",
    });
  });
});
