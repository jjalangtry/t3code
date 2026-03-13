# Provider-Native GUI Plan

## Goal

Make `codex`, `claudeCode`, and `cursor` all feel native in this GUI without fragmenting the product into three separate apps.

That means:

- preserve provider-native modes, model controls, approvals, edit flows, and session behaviors
- keep one shared orchestration model for chat, plans, approvals, diffs, and thread history
- avoid baking Codex-specific assumptions into contracts and UI state

This document complements `cursor-claude-cli-codex-parity-plan.md` by adding the missing feature inventory and the abstraction layer needed to generalize all three providers.

## Sources Reviewed

Reviewed on `2026-03-13`.

- Codex:
  - `https://developers.openai.com/codex/app-server`
  - `https://developers.openai.com/codex/agent-approvals-security`
  - `https://developers.openai.com/codex/cli/reference`
  - `https://developers.openai.com/codex/cli/slash-commands`
  - `https://developers.openai.com/codex/cli/features`
  - `https://developers.openai.com/codex/app/features`
  - `https://developers.openai.com/codex/app/review`
  - `https://developers.openai.com/codex/concepts/sandboxing/`
  - `https://developers.openai.com/codex/concepts/multi-agents`
- Claude Code:
  - `https://code.claude.com/docs/en/permissions`
  - `https://docs.anthropic.com/en/docs/claude-code/cli-reference`
  - `https://docs.anthropic.com/en/docs/claude-code/settings`
  - `https://docs.anthropic.com/en/docs/claude-code/hooks`
  - `https://docs.anthropic.com/en/docs/claude-code/subagents`
- Cursor:
  - `https://cursor.com/docs/agent/overview`
  - `https://cursor.com/docs/agent/modes`
  - `https://cursor.com/help/ai-features/ask-mode`
  - `https://cursor.com/docs/agent/debug-mode`
  - `https://cursor.com/help/ai-features/max-mode`
  - `https://cursor.com/docs/agent/subagents`
  - `https://cursor.com/docs/background-agent`

Cursor's official docs are materially weaker than Codex and Claude on machine-readable approvals and CLI protocol details. Where Cursor does not publish a stable structured API surface, the plan below assumes adapter-layer normalization and explicitly treats some features as provider-native/experimental instead of universally available.

## What Exists In This Repo Today

- Contracts already reserve `ProviderKind = codex | claudeCode | cursor`.
- The runtime event model is already moving in the right direction: it is item/turn/thread oriented instead of raw provider-log oriented.
- The current abstraction is still too narrow in two important places:
  - `ProviderInteractionMode = default | plan`
  - `RuntimeMode = approval-required | full-access`
- That shape fits Codex reasonably well, but it under-models:
  - Cursor `ask` and `debug`
  - Claude `acceptEdits`, `dontAsk`, and `bypassPermissions`
  - provider-native execution environments like `worktree`, `cloud`, and `remote`
  - checkpoints, queued messages, background tasks, hooks, and subagents as first-class UX concepts

## Feature Inventory

### 1. Conversation Modes

| Capability                    | Codex                                                 | Claude Code                                                     | Cursor                                           | Shared abstraction                                 |
| ----------------------------- | ----------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------- |
| Default agent mode            | Yes                                                   | Yes                                                             | Yes                                              | `conversationMode = agent`                         |
| Plan mode                     | Yes (`/plan`, app-server collaboration/plan flows)    | Yes (`permissionMode = plan`, Plan subagent)                    | Yes (native Plan Mode)                           | `conversationMode = plan`                          |
| Ask / read-only question mode | Yes via read-only permissions, but not branded as Ask | Effectively yes via `plan` or read-only permissions             | Yes, explicit Ask Mode                           | `conversationMode = ask` plus autonomy constraints |
| Debug mode                    | Not branded as a first-class mode                     | Not branded as a first-class mode                               | Yes, explicit Debug Mode                         | `conversationMode = debug`                         |
| Review mode                   | Yes, explicit `/review` and app review pane           | No direct native review mode; can emulate via prompts/subagents | No direct dedicated review mode in reviewed docs | `conversationMode = review` as optional capability |

### 2. Autonomy / Approval Modes

