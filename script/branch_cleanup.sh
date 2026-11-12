#!/usr/bin/env bash
# branch_cleanup.sh - plan (and, only with --execute, perform) removal of stale branches.
# Owner: Code Guard. Design: docs/security/branch-cleanup-plan.txt
#
# DEFAULT IS DRY-RUN: reads GitHub (git ls-remote only) and local refs, prints the plan and
# the exact delete commands, writes them to a file. Changes NOTHING.
#
#   script/branch_cleanup.sh                      # dry-run, remote + local plan
#   script/branch_cleanup.sh --stale-days 90      # change the age cut-off (default 60)
#   script/branch_cleanup.sh --execute            # really delete (needs backup bundle, asks to type DELETE)
#   script/branch_cleanup.sh --execute --yes      # same, no typed confirmation (for Shanta's explicit OK only)
#
# Options: --remote NAME (origin)  --keep-file F (branch names to always keep, one per line)
#          --approved-unmerged F (unmerged branch names the OWNER approved for deletion)
#          --local / --no-local (include local branches; default include)  --backup-dir D (~/.comserv/backups)
#
# Categories (same for remote and local):
#   KEEP-main / KEEP-default      main and the remote's default branch
#   KEEP-registered               listed in Comserv/root/config/worktrees.json or checked out in `git worktree list`
#   KEEP-keepfile                 named in --keep-file
#   KEEP-merged-recent            merged but newer than --stale-days
#   DELETE-merged-stale           merged into main AND older than --stale-days   -> deleted on --execute
#   UNMERGED(-stale)              has commits main lacks -> NEVER deleted unless named in --approved-unmerged
#   UNKNOWN                       commit not present locally (run: git fetch origin) -> skipped
# "Merged" means: remote branches vs <remote>/main as listed by GitHub now; local branches vs local main.
#
# Safety: --execute first writes `git bundle create --all` + a name/sha restore list to the backup dir,
# verifies the bundle, and aborts if that fails. Remote deletes are one `git push REMOTE --delete NAME` each.
# Never rewrites history, never force-pushes, never touches main. No secret values are read or printed.
set -euo pipefail

EXECUTE=0; YES=0; REMOTE=origin; STALE=60; DO_LOCAL=1; KEEPFILE=""; APPROVED=""
BACKUP_DIR="${COMSERV_BACKUP_DIR:-$HOME/.comserv/backups}"
OUT_DIR="${COMSERV_REPORT_DIR:-$HOME/.comserv/work/codeguard/reports}"
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;; --yes) YES=1 ;; --dry-run) EXECUTE=0 ;;
    --remote) REMOTE="$2"; shift ;; --stale-days) STALE="$2"; shift ;;
    --keep-file) KEEPFILE="$2"; shift ;; --approved-unmerged) APPROVED="$2"; shift ;;
    --local) DO_LOCAL=1 ;; --no-local) DO_LOCAL=0 ;; --backup-dir) BACKUP_DIR="$2"; shift ;;
    -h|--help) sed -n 2,28p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done
[[ "$STALE" =~ ^[0-9]+$ ]] || { echo "--stale-days must be a number" >&2; exit 2; }

TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
COMMON=$(git rev-parse --git-common-dir)          # same answer from any worktree
NOW=$(date +%s); CUTOFF=$((NOW - STALE*86400)); STAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT_DIR"; CMDS="$OUT_DIR/branch-cleanup-commands-$STAMP.txt"; : > "$CMDS"; chmod 600 "$CMDS"

