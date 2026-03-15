#!/usr/bin/env bash
set -euo pipefail

# Keep fork/custom rebased on top of upstream/main without mutating git config.
# Usage:
#   scripts/sync-upstream.sh
#   scripts/sync-upstream.sh --branch fork/custom --tag-prefix synced

branch="fork/custom"
upstream_remote="upstream"
upstream_branch="main"
tag_prefix="synced"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      branch="${2:-}"
      shift 2
      ;;
    --upstream-remote)
      upstream_remote="${2:-}"
      shift 2
      ;;
    --upstream-branch)
      upstream_branch="${2:-}"
      shift 2
      ;;
    --tag-prefix)
      tag_prefix="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$branch" || -z "$upstream_remote" || -z "$upstream_branch" || -z "$tag_prefix" ]]; then
  echo "Invalid empty argument." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Must be run inside a git repository." >&2
  exit 1
fi

if ! git remote get-url "$upstream_remote" >/dev/null 2>&1; then
  echo "Missing remote '$upstream_remote'. Configure it first." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes first." >&2
  exit 1
fi

git fetch "$upstream_remote" --tags
git checkout "$branch"

if [[ "$dry_run" == "true" ]]; then
  echo "[dry-run] would run: git -c rerere.enabled=true rebase ${upstream_remote}/${upstream_branch}"
  exit 0
fi

git -c rerere.enabled=true rebase "${upstream_remote}/${upstream_branch}"

if git describe --tags --exact-match "${upstream_remote}/${upstream_branch}" >/dev/null 2>&1; then
  upstream_tag="$(git describe --tags --exact-match "${upstream_remote}/${upstream_branch}")"
  git tag -f "${tag_prefix}/${upstream_tag}" HEAD
else
  short_sha="$(git rev-parse --short "${upstream_remote}/${upstream_branch}")"
  git tag -f "${tag_prefix}/${upstream_branch}-${short_sha}" HEAD
fi

echo "Rebase complete on branch '${branch}'."
echo "Review and push with:"
echo "  git push --force-with-lease origin ${branch}"