| Capability            | Codex                                                             | Claude Code                                    | Cursor                                                                                                   | Shared abstraction                                              |
| --------------------- | ----------------------------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | ------- | --------------- |
| Read-only             | Yes                                                               | Yes (`plan` or deny-heavy config)              | Yes (`Ask`)                                                                                              | `autonomy.files = readOnly`, `autonomy.exec = blocked/prompted` |
| Edit with prompts     | Yes (`workspace-write` + approval policy)                         | Yes (`default`)                                | Yes                                                                                                      | `autonomy.files = prompt`, `autonomy.exec = prompt`             |
| Auto-accept edits     | Partially, via trusted workspace behavior, but not a branded mode | Yes, explicit `acceptEdits`                    | Cursor supports native auto-apply/autonomous edits, but docs are less precise on exact approval taxonomy | `autonomy.files = autoApprove`                                  |
| Trusted commands only | Yes (`untrusted`)                                                 | Via allow/ask/deny rules                       | Partially via command approvals/allowlists                                                               | `autonomy.exec = trustedOnly`                                   |
| Never ask / bypass    | Yes (`--yolo`, `danger-full-access`)                              | Yes (`bypassPermissions`)                      | Exists in product settings under auto-run / YOLO style behavior, but official docs are sparse            | `autonomy.exec = unrestricted`, `autonomy.files = unrestricted` |
| Approval scopes       | `once`, `session`, policy-based                                   | per project command rules, session edit grants | native editor approvals                                                                                  | `approvalScope = once                                           | session | persistentRule` |

### 3. Execution Environment Modes

| Capability                     | Codex                         | Claude Code                               | Cursor                                                                                    | Shared abstraction                         |
| ------------------------------ | ----------------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------ |
| Local workspace                | Yes                           | Yes                                       | Yes                                                                                       | `executionEnvironment = local`             |
| Git worktree isolation         | Yes, explicit app thread mode | Yes, `--worktree` and worktree hooks      | Not exposed in reviewed docs as a first-class mode                                        | `executionEnvironment = worktree`          |
| Cloud / remote environment     | Yes, explicit cloud mode      | Yes, remote web sessions / remote control | Yes, Cloud Agents                                                                         | `executionEnvironment = cloud` or `remote` |
| Resume inside same environment | Yes                           | Yes                                       | Partially documented; resume exists in broader CLI references but Cursor docs are thinner | `resumeStrategy` capability                |

### 4. Model Controls

| Capability          | Codex                     | Claude Code                                                         | Cursor                                                                        | Shared abstraction                        |
| ------------------- | ------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------- | ---- |
| Model picker        | Yes                       | Yes                                                                 | Yes                                                                           | `model.current`, `model.available[]`      |
| Reasoning effort    | Yes, explicit             | "Thinking" / extended thinking instead of Codex-style effort ladder | Max Mode and model choice; no stable published effort ladder in reviewed docs | `model.depth` trait                       |
| Fast mode           | Yes                       | Indirect via cheaper models and subagent model choice               | Built-in fast models + `fast` subagent model type                             | `model.speedTier` trait                   |
| Personality / style | Yes, explicit personality | Indirect via system prompt / output style                           | Indirect via rules/prompts                                                    | `model.communicationStyle` optional trait |
| Max context mode    | Not branded that way      | Not branded that way                                                | Yes, explicit Max Mode                                                        | `model.contextTier = default              | max` |

### 5. Input Modalities

| Capability               | Codex                                            | Claude Code                                | Cursor                                            | Shared abstraction                         |
| ------------------------ | ------------------------------------------------ | ------------------------------------------ | ------------------------------------------------- | ------------------------------------------ |
| Text prompt              | Yes                                              | Yes                                        | Yes                                               | shared                                     |
| Image attachments        | Yes                                              | Supported broadly in Claude Code workflows | Yes                                               | `attachments.image[]`                      |
| Steer in-flight turn     | Yes, explicit `turn/steer` and queued follow-ups | Interactive follow-ups in session          | queued and immediate messages                     | `turn.steer` and `turn.queue` capabilities |
| Ask clarifying questions | Yes, structured user-input requests              | Yes, tool/user prompts and hooks           | Yes, explicit ask questions while continuing work | `question.requested` / `question.resolved` |

### 6. Planning Artifacts

| Capability                                     | Codex              | Claude Code                      | Cursor                             | Shared abstraction     |
| ---------------------------------------------- | ------------------ | -------------------------------- | ---------------------------------- | ---------------------- |
| Live plan updates                              | Yes                | Via Plan mode + hooks/MCP bridge | Yes, native plan generation        | `turn.plan.updated`    |
| Reviewable proposed plan before implementation | Yes                | Yes                              | Yes                                | `proposedPlan` entity  |
| Save/share plan file                           | Not the primary UX | Possible by prompt/tooling       | Yes, native save-to-workspace flow | optional `plan.export` |

