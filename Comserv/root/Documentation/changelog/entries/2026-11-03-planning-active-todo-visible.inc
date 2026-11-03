An ACTIVE todo could not be seen on /planning/daily when the page was served
from a branch worktree.

Reported 2026-11-03: todo 2006 was status 5 (ACTIVE) with an open log row
(id 2110, end_time 00:00:00) and still appeared nowhere on the planning page
served from :4004 (branch "git"). The rows were present in ency.todo the whole
time — this was a display defect, not a Start/logging defect.

Cause: Comserv::Util::FocusRanking::todo_matches_branch() matches only on
project id / parent id / project name / project code / keyword hints. It never
looks at status. On a worktree server the daily page therefore dropped every
todo whose project sits outside that branch's project scope — including a todo
somebody was actively working on. Todo 2006 belongs to project 3, while the git
worktree resolves to project 238 (GITWT-NEW), so the row was filtered out
before the Focus Queue was even ranked.

Fix: Controller/Planning.pm keeps a copy of the ACTIVE rows (status 5 or
in_progress) before the branch filter and merges back any it would have
dropped, logging "Branch focus rescued N active todo(s)" so the rescue is
visible in the log instead of happening silently.

Rule this encodes: active work is global, ranking is local. Branch scope may
reorder and may hide idle todos, but it may never hide the todo a user or agent
has running right now.
