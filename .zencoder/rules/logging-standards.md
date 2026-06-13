---
description: "Zencoder adapter — application logging (canonical docs in repo)"
globs: ["**/*.pm"]
alwaysApply: false
---

# Logging Standards (Zencoder adapter)

**Canonical source:** `Comserv/lib/Comserv/Util/Logging.pm` (header checklist) and `/Documentation/logging_best_practices`.

This file is a Zencoder pointer only. Do not treat it as the authoritative logging spec.

## Quick reminder

```perl
$self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
    'meaningful_action_name',
    "What failed with context: $detail");
```

- 5th arg = real action name (not `end` / `view` / `auto`)
- `error`+ → Application Error Audit todos; check `Comserv/DEPLOY_STATUS.json` before closing
- Fix logging opportunistically when editing the controller you touch

See also: `AGENTS.md` (deploy awareness), `/Documentation/DevelopmentStandards`