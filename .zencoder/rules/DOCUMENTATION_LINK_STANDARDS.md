# Documentation Link Standards - AUTHORITATIVE REFERENCE
**Version**: 1.0  
**Updated**: December 24, 2025  
**Scope**: All .tt files in `/Comserv/root/Documentation/`  
**Status**: 🔴 CRITICAL - Enforced for all documentation agents

---

## THE CORE RULE (Non-Negotiable)

**ALL documentation links MUST follow this format:**

```
/Documentation/FILENAME
```

**NOT:**
- ❌ `/Documentation/FILENAME.tt` (DO NOT include .tt extension)
- ❌ `/Documentation/subdirectory/FILENAME` (DO NOT include subdirectory)
- ❌ `/Documentation/system/FILENAME.tt` (DO NOT mix both errors)

---

## HOW THE DOCUMENTATION SYSTEM WORKS

The Comserv documentation controller (`Comserv/lib/Comserv/Controller/Documentation.pm`) uses a **flat namespace**:

1. **Scans all files recursively** in `/Documentation/` and subdirectories
2. **Extracts filename without extension** as the routing key
3. **Strips `.tt` extension** (line 111 of ScanMethods.pm): `basename($file, '.tt')`
4. **Ignores subdirectories** in the URL - only uses base filename
5. **Routes via `/Documentation/KEY`** where KEY = filename without extension

### Example Routing

| File Location | File Name | Routing Key | Correct URL |
|---|---|---|---|
| `root/Documentation/system/K3S_QUICK_REFERENCE.tt` | K3S_QUICK_REFERENCE.tt | K3S_QUICK_REFERENCE | `/Documentation/K3S_QUICK_REFERENCE` |
| `root/Documentation/system/DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt` | DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt | DOCKER_KUBERNETES_MIGRATION_STRATEGY | `/Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY` |
| `root/Documentation/features/todo_system.tt` | todo_system.tt | todo_system | `/Documentation/todo_system` |
| `root/Documentation/kubernetes/K8S_SECRETS_SETUP.tt` | K8S_SECRETS_SETUP.tt | K8S_SECRETS_SETUP | `/Documentation/K8S_SECRETS_SETUP` |

---

## QUICK REFERENCE TABLE

| What to Link | Format | Example | Notes |
|---|---|---|---|
| System documentation | `/Documentation/FILENAME` | `/Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY` | No .tt, no /system/ |
| Feature documentation | `/Documentation/FILENAME` | `/Documentation/todo_system` | Works for any subdirectory |
| Model documentation | `/Documentation/FILENAME` | `/Documentation/User` | From models/ subdirectory |
| Controller documentation | `/Documentation/FILENAME` | `/Documentation/Documentation` | From controllers/ subdirectory |
| Kubernetes guide | `/Documentation/FILENAME` | `/Documentation/K8S_SECRETS_SETUP` | From kubernetes/ subdirectory |
| Admin documentation | `/Documentation/FILENAME` | `/Documentation/documentation_system_guide` | From admin/ subdirectory |

---

## REAL-WORLD EXAMPLE: Fixed Links

### ❌ WRONG (Old Format)
```html
<a href="/Documentation/system/K3S_PRODUCTION_MIGRATION_GUIDE">Implementation Guide</a>
<a href="/Documentation/system/DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt">Main Migration</a>
<a href="/Documentation/system/PRODUCTION_DB_KUBERNETES_MIGRATION_PLAN">Grok's Plan</a>
```

**Problems:**
1. Includes `/system/` subdirectory (documentation system ignores this)
2. One example includes `.tt` extension (inconsistent)
3. Links will NOT work - users get 404 errors

### ✅ CORRECT (Fixed Format)
```html
<a href="/Documentation/K3S_PRODUCTION_MIGRATION_GUIDE">Implementation Guide</a>
<a href="/Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY">Main Migration</a>
<a href="/Documentation/PRODUCTION_DB_KUBERNETES_MIGRATION_PLAN">Grok's Plan</a>
```

**Why this works:**
1. No subdirectory in URL (documentation system handles that)
2. No `.tt` extension (routing key is filename without extension)
3. Clean, simple, consistent format
4. Links resolve correctly to `.tt` files regardless of location

---

## VALIDATION CHECKLIST FOR DOCUMENTATION CREATORS

When creating or editing `.tt` files with links:

- [ ] All links start with `/Documentation/` (not `/Documentation/system/`, `/Documentation/kubernetes/`, etc.)
- [ ] No links end with `.tt` extension
- [ ] Link text is descriptive (avoid "Click here" or generic text)
- [ ] All links tested in browser (navigate to `/Documentation/FILENAME` to verify)
- [ ] Cross-links reference valid documentation files (check filename exists)
- [ ] Internal anchors use consistent format: `#section-name` (lowercase, hyphens)
- [ ] No relative paths (always use `/Documentation/` absolute format)

---

## FOR DOCUMENTATION AGENTS

### When Generating Links

**Template for adding a link to documentation:**
```html
<a href="/Documentation/FILENAME" style="[your-styles]">Link Text</a>
```

**Replace `FILENAME` with:**
- The actual filename from `/Documentation/` directory
- WITHOUT the `.tt` extension
- WITHOUT any subdirectory prefix
- Check existing files for correct capitalization

