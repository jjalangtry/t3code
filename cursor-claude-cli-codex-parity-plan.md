# Cursor + Claude CLI Codex-Parity Plan

## Summary

Bring `cursor` and `claudeCode` up to the same product tier as `codex` for thread lifecycle, provider selection, health/status, plan mode, plan sidebar/proposed-plan cards, approvals, resume, rollback, and orchestration projection.

This will be a CLI-first design for both providers:

- `Claude Code` moves from the current SDK-backed adapter to a CLI-backed adapter.
- `Cursor` becomes a first-class provider with a new adapter.
- The existing web plan UI stays mostly unchanged; parity comes from emitting the same canonical runtime events Codex already emits.

## Public API / Type Changes

- Extend `ProviderKind` to `codex | claudeCode | cursor`.
- Extend all provider-keyed records to include `cursor`: model defaults, aliases, health status, picker options, store inference, settings state.
- Add `CursorProviderStartOptions` to `ProviderStartOptions` with `binaryPath?: string`.
- Keep `ClaudeCodeProviderStartOptions`, but reinterpret it for the CLI adapter; `binaryPath` remains supported.
- Add `ProviderModelOptions.cursor?: {}` so provider-keyed shapes stay exhaustive even though Cursor has no stable extra knobs yet.
- Add `DEFAULT_MODEL_BY_PROVIDER.cursor = "auto"` and make Cursor built-in model options `[{ slug: "auto", name: "Auto" }]`; all other Cursor models come from user custom-model settings.
- No SQL migration: provider/session tables already store provider names as `TEXT`.

## Server Architecture

- Add a shared CLI-provider core under `apps/server/src/provider/cli/` for:
  - logical session registry
  - per-turn resume checkpoint journal
  - child-process / PTY lifecycle
  - line-oriented JSON stream parsing
  - canonical runtime event helpers
  - transcript/native-event logging
- Add a shared internal MCP control server service for non-Codex providers with tools:
  - `t3.update_plan`
  - `t3.request_user_input`
  - `t3.permission_prompt`
- Use those tools to synthesize Codex-equivalent canonical events:
  - `turn.plan.updated`
  - `turn.proposed.completed`
  - `user-input.requested`
  - `user-input.resolved`
  - `request.opened`
  - `request.resolved`

## Claude Implementation

- Replace the live `ClaudeCodeAdapter` internals with a CLI-backed adapter while keeping the same service tag.
- Spawn Claude in headless JSON mode per turn with resume support, model selection, and internal MCP config.
- Route Claude permission prompts through `--permission-prompt-tool` to the internal MCP control server so the existing approval UI continues to work.
- Use `t3.update_plan` and `t3.request_user_input` MCP tools for live plan sidebar updates and structured user questions.
- Preserve `readThread` / `rollbackThread` via a local turn journal and per-turn resume checkpoints; rollback trims local turns and resets the session to the last retained checkpoint.
- Remove `@anthropic-ai/claude-agent-sdk` from the production path after parity tests are green.

## Cursor Implementation

- Add a new first-class `CursorAdapter` and register it in `ProviderAdapterRegistry`.
- Use two runtime paths:
  - `full-access` and `interactionMode=plan`: `cursor-agent --print --output-format stream-json` with resume, internal MCP tools, and structured canonical event mapping.
  - `approval-required`: PTY-backed interactive mode so built-in Cursor approval prompts can still round-trip through the existing approval UI.
- For plan mode, require the model to use `t3.update_plan` and `t3.request_user_input` MCP tools; this is how Cursor drives the current plan UI rather than relying on provider-native plan events.
- Guard the PTY approval parser aggressively:
  - if prompt parsing loses sync, interrupt the turn
  - emit `runtime.error`
  - keep Cursor unavailable behind the parity flag rather than silently degrading behavior
- Implement local turn journaling and rollback the same way as Claude.

## Web / UX Changes

- Remove the current fake `cursor` picker hack and make Cursor a real `ProviderKind`.
- Update `ChatView`, stores, settings, and session logic so provider handling is exhaustive and not Codex/Claude-special-cased except where traits truly differ.
- Keep the current plan sidebar, proposed-plan card, follow-up banner, and implement-plan flow unchanged; new providers must feed them identical orchestration events.
- Add settings UI for:
  - `Claude Code` binary path
  - `Cursor` binary path
  - custom Claude models
  - custom Cursor models
- Expose the existing Claude `thinking` option in the composer.
- Leave Cursor without extra provider-specific composer traits for now.

## Rollout

- Ship behind parity gates, not as partially available providers.
- Add feature flags for the new runtime paths, with both providers hidden or marked unavailable until parity tests pass.
- Keep startup health checks for `codex`, `claude`, and `cursor`.
- Health remains startup/PATH-based for now; per-session binary-path overrides still work when launching turns.

## Tests and Acceptance

- Contract tests for new provider enums, defaults, settings, and model resolution.
- Adapter unit tests for:
  - Claude JSON stream parsing
  - Claude permission prompt bridge
  - Cursor JSON stream parsing
  - Cursor PTY approval prompt parsing
  - resume and rollback checkpoint handling
- Orchestration ingestion tests for both providers covering:
  - `turn.plan.updated`
  - `turn.proposed.completed`
  - approval request/resolution
  - user-input request/resolution
  - diff/checkpoint projection
  - revert trimming of messages, activities, and proposed plans
- Web tests for:
  - provider picker availability
  - settings model sections
  - provider banner labels
  - plan sidebar behavior with Claude/Cursor events
- Integration harnesses should use fake `claude` and `cursor-agent` binaries/transcripts so parity is deterministic.
- Acceptance bar: the same thread-level scenarios currently passing for real/fake Codex must pass for Claude CLI and Cursor, except for Codex-only traits like reasoning effort / fast mode.

## Assumptions / Defaults

- Chosen strategy: `Claude CLI-first`, not SDK-first.
- Chosen rollout: `flag until parity`.
- Chosen Cursor strategy: `hybrid adapter` because Cursor’s official non-interactive docs expose structured output and resume, but not an official machine-readable approval callback.
- Cursor built-in models will start with `auto` only because Cursor’s official docs do not publish a stable model catalog suitable for hardcoding.
- Plan-mode parity for Claude/Cursor will be implemented through internal MCP tools plus `<proposed_plan>` fallback, not by waiting for upstream native plan events.
- No database migration is required.

## External Constraints

- Cursor CLI parameters / resume / MCP: https://docs.cursor.com/en/cli/reference/parameters
- Cursor CLI MCP support: https://docs.cursor.com/cli/mcp
- Cursor tool approvals / MCP approvals / guardrails: https://docs.cursor.com/en/context/mcp and https://docs.cursor.com/agent/tools
- Claude Code CLI reference (`--print`, `--output-format`, `--resume`, `--permission-prompt-tool`): https://docs.anthropic.com/en/docs/claude-code/cli-reference
- Claude Code SDK docs note that plan mode is not yet supported in the SDK; this is why the plan switches Claude to CLI-first.
- Codex app-server reference for current parity target: https://developers.openai.com/codex/sdk/#app-server