# --- inputs (read-only) ---
LS=$(git ls-remote --heads "$REMOTE")                                   # sha<TAB>refs/heads/name
DEFAULT=$(git ls-remote --symref "$REMOTE" HEAD | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}')
RMAIN=$(printf '%s\n' "$LS" | awk '$2=="refs/heads/main"{print $1}')
[ -n "$RMAIN" ] || { echo "no main on $REMOTE; refusing" >&2; exit 1; }
git cat-file -e "$RMAIN^{commit}" 2>/dev/null || { echo "remote main $RMAIN not local; run: git fetch $REMOTE" >&2; exit 1; }
REG=$(perl -MJSON::PP -e 'local $/; open my $f,"<",$ARGV[0] or exit; my $d=decode_json(<$f>); print "$_\n" for sort keys %{$d->{branches}||{}}' \
      "$TOP/Comserv/root/config/worktrees.json" 2>/dev/null || true)
WTB=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2);print $2}')
KEEPS=$( { printf '%s\n' main "$DEFAULT"; printf '%s\n' "$REG" "$WTB"; [ -n "$KEEPFILE" ] && cat "$KEEPFILE"; true; } | sed '/^$/d' | sort -u)
APPR=""; [ -n "$APPROVED" ] && APPR=$(sed '/^$/d' "$APPROVED")
in_list() { printf '%s\n' "$2" | grep -Fxq -- "$1"; }

classify() {  # name sha basecommit -> prints "CATEGORY<TAB>last_date<TAB>author"
  local n="$1" s="$2" base="$3" ct an
  if ! git cat-file -e "$s^{commit}" 2>/dev/null; then printf 'UNKNOWN\t?\t?\n'; return; fi
  ct=$(git log -1 --format=%ct "$s"); an=$(git log -1 --format=%an "$s")
  local d; d=$(date -d "@$ct" +%F)
  local cat
  if   [ "$n" = main ]; then cat=KEEP-main
  elif [ "$n" = "$DEFAULT" ]; then cat=KEEP-default
  elif in_list "$n" "$REG" || in_list "$n" "$WTB"; then cat=KEEP-registered
  elif [ -n "$KEEPFILE" ] && grep -Fxq -- "$n" "$KEEPFILE"; then cat=KEEP-keepfile
  elif git merge-base --is-ancestor "$s" "$base"; then
       if [ "$ct" -lt "$CUTOFF" ]; then cat=DELETE-merged-stale; else cat=KEEP-merged-recent; fi
  else if [ "$ct" -lt "$CUTOFF" ]; then cat=UNMERGED-stale; else cat=UNMERGED; fi
  fi
  printf '%s\t%s\t%s\n' "$cat" "$d" "$an"
}

REMOTE_DEL=(); LOCAL_DEL=(); declare -A CNT
echo "== Remote branches on $REMOTE (live from GitHub): $(printf '%s\n' "$LS" | wc -l); default=$DEFAULT; stale cut-off=${STALE}d =="
while IFS=$'\t' read -r sha ref; do
  n=${ref#refs/heads/}
  IFS=$'\t' read -r c d a < <(classify "$n" "$sha" "$RMAIN")
  if [ "$c" = UNMERGED-stale ] || [ "$c" = UNMERGED ]; then
    if [ -n "$APPR" ] && in_list "$n" "$APPR"; then c="$c+OWNER-APPROVED"; fi
  fi
  CNT[$c]=$(( ${CNT[$c]:-0} + 1 ))
  printf 'remote %-26s %-42s %s %s\n' "$c" "$n" "$d" "$a"
  case "$c" in DELETE-merged-stale|*+OWNER-APPROVED) REMOTE_DEL+=("$n|$sha") ;; esac
done <<< "$LS"

if [ "$DO_LOCAL" = 1 ]; then
  echo "== Local branches (merged = into local main) =="
  while IFS='|' read -r n sha; do
    IFS=$'\t' read -r c d a < <(classify "$n" "$sha" main)
    if [ "$c" = UNMERGED-stale ] || [ "$c" = UNMERGED ]; then
      if [ -n "$APPR" ] && in_list "$n" "$APPR"; then c="$c+OWNER-APPROVED"; fi
    fi
    CNT["local:$c"]=$(( ${CNT["local:$c"]:-0} + 1 ))
    printf 'local  %-26s %-42s %s %s\n' "$c" "$n" "$d" "$a"
    case "$c" in DELETE-merged-stale) LOCAL_DEL+=("$n|$sha|d") ;; *+OWNER-APPROVED) LOCAL_DEL+=("$n|$sha|D") ;; esac
  done < <(git for-each-ref refs/heads --format='%(refname:short)|%(objectname)')
