#!/usr/bin/env bash
# scripts/patch-tags.sh
#
# For every upstream kanidm release tag, maintains a local tag of the same name
# whose commit descends from both the upstream release and all patches/vMAJOR/*
# branches for that major version.
#
# Idempotent: tags that already satisfy the ancestry conditions are skipped.
# Tags older than the patch branch base are skipped (building them would pull in
# unintended upstream changes).
#
# Usage:
#   ./scripts/patch-tags.sh [--dry-run]
#
# Environment:
#   UPSTREAM_URL     git URL for upstream kanidm
#                    (default: https://github.com/kanidm/kanidm.git)
#
# Output:
#   Progress lines on stdout.
#   Exits 0 if all eligible tags are up to date or were built successfully.
#   Exits 1 if one or more tags failed; failing tag names are printed on lines
#   prefixed with "FAIL ".

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/kanidm/kanidm.git}"
UPSTREAM_REMOTE="upstream"
UPSTREAM_NS="refs/upstream_tags"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

log() { echo "$@"; }

# ---------------------------------------------------------------------------
# Upstream fetch
# ---------------------------------------------------------------------------

fetch_upstream() {
  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi
  log "Fetching upstream tags..."
  # Store in a private namespace to avoid clobbering our patched local tags.
  git fetch "$UPSTREAM_REMOTE" "+refs/tags/*:${UPSTREAM_NS}/*" --no-tags --quiet
}

# ---------------------------------------------------------------------------
# Tag enumeration and filtering
# ---------------------------------------------------------------------------

# All upstream release tags: strict semver vMAJOR.MINOR.PATCH, MAJOR >= 1.
# No pre-release suffixes (alpha, beta, rc, etc.).
release_tags() {
  git for-each-ref "${UPSTREAM_NS}/v*" --format='%(refname)' \
    | sed "s|^${UPSTREAM_NS}/||" \
    | grep -E '^v[1-9][0-9]*\.[0-9]+\.[0-9]+$' \
    | sort -V
}

major_of() { echo "${1#v}" | cut -d. -f1; }

patches_for_major() {
  git branch --list "patches/v${1}/*" --format='%(refname:short)'
}

# ---------------------------------------------------------------------------
# Ancestry checks
# ---------------------------------------------------------------------------

# True if the local tag already descends from the upstream commit and every
# patch branch tip — meaning it is current and needs no rebuild.
tag_is_current() {
  local tag="$1"; shift
  local patch_branches=("$@")

  git rev-parse "refs/tags/${tag}" >/dev/null 2>&1 || return 1

  local local_commit upstream_commit
  local_commit=$(git rev-parse "refs/tags/${tag}^{commit}")
  upstream_commit=$(git rev-parse "${UPSTREAM_NS}/${tag}^{commit}")

  git merge-base --is-ancestor "$upstream_commit" "$local_commit" || return 1

  local branch
  for branch in "${patch_branches[@]}"; do
    git merge-base --is-ancestor "${branch}^{commit}" "$local_commit" || return 1
  done
}

# True if the upstream tag is at or after the base commit of every patch
# branch. If not, merging the patch into this tag would pull in unintended
# upstream changes (the patch was created against a newer release).
tag_is_patchable() {
  local tag="$1"; shift
  local patch_branches=("$@")

  local upstream_commit
  upstream_commit=$(git rev-parse "${UPSTREAM_NS}/${tag}^{commit}")

  local branch
  for branch in "${patch_branches[@]}"; do
    # The first parent of the patch branch tip is the upstream commit it was
    # based on. The upstream tag must be a descendant of (or equal to) that
    # base commit for a clean merge.
    local branch_base
    if ! branch_base=$(git rev-parse "${branch}^" 2>/dev/null); then
      continue  # orphan branch; skip the check
    fi
    git merge-base --is-ancestor "$branch_base" "$upstream_commit" || return 1
  done
}

# ---------------------------------------------------------------------------
# Tag construction
# ---------------------------------------------------------------------------

# Creates (or force-updates) a local tag for one upstream release by merging
# all given patch branches into a worktree rooted at the upstream commit.
# Returns 0 on success, 1 if any merge fails.
build_tag() {
  local tag="$1"; shift
  local patch_branches=("$@")

  local work_dir
  work_dir=$(mktemp -d)

  git worktree add --detach --quiet "${work_dir}" "${UPSTREAM_NS}/${tag}"

  local rc=0
  (
    cd "${work_dir}"
    git config user.email "patch-tags@local"
    git config user.name  "patch-tags"
    local branch
    for branch in "${patch_branches[@]}"; do
      if ! git merge --no-ff --quiet -m "Merge ${branch}" "${branch}"; then
        git merge --abort 2>/dev/null || true
        log "    conflict while merging ${branch}"
        exit 1
      fi
    done
    git tag -f "${tag}" HEAD
  ) || rc=$?

  git worktree remove --force "${work_dir}" 2>/dev/null || rm -rf "${work_dir}"
  return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local failed=() built=() skipped=0

  fetch_upstream

  mapfile -t tags < <(release_tags)
  log "Upstream release tags found: ${#tags[@]}"

  local tag
  for tag in "${tags[@]}"; do
    local major
    major=$(major_of "$tag")

    local patches
    mapfile -t patches < <(patches_for_major "$major")

    if [[ ${#patches[@]} -eq 0 ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if ! tag_is_patchable "$tag" "${patches[@]}"; then
      log "  skip   $tag  (predates patch branch base — update patches/v${major}/* to support this release)"
      skipped=$((skipped + 1))
      continue
    fi

    if tag_is_current "$tag" "${patches[@]}"; then
      log "  ok     $tag"
      continue
    fi

    log "  build  $tag ..."

    if [[ $DRY_RUN -eq 1 ]]; then
      log "         (dry run — would merge: ${patches[*]})"
      built+=("$tag")
      continue
    fi

    if build_tag "$tag" "${patches[@]}"; then
      log "         done"
      built+=("$tag")
    else
      log "  FAIL   $tag"
      failed+=("$tag")
    fi
  done

  [[ $skipped -gt 0 ]] && log "($skipped tag(s) skipped)"

  if [[ ${#built[@]} -gt 0 ]]; then
    log ""
    log "Built: ${built[*]}"
  fi

  if [[ ${#failed[@]} -gt 0 ]]; then
    log ""
    log "The following tags failed due to merge conflicts:"
    local t
    for t in "${failed[@]}"; do
      log "FAIL $t"
    done
    return 1
  fi

  return 0
}

main "$@"
