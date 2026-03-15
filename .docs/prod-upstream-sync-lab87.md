# Production Upstream Sync Runbook (`lab87`)

This runbook explains how to keep this fork up to date with upstream and safely deploy to production on `jjalangtry@lab87`.

## What the new sync system changes

- It changes **release preparation** (how code is synced before deploy).
- It does **not** change runtime behavior in production by itself.
- Production still runs whichever commit/branch you deploy.

## Source-of-truth model

- Upstream repository: `pingdotgg/t3code` (authoritative base).
- Custom branch: `fork/custom` (your backend/web/iOS additions).
- Deployment branch on server: `fork/custom` (recommended).

## Why deployment flow changes

`scripts/sync-upstream.sh` uses a **rebase** workflow.
Rebase rewrites branch history, so production should use:

- `git fetch`
- `git reset --hard origin/fork/custom`

instead of plain `git pull`.

## Standard release flow

## Primary operation mode for this project

In this project, sync/deploy is often performed **directly on `lab87`**. Treat the server as the working deployment host:

1. Sync branch on `lab87`.
2. Validate on `lab87`.
3. Restart `t3code` on `lab87`.

Use the local-machine flow only when you intentionally prepare and push from another machine first.

### 1) Local: sync custom branch onto upstream

From repo root:

```bash
bash scripts/sync-upstream.sh --branch fork/custom --tag-prefix synced
```

### 2) Local: validate before deploy

```bash
bun fmt
bun lint
bun typecheck
```

### 3) Local: push deploy branch

```bash
git push --force-with-lease origin fork/custom
```

### 4) Server (`lab87`): deploy exact branch state

```bash
ssh jjalangtry@lab87
cd /path/to/t3code
git fetch origin
git checkout fork/custom
git reset --hard origin/fork/custom
```

Then run your normal build/restart path (example only):

```bash
bun install
bun run build
# restart app with your process manager:
# pm2 restart <name>
# or systemctl restart <service>
# or docker compose up -d --build
```

## Direct-on-`lab87` sync + restart flow (frequent path)

```bash
ssh jjalangtry@lab87
cd /path/to/t3code
git fetch upstream --tags
git fetch origin
git checkout fork/custom
git -c rerere.enabled=true rebase upstream/main
git push --force-with-lease origin fork/custom

# validation gates
bun fmt
bun lint
bun typecheck

# restart t3code (choose your manager)
# pm2 restart <name>
# systemctl restart <service>
# docker compose up -d --build
```

If rebase conflicts occur, resolve on `lab87`, continue rebase, then run the same validation + restart steps.

## Notes for reverse proxy / Tailscale

- No reverse-proxy or Tailscale changes are required for this sync model.
- `code.jjalangtry.com` routing is unaffected.

## Rollback strategy

- Tag deployed commits (example: `prod-2026-03-15-1`).
- To rollback on server:

```bash
git fetch --tags
git checkout fork/custom
git reset --hard <rollback-tag-or-sha>
```

Then rebuild/restart normally.

## Automation section (for another model/agent)

Use this exact sequence:

1. Run local sync script:
   - `bash scripts/sync-upstream.sh --branch fork/custom --tag-prefix synced`
2. Run gates:
   - `bun fmt && bun lint && bun typecheck`
3. Push deploy branch:
   - `git push --force-with-lease origin fork/custom`
4. SSH to prod and deploy branch tip:
   - `git fetch origin`
   - `git checkout fork/custom`
   - `git reset --hard origin/fork/custom`
5. Rebuild/restart using the existing process manager.

Critical rule for agents: because rebase is used, **never rely on `git pull` in production**.
Frequent-mode note: this entire process may run directly on `lab87` followed by a `t3code` restart.