### 7. Edit Acceptance, Diff, and Rollback

| Capability                 | Codex                                        | Claude Code                                                          | Cursor                                              | Shared abstraction                     |
| -------------------------- | -------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------- |
| Inline diff review         | Yes, strong native support                   | Not a first-class native pane in reviewed docs                       | Yes, editor-native diff/checkpoint review           | shared diff panel where possible       |
| Accept/reject edits        | Yes                                          | Permission-driven rather than review-pane-driven                     | Yes                                                 | `editReview` capability                |
| Stage / revert hunks/files | Yes                                          | Not native in reviewed docs                                          | not clearly documented as native Git-stage UX       | Git integration trait, not universal   |
| Checkpoints                | Thread rollback + diff/checkpoint projection | Session persistence and worktrees, but no Cursor-style checkpoint UX | Yes, explicit local checkpoints                     | `checkpoint.create/restore` capability |
| Thread rollback            | Yes, explicit app-server API                 | Can emulate via local journal + resume checkpoints                   | Can emulate via local journal or native checkpoints | `thread.rollback` capability           |

### 8. Session / Thread Lifecycle

| Capability               | Codex | Claude Code                      | Cursor                                         | Shared abstraction                |
| ------------------------ | ----- | -------------------------------- | ---------------------------------------------- | --------------------------------- |
| Start new thread         | Yes   | Yes                              | Yes                                            | shared                            |
| Resume thread/session    | Yes   | Yes                              | likely yes, but docs reviewed here are thinner | shared                            |
| Fork thread              | Yes   | Yes (`--fork-session`)           | not clearly documented in reviewed docs        | `thread.fork` optional capability |
| Archive/unarchive thread | Yes   | not highlighted in reviewed docs | not highlighted in reviewed docs               | optional lifecycle capability     |

### 9. Subagents / Multi-agent / Background Work

| Capability           | Codex                                         | Claude Code                                        | Cursor                                     | Shared abstraction                                    |
| -------------------- | --------------------------------------------- | -------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------- |
| Built-in subagents   | Experimental multi-agents                     | Yes (`Explore`, `Plan`, `general-purpose`, others) | Yes (`Explore`, `Bash`, `Browser`)         | `subagent` runtime entity                             |
| Custom subagents     | Yes via config/agents                         | Yes, rich file/frontmatter model                   | Yes, rich file/frontmatter model           | shared subagent catalog with provider-native metadata |
| Background tasks     | Some via multi-agent and background terminals | Yes, background subagents                          | Yes, background subagents and Cloud Agents | `task` runtime entity                                 |
| Parallel workstreams | Yes                                           | Yes                                                | Yes                                        | shared                                                |

### 10. Hooks / Rules / Automation / MCP

| Capability                      | Codex                        | Claude Code                  | Cursor                                                                                    | Shared abstraction                        |
| ------------------------------- | ---------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------- |
| Rules / persistent instructions | `AGENTS.md`, config, skills  | `CLAUDE.md`, rules, settings | Cursor rules                                                                              | `instructionSources`                      |
| Hooks                           | Limited compared with Claude | Very rich hook lifecycle     | Cursor has rules and automation, but hook docs were not part of reviewed official sources | `hook` support as optional provider trait |
| MCP                             | Yes                          | Yes                          | Yes                                                                                       | shared MCP section                        |
| Skills / reusable actions       | Yes                          | Yes                          | Cursor uses slash commands/rules/skills-style customizations                              | `skill` capability where supported        |

## Shared Features We Should Canonicalize

These are strong enough across all three providers to become first-class product concepts:

1. Thread lifecycle
2. Turn lifecycle
3. Conversation mode
4. Autonomy / approval state
5. Model selection and model traits
6. User questions / approvals / interruptions
7. Plans and proposed plans
8. Diffs, changed files, and rollback/checkpoint history
9. Subagents/background tasks
10. Execution environment (`local`, `worktree`, `cloud`, `remote`)

## Native Features We Should Preserve Instead Of Flattening Away

These should stay provider-native in labels and UI affordances even if they map into shared primitives:

- Codex:
  - personality
  - reasoning effort
  - review mode / review pane semantics
  - worktree/local/cloud thread modes
