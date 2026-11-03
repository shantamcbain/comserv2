"Update all branches from main" looked dead: clicking Preview or Update changed nothing on
the page and left no trace on the server.

What was ruled out first (2026-11-03): the endpoint, its CSRF check, and the merge util were
all sound. The card's data attributes matched what git-dashboard.js read, the served JS was
byte-identical to the file on disk (md5 a3bbb60d...), the action answers a JSON 403 instead
of a login redirect, and a t/ run of Util::Git->update_all_from_main had already merged and
fast-forwarded real branches. Also: Root.pm's [REQUEST_START] does not run for /admin/*
requests (Admin.pm::begin logs those instead), so "no REQUEST_START line" was never evidence
that a click had not arrived.

That left the browser as the only unproven link: with the handler at the very end of a 900+
line file, a single earlier script error, a stale cached copy or a missing script tag makes
every button on the card inert, and the page shows nothing at all.

Fix: the card is now a real <form method="post"> with a hidden CSRF field and submit buttons
named mode=preview|update, so the browser can post it with no JavaScript whatsoever. When the
script does run it intercepts the submit (ev.preventDefault) and renders the JSON in place as
before. The action distinguishes the two callers with _wants_json(): fetch() still gets JSON,
a plain form post stores the result in the session and redirects back to /admin/git, where
index() renders the summary and per-branch rows server-side (one-shot stash, deleted on read).

Result: the feature no longer depends on JS being loaded, current or error-free.
