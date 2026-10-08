#!/usr/bin/env bash
# =============================================================================
# pre-push-guard.sh — refuse pushes that would re-pollute the repo with large
# or misplaced files.
#
# WHY: 2026-10-04 incident — STL-mesh SVGs (50-460 MB each) were written into
# Comserv/root/static/images/3d/library/ and committed. They exceeded GitHub's
# 100 MB/file limit, blocked every push (GH001 / pre-receive hook declined),
# and forced a full history rewrite (git-filter-repo --strip-blobs-bigger-than
# 50M) across main/3d/planning.
#
# WHAT IT ENFORCES (on `git push`):
#   1. New blobs > MAX_BLOB_MB (default 20 MB) are refused outright.
#   2. Any commit that ADDS a file under the ignored upload dirs listed in
#      BLOCKED_DIRS is refused (files must go to NFS via the File Management
#      system, not the repo tree).
#   3. The 3d/library extension block: any file matching EXT_BLOCKPATTERNS in
#      those dirs is refused even if small (mesh SVGs are regenerable; PNG
#      thumbnails belong on NFS).
#
# INSTALL (per checkout — hooks are not versioned):
#   Script lives at <repo>/script/pre-push-guard.sh. Either:
#     a) cp script/pre-push-guard.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push
#     b) git config core.hooksPath script/hooks   (then place this as
#        script/hooks/pre-push) — shares ONE installed hook across machines.
#   Since AI agents commonly bypass hooks, ALSO keep the .gitignore rules —
#   this guard is the second layer, the .gitignore is the first.
#
# The hook receives, on stdin, lines of the form:
#   <local ref> <local sha> <remote ref> <remote sha>
# For each pushed ref we diff its commits against the remote base and inspect
# the added files. A push that only moves the same ref forward is checked
# against the remote tip; a brand-new ref is diffed from the merge-base with
# origin/main (so a giant committed months ago is not re-sent).
# =============================================================================
set -u

MAX_BLOB_MB="${MAX_BLOB_MB:-20}"
MAX_BYTES=$((MAX_BLOB_MB * 1024 * 1024))

# Upload/asset dirs that must NEVER hold committed files (relative to repo root).
BLOCKED_DIRS=(
  'Comserv/root/static/images/3d/library'
  'Comserv/root/uploads'
)

# Extension patterns that are regenerable/served-from-NFS and must not be
# committed under the blocked dirs (case-insensitive match on basename).
EXT_BLOCKPATTERNS=(
  '*.svg'
)

repo_top="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
z40='0000000000000000000000000000000000000000'

fail() {
  echo "pre-push-guard: REFUSING PUSH: $1" >&2
  echo "pre-push-guard: fix: remove the offending file(s) from the commits, or"
  echo "pre-push-guard: move the data to NFS via the File Management system (see"
  echo "pre-push-guard: .hermes/plans/2026-10-04-file-management-3d-library.md)." >&2
  exit 1
}

# is_new_blob <sha> : true if the blob exists and is larger than MAX_BYTES
is_new_blob() {
  local sha="$1" size
  size="$(git cat-file -s "$sha" 2>/dev/null || echo 0)"
  [ "$size" -gt "$MAX_BYTES" ]
}

# check_ref <local_ref> <local_sha> <remote_ref> <remote_sha>
check_ref() {
  local local_ref="$1" local_sha="$2" remote_ref="$3" remote_sha="$4"
  local base="" range=""

  # Branch-delete / empty pushes are fine.
  [ "$local_sha" = "$z40" ] && return 0

  if [ "$remote_sha" = "$z40" ]; then
    # New ref: base = merge-base with origin/main (if known), else parent of first commit.
    base="$(git merge-base --fork-point origin/main "$local_sha" 2>/dev/null \
            || git merge-base origin/main "$local_sha" 2>/dev/null || echo '')"
    if [ -z "$base" ]; then
      base="$(git rev-list --max-parents=0 "$local_sha" 2>/dev/null | head -1)"
    fi
    [ -z "$base" ] && base="$(git rev-parse "$local_sha^" 2>/dev/null)"
    range="${base}..${local_sha}"
  else
    range="${remote_sha}..${local_sha}"
  fi

  # No new commits → nothing to vet.
  git rev-list --count "$range" >/dev/null 2>&1 || return 0

  # 1) giant blobs
  local bad_blob
  bad_blob="$(git rev-list --objects "$range" 2>/dev/null \
    | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' \
    | awk -v m="$MAX_BYTES" '$1=="blob" && $2>m {print $2, $3}' | head -5)"
  if [ -n "$bad_blob" ]; then
    fail "commit(s) $range add blobs > ${MAX_BLOB_MB}MB:${NL}$bad_blob"
  fi

  # 2) additions inside blocked dirs (any file)
  local dir pat
  for dir in "${BLOCKED_DIRS[@]}"; do
    local added
    added="$(git diff --name-only --diff-filter=A "$range" -- "$dir" 2>/dev/null | head -10)"
    if [ -n "$added" ]; then
      fail "additions under blocked dir '$dir':${NL}$added"
    fi
  done

  # 3) extension blockpatterns inside blocked dirs (defense in depth)
  for pat in "${EXT_BLOCKPATTERNS[@]}"; do
    local hit
    hit="$(git diff --name-only --diff-filter=A "$range" 2>/dev/null \
      | grep -iE "/[^/]*${pat#\*}" | head -10)"
    if [ -n "$hit" ]; then
      fail "files matching '$pat' would be added:$NL$hit"
    fi
  done

  return 0
}

NL=$'\n'
failures=0
while read -r local_ref local_sha remote_ref remote_sha; do
  # Only vet branch refs (skip tags/notes).
  case "$local_ref" in refs/heads/*) ;; *) continue ;; esac
  if ! check_ref "$local_ref" "$local_sha" "$remote_ref" "$remote_sha"; then
    failures=1
  fi
done

exit $failures