Two defects in the work-log clock, both surfaced by todo 2006 on 2026-11-03.

1. A log left open past midnight billed 1 minute. _duration_hms subtracted the end
   clock time from the start clock time, so a session opened 15:39 and closed at
   01:38 produced a negative value, which the floor turned into 00:01:00. It now
   counts elapsed days from the stored start_date before subtracting, so:

     15:39 -> 17:38 same day ............ 01:59:00 (119 min)
     15:39 -> 01:38 next day ........... 09:59:00 (599 min)
     23:50 -> 00:20 .................... 00:30:00 (30 min)
     15:39 -> 16:10 three days later ... 72:31:00 then refused by the stale guard

2. A stale clock was billed as real work. close_log now refuses to bill a span
   longer than 12 hours: it records the close with time 00:00:00 and a comment
   "auto-closed stale log: N min elapsed, 0 billed". This matches the rule that a
   clock left running is a discipline failure, not hours worked.

3. A finished todo could still show as open. New TodoLog::reap_orphan_logs closes
   any open log whose todo is already status 3 or 4 (end_time = start_time, time
   0, comment "auto-closed: todo was already done"). It runs on toggle_start and
   close_log, so the inconsistency heals as soon as anyone touches a todo - the
   reported case was todo 2644 sitting at status 3 while its log showed as open.

Data corrected the same day: log 2110 set to end 17:38:07 / 01:58:00; logs 2031,
2082 and 2094 closed with 0 billed.
