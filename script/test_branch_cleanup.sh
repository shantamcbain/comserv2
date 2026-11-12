#!/usr/bin/env bash
# Self-test for branch_cleanup.sh using a THROWAWAY local bare "origin" in /tmp. Never touches GitHub.
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)/branch_cleanup.sh"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
export COMSERV_BACKUP_DIR="$T/bk" COMSERV_REPORT_DIR="$T/rep"
git init -q --bare "$T/o.git"; git init -q -b main "$T/w"; cd "$T/w"; git remote add origin "$T/o.git"
OLD="2025-01-01T00:00:00"; mk() { GIT_COMMITTER_DATE="$2" GIT_AUTHOR_DATE="$2" git commit -q --allow-empty -m "$1"; }
mk base "$OLD"; git branch merged-old; git branch merged-new
git checkout -q -b unmerged-old; mk u "$OLD"; git checkout -q main
git checkout -q -b keepme; git checkout -q main; git branch -D keepme -q   # keepme only listed in keep-file below
git branch keepme; mk onmain "$(date -Iseconds)"; git branch -f merged-new main
git push -q origin main merged-old merged-new unmerged-old keepme
echo keepme > "$T/keep.txt"
fail() { echo "FAIL: $*" >&2; exit 1; }
heads() { git ls-remote --heads origin | wc -l; }
[ "$(heads)" = 5 ] || fail "setup"
"$S" --keep-file "$T/keep.txt" > "$T/dry.out"; [ "$(heads)" = 5 ] || fail "dry-run deleted something"
grep -q 'remote DELETE-merged-stale *merged-old' "$T/dry.out" || fail "merged-old not planned"
grep -q 'remote UNMERGED-stale *unmerged-old' "$T/dry.out" || fail "unmerged-old not classified"
grep -q 'remote KEEP-merged-recent *merged-new' "$T/dry.out" || fail "merged-new not kept"
grep -q 'remote KEEP-keepfile *keepme' "$T/dry.out" || fail "keep-file ignored"
[ ! -d "$T/bk" ] || fail "dry-run made a backup dir"
echo no | "$S" --execute --no-local --keep-file "$T/keep.txt" > /dev/null 2>&1 && fail "execute without DELETE confirmation succeeded"; [ "$(heads)" = 5 ] || fail "aborted run deleted"
ls "$T"/bk/*.bundle >/dev/null || fail "no bundle written before prompt"
"$S" --execute --yes --no-local --keep-file "$T/keep.txt" > "$T/exec.out" 2>&1 || { cat "$T/exec.out"; fail "execute failed"; }; cat "$T/exec.out" >&2
git ls-remote --heads origin | grep -q "refs/heads/merged-old$" && fail "merged-old still there"
for b in main unmerged-old merged-new keepme; do git ls-remote --heads origin | grep -q "refs/heads/$b\$" || fail "$b wrongly deleted"; done
echo "approved" ; echo unmerged-old > "$T/ok.txt"
"$S" --execute --yes --no-local --keep-file "$T/keep.txt" --approved-unmerged "$T/ok.txt" > /dev/null
git ls-remote --heads origin | grep -q "refs/heads/unmerged-old$" && fail "approved unmerged not deleted"
echo "PASS branch_cleanup.sh self-test"
