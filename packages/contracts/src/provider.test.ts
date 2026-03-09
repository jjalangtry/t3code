import { describe, expect, it } from "vitest";
import { Schema } from "effect";

import { ProviderSendTurnInput, ProviderSessionStartInput } from "./provider";

const decodeProviderSessionStartInput = Schema.decodeUnknownSync(ProviderSessionStartInput);
const decodeProviderSendTurnInput = Schema.decodeUnknownSync(ProviderSendTurnInput);

describe("ProviderSessionStartInput", () => {
  it("accepts codex-compatible payloads", () => {
    const parsed = decodeProviderSessionStartInput({
      threadId: "thread-1",
      provider: "codex",
      cwd: "/tmp/workspace",
      model: "gpt-5.3-codex",
      modelOptions: {
        codex: {
          reasoningEffort: "high",
          fastMode: true,
        },
      },
      runtimeMode: "full-access",
      providerOptions: {
        codex: {
          binaryPath: "/usr/local/bin/codex",
          homePath: "/tmp/.codex",
        },
      },
    });
    expect(parsed.runtimeMode).toBe("full-access");
    expect(parsed.modelOptions?.codex?.reasoningEffort).toBe("high");
    expect(parsed.modelOptions?.codex?.fastMode).toBe(true);
    expect(parsed.providerOptions?.codex?.binaryPath).toBe("/usr/local/bin/codex");
    expect(parsed.providerOptions?.codex?.homePath).toBe("/tmp/.codex");
  });

  it("accepts cursor-compatible payloads", () => {
    const parsed = decodeProviderSessionStartInput({
      threadId: "thread-cursor-1",
      provider: "cursor",
      cwd: "/tmp/workspace",
      model: "auto",
      modelOptions: {
        cursor: {},
      },
      runtimeMode: "approval-required",
      providerOptions: {
        cursor: {
          binaryPath: "/usr/local/bin/cursor-agent",
        },
      },
    });

    expect(parsed.provider).toBe("cursor");
    expect(parsed.model).toBe("auto");
    expect(parsed.runtimeMode).toBe("approval-required");
    expect(parsed.providerOptions?.cursor?.binaryPath).toBe("/usr/local/bin/cursor-agent");
  });

  it("rejects payloads without runtime mode", () => {
    expect(() =>
      decodeProviderSessionStartInput({
        threadId: "thread-1",
        provider: "codex",
      }),
    ).toThrow();
  });
});

describe("ProviderSendTurnInput", () => {
  it("accepts provider-scoped model options", () => {
    const parsed = decodeProviderSendTurnInput({
      threadId: "thread-1",
      model: "gpt-5.3-codex",
      modelOptions: {
        codex: {
          reasoningEffort: "xhigh",
          fastMode: true,
        },
      },
    });

    expect(parsed.model).toBe("gpt-5.3-codex");
    expect(parsed.modelOptions?.codex?.reasoningEffort).toBe("xhigh");
    expect(parsed.modelOptions?.codex?.fastMode).toBe(true);
  });

  it("accepts claude and cursor provider-scoped model options", () => {
    const parsed = decodeProviderSendTurnInput({
      threadId: "thread-claude-1",
      model: "claude-sonnet-4-6",
      modelOptions: {
        claudeCode: {
          thinking: true,
        },
        cursor: {},
      },
    });

    expect(parsed.modelOptions?.claudeCode?.thinking).toBe(true);
    expect(parsed.modelOptions?.cursor).toEqual({});
  });
});
