# Fork Sync Workflow

This fork tracks `pingdotgg/t3code` as the source of truth while keeping local customizations on top.

## Branching model

- `main`: mirror of upstream sync points.
- `fork/custom`: local customizations (iOS app, provider adapters, UI additions).

Keep custom changes in small, focused commits so rebases are easier to resolve.

## One-time setup

```bash
git remote add upstream https://github.com/pingdotgg/t3code.git
git fetch upstream --tags
git checkout -b fork/custom
```

## Regular sync

```bash
bash scripts/sync-upstream.sh --branch fork/custom --tag-prefix synced
```

What it does:

1. Verifies clean working tree.
2. Fetches upstream tags.
3. Rebases `fork/custom` onto `upstream/main` with `rerere` enabled for this operation.
4. Creates/updates a local `synced/*` tag pointing at the rebased head.

Push after review:

```bash
git push --force-with-lease origin fork/custom
```

## Dry run

```bash
bash scripts/sync-upstream.sh --branch fork/custom --dry-run
```

## Conflict policy

- Resolve conflicts in favor of upstream behavior unless local behavior is intentionally divergent.
- If upstream introduces equivalent functionality, drop the local customization commit during rebase.
- Prefer wrappers/new files over direct edits to upstream-heavy files (`wsServer`, contracts, shared configs).
