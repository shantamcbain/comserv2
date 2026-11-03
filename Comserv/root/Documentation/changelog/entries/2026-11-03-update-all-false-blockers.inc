"Update all branches from main" reported would_skip_local_changes for 12 of 16
worktrees even though nothing could be lost.

Two independent causes, both measured 2026-11-03:

1. Mode-only typechange counted as a blocker. .zencoder/scripts/updateprompt.pl
   shows " T" (file <-> symlink) in every worktree, and its working copy is
   already byte-identical to main's version. The preview intersected "dirty
   files" with "files main changes" and skipped the whole branch. Now each
   candidate is re-checked with `git diff --quiet main -- <file>`: if the working
   copy already equals main's, the merge would leave the file untouched, so it is
   not a blocker.

2. Comserv/root/config/worktrees.json is the per-worktree registry and differs in
   every checkout while main also changes it, so git would genuinely refuse. It
   is now untracked (git rm --cached) in every worktree and main, kept on disk and
   ignored through .git/info/exclude (local, so it can never conflict), which
   removes the blocker permanently instead of papering over it.

Proxmox (:4016) is still skipped by design.

Related, found while fixing this: [%# ... #] is not a valid TT comment close in
admin/git/index.tt - it swallowed markup up to the next %], which is why the
update-all card's buttons belonged to no form and did nothing when clicked.
