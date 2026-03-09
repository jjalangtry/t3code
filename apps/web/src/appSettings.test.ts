import { describe, expect, it } from "vitest";

import {
  getAppModelOptions,
  getSlashModelOptions,
  normalizeCustomModelSlugs,
  resolveAppClaudeMaxThinkingTokens,
  resolveAppClaudePermissionMode,
  resolveAppClaudeThinking,
  resolveAppServiceTier,
  shouldShowFastTierIcon,
  resolveAppModelSelection,
} from "./appSettings";

describe("normalizeCustomModelSlugs", () => {
  it("normalizes aliases, removes built-ins, and deduplicates values", () => {
    expect(
      normalizeCustomModelSlugs([
        " custom/internal-model ",
        "gpt-5.3-codex",
        "5.3",
        "custom/internal-model",
        "",
        null,
      ]),
    ).toEqual(["custom/internal-model"]);
  });
});

describe("getAppModelOptions", () => {
  it("appends saved custom models after the built-in options", () => {
    const options = getAppModelOptions("codex", ["custom/internal-model"]);

    expect(options.map((option) => option.slug)).toEqual([
      "gpt-5.4",
      "gpt-5.3-codex",
      "gpt-5.3-codex-spark",
      "gpt-5.2-codex",
      "gpt-5.2",
      "custom/internal-model",
    ]);
  });

  it("supports cursor built-in and custom model options", () => {
    const options = getAppModelOptions("cursor", ["cursor/custom-model"]);
    const slugs = options.map((option) => option.slug);

    expect(slugs[0]).toBe("auto");
    expect(slugs).toEqual(
      expect.arrayContaining([
        "composer-1.5",
        "gpt-5.4-medium",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "sonnet-4.6",
        "sonnet-4.6-thinking",
        "opus-4.6",
        "gemini-3.1-pro",
        "grok",
        "kimi-k2.5",
        "cursor/custom-model",
      ]),
    );
    expect(slugs.at(-1)).toBe("cursor/custom-model");
  });

  it("keeps the currently selected custom model available even if it is no longer saved", () => {
    const options = getAppModelOptions("codex", [], "custom/selected-model");

    expect(options.at(-1)).toEqual({
      slug: "custom/selected-model",
      name: "custom/selected-model",
      isCustom: true,
    });
  });
});

describe("resolveAppModelSelection", () => {
  it("preserves saved custom model slugs instead of falling back to the default", () => {
    expect(resolveAppModelSelection("codex", ["galapagos-alpha"], "galapagos-alpha")).toBe(
      "galapagos-alpha",
    );
  });

  it("falls back to the provider default when no model is selected", () => {
    expect(resolveAppModelSelection("codex", [], "")).toBe("gpt-5.4");
    expect(resolveAppModelSelection("cursor", [], "")).toBe("auto");
  });
});

describe("getSlashModelOptions", () => {
  it("includes saved custom model slugs for /model command suggestions", () => {
    const options = getSlashModelOptions(
      "codex",
      ["custom/internal-model"],
      "",
      "gpt-5.3-codex",
    );

    expect(options.some((option) => option.slug === "custom/internal-model")).toBe(true);
  });

  it("filters slash-model suggestions across built-in and custom model names", () => {
    const options = getSlashModelOptions(
      "codex",
      ["openai/gpt-oss-120b"],
      "oss",
      "gpt-5.3-codex",
    );

    expect(options.map((option) => option.slug)).toEqual(["openai/gpt-oss-120b"]);
  });
});

describe("resolveAppServiceTier", () => {
  it("maps automatic to no override", () => {
    expect(resolveAppServiceTier("auto")).toBeNull();
  });

  it("preserves explicit service tier overrides", () => {
    expect(resolveAppServiceTier("fast")).toBe("fast");
    expect(resolveAppServiceTier("flex")).toBe("flex");
  });
});

describe("resolveAppClaudePermissionMode", () => {
  it("omits inherited permission mode overrides", () => {
    expect(resolveAppClaudePermissionMode("inherit")).toBeUndefined();
  });

  it("preserves explicit Claude permission mode overrides", () => {
    expect(resolveAppClaudePermissionMode("acceptEdits")).toBe("acceptEdits");
  });
});

describe("resolveAppClaudeThinking", () => {
  it("maps thinking UI modes to Claude model option booleans", () => {
    expect(resolveAppClaudeThinking("inherit")).toBeUndefined();
    expect(resolveAppClaudeThinking("on")).toBe(true);
    expect(resolveAppClaudeThinking("off")).toBe(false);
  });
});

describe("resolveAppClaudeMaxThinkingTokens", () => {
  it("parses valid Claude thinking token overrides", () => {
    expect(resolveAppClaudeMaxThinkingTokens("4096")).toBe(4096);
    expect(resolveAppClaudeMaxThinkingTokens(" 0 ")).toBe(0);
  });

  it("ignores blank or invalid token overrides", () => {
    expect(resolveAppClaudeMaxThinkingTokens("")).toBeUndefined();
    expect(resolveAppClaudeMaxThinkingTokens("abc")).toBeUndefined();
    expect(resolveAppClaudeMaxThinkingTokens("-1")).toBeUndefined();
  });
});

describe("shouldShowFastTierIcon", () => {
  it("shows the fast-tier icon only for gpt-5.4 on fast tier", () => {
    expect(shouldShowFastTierIcon("gpt-5.4", "fast")).toBe(true);
    expect(shouldShowFastTierIcon("gpt-5.4", "auto")).toBe(false);
    expect(shouldShowFastTierIcon("gpt-5.3-codex", "fast")).toBe(false);
  });
});