fi

echo "== Summary =="; for k in $(printf '%s\n' "${!CNT[@]}" | sort); do printf '  %-40s %s\n' "$k" "${CNT[$k]}"; done

{
  echo "# Generated $(date '+%F %T %Z') by branch_cleanup.sh (dry-run list; nothing has been run)"
  echo "# Restore any remote branch:  git push $REMOTE <sha>:refs/heads/<name>   (shas in restore list / bundle)"
  for e in "${REMOTE_DEL[@]:-}"; do [ -n "$e" ] || continue; echo "git push $REMOTE --delete ${e%%|*}   # was ${e##*|}"; done
  for e in "${LOCAL_DEL[@]:-}"; do [ -n "$e" ] || continue; IFS='|' read -r n s f <<< "$e"; echo "git branch -$f $n   # was $s"; done
} > "$CMDS"
echo "Delete commands (${#REMOTE_DEL[@]} remote, ${#LOCAL_DEL[@]} local) written to: $CMDS"

if [ "$EXECUTE" != 1 ]; then
  echo "DRY-RUN: nothing was changed. Review the list, then re-run with --execute."; exit 0
fi

# ---------------- EXECUTE ----------------
[ $(( ${#REMOTE_DEL[@]} + ${#LOCAL_DEL[@]} )) -gt 0 ] || { echo "nothing to delete"; exit 0; }
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
BUNDLE="$BACKUP_DIR/branch-cleanup-$STAMP.bundle"; RESTORE="$BACKUP_DIR/branch-cleanup-$STAMP.restore.txt"
echo "Backing up ALL refs -> $BUNDLE"
git bundle create "$BUNDLE" --all >/dev/null 2>&1 || { echo "bundle failed; NOTHING deleted" >&2; exit 1; }
git bundle verify "$BUNDLE" >/dev/null 2>&1 || { echo "bundle did not verify; NOTHING deleted" >&2; exit 1; }
sha256sum "$BUNDLE" > "$BUNDLE.sha256"; chmod 600 "$BUNDLE" "$BUNDLE.sha256"
{ for e in "${REMOTE_DEL[@]:-}"; do [ -n "$e" ] && echo "remote ${e%%|*} ${e##*|}"; done
  for e in "${LOCAL_DEL[@]:-}";  do [ -n "$e" ] && { IFS='|' read -r n s f <<< "$e"; echo "local $n $s"; }; done; } > "$RESTORE"
chmod 600 "$RESTORE"
echo "Bundle verified ($(du -h "$BUNDLE" | cut -f1)); restore list: $RESTORE"
if [ "$YES" != 1 ]; then
  read -r -p "Type DELETE to remove ${#REMOTE_DEL[@]} remote and ${#LOCAL_DEL[@]} local branches: " ans
  [ "$ans" = DELETE ] || { echo "aborted; nothing deleted"; exit 1; }
fi
fail=0
for e in "${REMOTE_DEL[@]:-}"; do [ -n "$e" ] || continue; n=${e%%|*}
  if git push "$REMOTE" --delete "$n" >/dev/null 2>&1; then echo "deleted remote $n"; else echo "FAILED remote $n" >&2; fail=1; fi
done
for e in "${LOCAL_DEL[@]:-}"; do [ -n "$e" ] || continue; IFS='|' read -r n s f <<< "$e"
  if git branch -"$f" "$n" >/dev/null 2>&1; then echo "deleted local $n"; else echo "FAILED local $n" >&2; fail=1; fi
done
git worktree prune
echo "Done (failures=$fail). Undo: git bundle unbundle / git push $REMOTE <sha>:refs/heads/<name> from $RESTORE"
exit $fail
