# Documentation Paths - Quick Reference Card

**Status**: 🔴 CRITICAL - Auto-enforced by Zencoder  
**Last Updated**: 2026-01-04  
**Authority**: coding-standards.yaml (CRITICAL SETTINGS section)

---

## THE ONLY VALID FORMAT

```
✅ /Documentation/FILENAME
```

---

## WHAT ZENCODER MUST CHECK BEFORE EVERY DOCUMENTATION ACTION

Before creating, editing, or linking ANY documentation:

```
1. Does the path start with /Documentation/? ✅
2. Is there NO .tt extension at the end?   ✅
3. Is there NO subdirectory between /Documentation/ and filename? ✅
4. Is the format exactly: /Documentation/FILENAME ✅
```

If ANY answer is ❌, STOP and ask the user for correction.

---

## FORBIDDEN PATTERNS (Auto-Fail)

| ❌ Wrong | 🐛 Error | ✅ Correct |
|----------|---------|-----------|
| `/Documents/FILENAME` | Wrong directory name (Documents vs Documentation) | `/Documentation/FILENAME` |
| `/Documentation/FILENAME.tt` | Includes file extension | `/Documentation/FILENAME` |
| `/Documentation/system/FILENAME` | Includes subdirectory path | `/Documentation/FILENAME` |
| `/Documentation/folder/FILE.tt` | Multiple errors combined | `/Documentation/FILE` |
| `Documentation/FILENAME` | Missing leading slash | `/Documentation/FILENAME` |
| `/Docs/FILENAME` | Abbreviated directory name | `/Documentation/FILENAME` |

---

## REAL EXAMPLES

### ✅ CORRECT (Use These)
```
/Documentation/K3S_QUICK_REFERENCE
/Documentation/DOCKER_KUBERNETES_MIGRATION
/Documentation/todo_system
/Documentation/User
/Documentation/AdminPanel
/Documentation/DatabaseSchema
```

### ❌ WRONG (Never Use)
```
/Documents/K3S_QUICK_REFERENCE                    (Wrong dir)
/Documentation/K3S_QUICK_REFERENCE.tt             (Has .tt)
/Documentation/system/K3S_QUICK_REFERENCE         (Has subdir)
/Documentation/system/K3S_QUICK_REFERENCE.tt      (Multiple errors)
/Documents/system/K3S_QUICK_REFERENCE.tt          (All errors)
```

---

## WHY THIS MATTERS

**How Comserv Routes Documentation**:
1. Files can be stored in subdirectories: `root/Documentation/system/`, `root/Documentation/kubernetes/`, etc.
2. The Comserv controller uses a **flat namespace**
3. Only the **filename** matters for routing (no subdirectories, no extension)
4. URL pattern strips both subdirectories and `.tt` extension

**Example**:
```
File on disk: root/Documentation/system/K3S_QUICK_REFERENCE.tt
Routing key:  K3S_QUICK_REFERENCE (filename without extension)
URL format:   /Documentation/K3S_QUICK_REFERENCE
```

---

## AUTO-CHECK (Execute Before Any Doc Work)

```perl
# Pseudo-code for Zencoder automatic validation
if ($doc_reference =~ m|/Documents/|) {
    HALT: "ERROR: Using /Documents/ (wrong). Use /Documentation/ instead."
}
if ($doc_reference =~ m|\.tt$|) {
    HALT: "ERROR: URL includes .tt extension (wrong). Remove it."
}
if ($doc_reference =~ m|/Documentation/[^/]+/|) {
    HALT: "ERROR: Subdirectory in URL (wrong). Use flat namespace: /Documentation/FILENAME"
}
if ($doc_reference =~ m|^/Documentation/[\w]+$|) {
    PASS: "✅ Valid documentation path format"
}
```

---

## WHEN TO USE THIS CARD

**Every time Zencoder**:
- 📝 Creates a new documentation file
- 🔗 Generates a link to documentation
- ✏️ Edits documentation paths
- 📍 References documentation in code

---

## EXCEPTION: Non-Documentation Links

For pages **outside** `/Documentation/` (rare):

| Target | Correct Format |
|--------|---|
| Admin interface | `/admin` |
| Home page | `/` or `/index` |
| Todo app | `/todo` |
| Projects | `/projects` |

**NOTE**: These use full paths. Documentation uses flat namespace.

---

## IF YOU SEE THE WRONG FORMAT

**User's Responsibility**: 
1. Zencoder will ask: "I notice you're using [WRONG_FORMAT]. Should I use [CORRECT_FORMAT] instead?"
2. User confirms the correct format
3. Zencoder proceeds with correct format

**Zencoder's Responsibility**:
1. Never use wrong format without asking
2. Always auto-check before documentation work
3. Stop and ask user if wrong format detected
4. Document the correction in session logs

---

## LINKED DOCUMENTATION

- **Full Rules**: `.zencoder/rules/DOCUMENTATION_LINK_STANDARDS.md` (comprehensive reference)
- **Coding Standards**: `.zencoder/coding-standards.yaml` (CRITICAL SETTINGS section)
- **Controller Code**: `Comserv/lib/Comserv/Controller/Documentation.pm` (implementation details)

---

**Enforcement Level**: 🔴 MANDATORY  
**Applies To**: All Zencoder agents + all documentation work  
**Status**: Active from 2026-01-04 onwards