- Claude Code:
  - `acceptEdits`
  - hooks
  - fine-grained permission rules
  - custom subagent frontmatter and memory
- Cursor:
  - Ask Mode
  - Debug Mode
  - Max Mode
  - checkpoints
  - queued messages

The rule should be:

- shared state model underneath
- provider-native names and controls at the edge

## Proposed Abstraction Layer

### A. Split "mode" into three separate concepts

The current `RuntimeMode` and `ProviderInteractionMode` are conflating different things.

Replace them conceptually with:

1. `conversationMode`
   - `agent`
   - `ask`
   - `plan`
   - `debug`
   - `review`

2. `autonomyMode`
   - not one universal enum
   - model as normalized facets plus a provider-native preset id

```ts
type NormalizedAutonomy = {
  files: "blocked" | "prompt" | "autoApprove" | "unrestricted";
  exec: "blocked" | "prompt" | "trustedOnly" | "unrestricted";
  network: "blocked" | "webOnly" | "restricted" | "unrestricted";
  approvalsBypass: boolean;
};
```

3. `executionEnvironment`
   - `local`
   - `worktree`
   - `cloud`
   - `remote`

### B. Add provider-native preset descriptors

The UI should not invent fake generic labels like "Default" when the provider has a native mode with a stronger mental model.

Add a provider capability/preset descriptor layer:

```ts
type ProviderNativePreset = {
  id: string;
  provider: ProviderKind;
  family: "conversation" | "autonomy" | "environment";
  label: string;
  description?: string;
  normalized: unknown;
  experimental?: boolean;
};
```

Examples:

- Codex `Auto`
- Codex `Read-only`
- Claude `acceptEdits`
- Cursor `Ask`
- Cursor `Debug`
- Cursor `Cloud`

### C. Move from hardcoded model lists to model descriptors

Current provider model lists are partly static. That is fine for bootstrap, but not for native-feeling parity.

Add a runtime model discovery shape:

```ts
type ProviderModelDescriptor = {
  id: string;
  label: string;
  provider: ProviderKind;
  supportsImages: boolean;
  supportsPersonality?: boolean;
  supportsThinking?: boolean;
  supportsReasoningEffort?: boolean;
  supportsMaxContext?: boolean;
  hidden?: boolean;
  default?: boolean;
  aliases?: string[];
};
```

Codex can fill this from `model/list`.
Claude can fill it from configured/allowed models.
Cursor likely starts as config-driven plus user-supplied model catalog until its docs/API surface are stable enough for reliable discovery.

### D. Add first-class task/subagent/checkpoint entities

Today these mostly leak through runtime events. They should be explicit read-model concepts:

```ts
type OrchestrationCheckpoint = {
  id: string;
  kind: "provider" | "git" | "cursor-native";
  label: string;
  restorable: boolean;
  createdAt: string;
};

type OrchestrationTask = {
  id: string;
  kind: "subagent" | "background-task" | "review" | "automation";
  status: "running" | "waiting" | "completed" | "failed";
  title: string;
  provider?: ProviderKind;
};
```

Cursor checkpoints should map directly.
Codex rollback/git checkpoints should map indirectly.
Claude can start with adapter-synthesized checkpoints based on per-turn resume journals.

### E. Generalize approvals into one "action gate" model

The current `request.opened` / `request.resolved` direction is correct. Extend the taxonomy so it covers all three cleanly:

- command execution
- file edit
- file read
- network access
- MCP/app tool action
- destructive action
- user clarification

This should become one shared UX component: `ActionGateCard`.
Provider-native wording stays in metadata.

## Concrete Contract Changes

### 1. Replace the narrow interaction enum

Current:

- `ProviderInteractionMode = default | plan`

Proposed:

- `ProviderConversationMode = agent | ask | plan | debug | review`

Then add provider-native preset ids separately instead of trying to jam native labels into the enum.

### 2. Replace `RuntimeMode` with a richer session control model

Current:

- `approval-required | full-access`

Proposed:

```ts
type ProviderSessionControl = {
  conversationMode: ProviderConversationMode;
  autonomyPresetId?: string;
  executionEnvironment?: "local" | "worktree" | "cloud" | "remote";
};
```

For backward compatibility, `runtimeMode` can be retained temporarily and derived from the richer structure.

### 3. Extend `ProviderStartOptions`

Codex:

