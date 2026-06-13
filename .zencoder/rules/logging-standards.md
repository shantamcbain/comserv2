---
description: "Application logging standards"
globs: ["**/*.pm"]
alwaysApply: false
---

# Logging Protocol

**Standard**: Use `log_with_details` for all operational logging (see checklist in `Comserv/lib/Comserv/Util/Logging.pm`).

## Required format
```perl
$self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
    'meaningful_action_name',
    "What failed with context: $detail");
```

## Checklist (summary)
1. Use `log_with_details` — not bare `warn`, `print`, or `$c->log->error` for failures
2. 5th argument = real action name (`dns_records`, `modify_todo`) — not `end` / `view` / `auto`
3. Message = self-contained (what, ids, path)
4. `error`+ creates Application Error Audit todos via `error_audit_meta`
5. After fixing audit todos: deploy, then close — check `Comserv/DEPLOY_STATUS.json`

## Log locations
- `Comserv/logs/application.log`
- `system_log` table (WARN+)
- Application Error Audit panel on Planning → Daily Priorities (ERROR+)

## Deploy awareness
Read `Comserv/DEPLOY_STATUS.json` and `Comserv/version.json` at session start when debugging production vs dev.