**Examples:**
```html
<!-- Good -->
<a href="/Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY">Migration Strategy</a>
<a href="/Documentation/todo_system">Todo System Guide</a>
<a href="/Documentation/User">User Model Documentation</a>

<!-- Bad - DO NOT USE -->
<a href="/Documentation/system/DOCKER_KUBERNETES_MIGRATION_STRATEGY.tt">❌</a>
<a href="/Documentation/features/todo_system">❌ (subdirectory ignored anyway)</a>
<a href="/Documentation/models/User.tt">❌ (both errors)</a>
```

### When Validating Documentation

Use `/validatett` keyword to check for link validity:
- Scans all links in `.tt` file
- Verifies target files exist
- Reports broken links with line numbers
- Suggests correct format for malformed links

---

## EXCEPTION HANDLING

### Linking to Non-Documentation Pages

For pages **outside** `/Documentation/`:

| Target | Format | Example |
|---|---|---|
| Admin interface | `/admin` | `<a href="/admin">Admin</a>` |
| Home page | `/` or `/index` | `<a href="/">Home</a>` |
| Todo app | `/todo` | `<a href="/todo">Todo App</a>` |
| Projects | `/projects` | `<a href="/projects">Projects</a>` |

**Key Difference**: Non-documentation links use full path; documentation uses flat namespace.

---

## TECHNICAL DETAILS (For Reference)

### Documentation Controller Routing

From `Documentation.pm` line 589:
```perl
sub view :Path('/Documentation') :Args(1) {
    my ($self, $c, $page) = @_;
    # ... authentication/authorization checks ...
    if (exists $pages->{$page}) {
        # $page is KEY without subdirectory or extension
        # e.g., "DOCKER_KUBERNETES_MIGRATION_STRATEGY"
        $metadata = $pages->{$page};
    }
}
```

### ScanMethods.pm Key Generation

From `ScanMethods.pm` lines 110-122:
```perl
if ($file =~ /\.tt$/) {
    $key = basename($file, '.tt');  # Remove .tt extension
    # Example: "K3S_QUICK_REFERENCE.tt" → "K3S_QUICK_REFERENCE"
}
# The $key is used regardless of file location
# "/Documentation/system/K3S_QUICK_REFERENCE.tt" → key = "K3S_QUICK_REFERENCE"
# "/Documentation/features/K3S_QUICK_REFERENCE.tt" → key = "K3S_QUICK_REFERENCE"
```

**Result**: Same filename in different subdirectories share the same routing key.  
This is why subdirectory is irrelevant in URLs.

---

## CONFLICT RESOLUTION

### Multiple Files with Same Name (Different Directories)

**DO NOT:**
```
/Documentation/system/User.tt
/Documentation/models/User.tt (both trying to use same routing key)
```

**This creates ambiguity.** The documentation system will use one (usually the first scanned).

**DO:**
```
/Documentation/models/User.tt      (keep canonical version)
/Documentation/system/User_System.tt (rename to be unique)
```

**Check for conflicts:**
```bash
# Find potential conflicts
find /Comserv/root/Documentation -type f -name "*.tt" -exec basename {} \; | sort | uniq -d
```

If duplicates found: Rename or consolidate into one file.

---

## AUDIT: Recent Fix

**File**: `K3S_QUICK_REFERENCE.tt`  
**Date Fixed**: December 24, 2025  
**Changes Made**:
```
OLD: /Documentation/system/K3S_PRODUCTION_MIGRATION_GUIDE
NEW: /Documentation/K3S_PRODUCTION_MIGRATION_GUIDE

OLD: /Documentation/system/DOCKER_KUBERNETES_MIGRATION_STRATEGY
NEW: /Documentation/DOCKER_KUBERNETES_MIGRATION_STRATEGY

OLD: /Documentation/system/PRODUCTION_DB_KUBERNETES_MIGRATION_PLAN
NEW: /Documentation/PRODUCTION_DB_KUBERNETES_MIGRATION_PLAN
```

**Status**: ✅ Fixed and verified

---

## RELATED DOCUMENTATION STANDARDS

See also:
- `coding-standards.yaml` agents:DocumentationSyncAgent - General documentation rules and validation
- `documentation_tt_template.tt` - Template structure and META requirements
- `coding-standards.yaml` Rule 6 - Repository-wide documentation standards (Zencoder rules)

---

## ENFORCEMENT

**This standard is enforced by:**
1. ✅ `/validatett` keyword - scans for broken links
2. ✅ Documentation Synchronization Agent - weekly audits
3. ✅ Manual review - when new documentation created
4. ✅ Pull request checks - CI/CD validation (future)

**Violation Impact:**
- Broken links prevent users from navigating documentation
- Users see 404 errors
- Tutorial links fail
- Cross-references don't work
- Documentation becomes unreliable

**Compliance**:
- ✅ MANDATORY for all `.tt` files in `/Documentation/`
- ✅ REQUIRED for all documentation creation agents
- ✅ ENFORCED by validation tools

---

**Last Verified**: December 24, 2025  
**Verified By**: Docker/Kubernetes Migration Specialist  
**Status**: ✅ ACTIVE AND AUTHORITATIVE