- environment mode
- personality
- sandbox / approval / service tier traits already exist or are adjacent

Claude:

- `permissionMode`
- hook/rules/bootstrap options if needed later
- `worktree` / `remote` entrypoints

Cursor:

- binary path
- execution entrypoint choice
- max mode / model picker bridge if not expressed elsewhere

### 4. Extend `ProviderRuntimeEvent`

Add event families only where the UI needs first-class rendering:

- `conversation.mode.changed`
- `autonomy.mode.changed`
- `execution.environment.changed`
- `checkpoint.created`
- `checkpoint.restored`
- `queue.updated`
- `review.started`
- `review.finding`
- `review.completed`
- `subagent.started`
- `subagent.completed`

Do not add provider-specific raw events directly to the shared schema unless the UI actually consumes them.

## GUI Architecture

### Shared shell

Keep one shared thread UI with:

- composer
- message timeline
- plan sidebar
- diff panel
- approval/question cards
- activity rail

### Provider-native controls row

Add a provider-native controls strip above the composer:

- model picker
- conversation mode picker
- autonomy picker
- environment picker
- optional provider traits

Examples:

- Codex shows: `Model`, `Mode`, `Permissions`, `Environment`, `Reasoning`, `Personality`
- Claude shows: `Model`, `Mode`, `Permissions`, `Hooks/Tools` entrypoint
- Cursor shows: `Model`, `Mode`, `Max Mode`, `Cloud/Local`

### Provider overlays, not provider forks

Do not fork `ChatView` into three versions.
Instead:

- render from shared contracts
- attach provider-specific controls via capabilities
- attach provider-specific cards only when the provider emits them

## Server Adapter Strategy

### Codex

Keep Codex as the gold-standard structured provider.
Use it to define the canonical event contract, but stop assuming every provider can expose the same behavior natively.

### Claude Code

Use CLI-first parity:

- native permission modes map to normalized autonomy facets
- hooks stay provider-native
- subagents map to shared task entities
- structured user-input and plan updates should continue to bridge through internal MCP/control tools when native streams are insufficient

### Cursor

Use hybrid parity:

- native Ask/Plan/Debug become conversation presets
- checkpoints become first-class provider-native checkpoints
- background tasks/subagents map to shared tasks
- approvals likely require adapter-level synthesis because the public docs are weak on a stable machine callback surface

## Rollout Plan

### Phase 1. Contracts first

- add `ProviderConversationMode`
- add provider-native preset descriptors
- add richer session control shape
- add model descriptors
- add checkpoint/task entities

### Phase 2. Web state model

- update stores and settings to consume capability descriptors instead of hardcoded provider conditionals
- make picker UIs descriptor-driven
- keep existing plan sidebar and diff UI, but make them consume generalized entities

### Phase 3. Adapter normalization

- Codex: mostly expose existing structure through new descriptors
- Claude: CLI-first adapter + internal control bridge
- Cursor: native mode mapping + checkpoint/task mapping + approval synthesis

### Phase 4. Native-feel polish

- provider-native labels and help text
- provider-specific controls
- provider-specific empty/loading/error states
- per-provider docs links in settings

### Phase 5. Feature gating

- ship behind per-provider parity flags
- do not expose partial providers as if they are complete
- acceptance bar is thread-level scenario parity, not "the picker appears"

## Recommended Acceptance Bar

Each provider should pass the same end-to-end GUI scenarios where the provider actually supports the underlying behavior:

1. create thread
2. change model
3. switch into plan-like mode
4. ask a question with image attachment
5. receive plan updates
6. approve or deny an action
7. accept edits and inspect diff
8. interrupt and resume work
9. restore a prior checkpoint or rollback state
10. launch background/subagent work

Provider-specific additions:

- Codex: review mode, worktree/local/cloud, personality, reasoning effort
- Claude: `acceptEdits`, hooks visibility, fine-grained permission rules, subagent scope
- Cursor: Ask/Plan/Debug, Max Mode, checkpoints, queued messages, Cloud Agents

## Immediate Repo Changes I Recommend

1. Treat `cursor-claude-cli-codex-parity-plan.md` as the short execution plan.
2. Use this document as the product/contract design reference.
3. Next implementation task should be a contract pass:
   - replace `ProviderInteractionMode`
   - introduce provider-native preset descriptors
   - add execution environment and checkpoint/task entities

That ordering will prevent the UI from hardcoding the wrong abstractions a second time.
