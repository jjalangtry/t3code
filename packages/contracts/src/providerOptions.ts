import { Schema } from "effect";
import { NonNegativeInt, TrimmedNonEmptyString } from "./baseSchemas";

const CodexProviderStartOptions = Schema.Struct({
  binaryPath: Schema.optional(TrimmedNonEmptyString),
  homePath: Schema.optional(TrimmedNonEmptyString),
});

const ClaudeCodeProviderStartOptions = Schema.Struct({
  binaryPath: Schema.optional(TrimmedNonEmptyString),
  permissionMode: Schema.optional(TrimmedNonEmptyString),
  maxThinkingTokens: Schema.optional(NonNegativeInt),
});

const CursorProviderStartOptions = Schema.Struct({
  binaryPath: Schema.optional(TrimmedNonEmptyString),
});

export const ProviderStartOptions = Schema.Struct({
  codex: Schema.optional(CodexProviderStartOptions),
  claudeCode: Schema.optional(ClaudeCodeProviderStartOptions),
  cursor: Schema.optional(CursorProviderStartOptions),
});
export type ProviderStartOptions = typeof ProviderStartOptions.Type;
