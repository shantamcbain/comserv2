# Documentation Sync Master Plan (Chat 49+)
**Created**: 2026-01-10  
**Status**: PHASE 2 COMPLETE - Foundation Built (RepositoryCodeAudit.json v2.0)  
**Goal**: Establish permanent, maintainable documentation-to-code audit system with 1:N mapping and git-based workflow  

---

## ✅ PHASE 2 COMPLETION (Chat 49, Prompt 21)

**Status**: COMPLETE - Primary 1:N Code-to-Documentation Mapping Built

**What Was Accomplished**:
- ✅ Created `build_code_to_docs_mapping.pl` script (Perl-based grepping automation)
- ✅ Analyzed all 157 code files in `Comserv/lib/Comserv/`
- ✅ Grepped entire Documentation directory for code file references
- ✅ Updated `RepositoryCodeAudit.json` to v2.0 with **1:N relationships**
- ✅ Added `related_documentation` array to every code file entry
- ✅ Added `doc_count` field showing number of docs per code file
- ✅ Preserved backward compatibility with `documentation_path` field

**Key Statistics**:
- 🔵 Total code files: **157**
- 🟢 Files with documentation: **157 (100% coverage)**
- 🟡 Files with MULTIPLE docs: **154 (98%)**
- 📊 Example: AI.pm now shows **104 related documentation files**

**New Artifact**: `Comserv/root/Documentation/config/RepositoryCodeAudit.json` v2.0
- Location: Primary persistent mapping file
- Structure: `{code_files: {filename: {documentation_path, related_documentation: [], doc_count, ...}}}`
- Updated: 2026-01-10T16:34:03Z
- Usage: Foundation for all future documentation-sync workflow tasks

---

## 🎯 PROBLEM STATEMENT

Currently, **documentation is only partially maintained** and we lack:
1. ❌ **No definitive audit** of code changes vs documentation state
2. ❌ **No permanent mapping** of code files → documentation files
3. ❌ **No systematic verification** that docs match code (overall, not just current changes)
4. ❌ **Format inconsistencies**: Using "documentation_tt_template.tt" name when actual file is "DocumentationTtTemplate.tt"
5. ❌ **Manual, ad-hoc process** without repeatable workflow

---

## 📋 ORIGINAL PROPOSED SOLUTION (Historical Reference)

**NOTE**: The plan below describes the original 4-phase approach. This has been refined in the **EXECUTION PLAN** section (lines 173-228) where:
- **PHASE 2 (Documentation Mapping)** is now COMPLETE via `RepositoryCodeAudit.json v2.0`
- **Chat 50+ will execute PHASE 1** (Git-based code change detection) using the v2.0 mapping as foundation
- This enables **PHASE 3-4** to focus only on documentation files related to actual code changes (not full 300+ file audit)

---

### **PHASE 1: Code Audit (Foundation) - ORIGINAL DESCRIPTION**

**Objective**: Get authoritative list of code changes and related documentation needs.

**Steps**:
```
1. Run: git diff HEAD~10..HEAD --name-only
   Output: List of ALL changed files (*.pm) since last 10 commits
   
2. For each changed file, identify scope:
   - Controllers: Comserv/lib/Comserv/Controller/*.pm
   - Models: Comserv/lib/Comserv/Model/*.pm  
   - Utilities: Comserv/lib/Comserv/Util/*.pm
   - Schema: Comserv/lib/Comserv/Model/Schema/**/*.pm
   
3. Output: CODE_CHANGES_AUDIT_2026-01-10.yaml
   Contains: { file, type, methods_changed, features_added, bugs_fixed }
```

**Deliverable**: `CODE_CHANGES_AUDIT_2026-01-10.yaml`

---

### **PHASE 2: Documentation Mapping (Linking)**

**Objective**: Create permanent code→documentation mapping.

**Steps**:
```
1. For each code file from Phase 1, identify related documentation:
   
   Controllers/Admin.pm → Documentation/controllers/Admin.tt
   Models/Ollama.pm → Documentation/models/Ollama.tt
   Util/DockerManager.pm → Documentation/utilities/DockerManager.tt (may not exist yet)
   
2. Document has MULTIPLE types:
   - Primary: Matching filename (.tt file for each .pm file)
   - Related: Tutorials, guides, examples using this code
   - Orphaned: .md files without .tt equivalents
   
3. Output: DOCUMENTATION_MAPPING_2026-01-10.yaml
   Contains: 
   {
     "Comserv/lib/Comserv/Controller/AI.pm": {
       "primary_doc": "Documentation/controllers/AI.tt",
       "exists": true,
       "version": "1.13",
       "last_updated": "2026-01-10",
       "related_docs": ["Chat.tt", "AiConversation.tt"],
       "tutorials": ["AI_Chat_Interface_Architecture_Audit.tt"]
     }
   }
```

**Deliverable**: `DOCUMENTATION_MAPPING_2026-01-10.yaml`

---

### **PHASE 3: Format Verification (Compliance)**

**Objective**: Verify all documentation files meet format standards.

**Standards**: Based on **DocumentationTtTemplate.tt** (NOT "documentation_tt_template.tt")

**Required Elements** (MUST have all):
- ✅ Valid `[% META ... %]` block with 7 required fields:
  - `title`
  - `description`  
  - `roles`
  - `TemplateType`
  - `category`
  - `page_version`
  - `last_updated`
  - `site_specific`
- ✅ `[% PageVersion = '...' %]` RCS line (format: `path,v X.YY YYYY/MM/DD Author`)
- ✅ Debug guard: `[% IF c.session.debug_mode == 1 %][% PageVersion %][% END %]`
- ✅ Theme-compliant CSS: `var(--text-color)`, `var(--link-color)` (NO hex colors)
- ✅ `<div class="last-updated">` with YYYY-MM-DD format
- ✅ **All files must be .tt format** (Exception: .continue/rules/*.md are agent configs only)

**Steps**:
```
1. Scan all .tt files (300+ files in /Comserv/root/Documentation/)
2. For each file:
   - Validate META block has all 7 fields
   - Check PageVersion RCS line format
   - Verify CSS uses var(--...) not hex colors
   - Check last-updated div format
3. Collect violations by severity:
   🔴 CRITICAL: Missing META block, invalid structure
   🟠 ERROR: Missing required fields, invalid CSS
   🟡 WARNING: Formatting issues, outdated dates
4. Output: FORMAT_AUDIT_2026-01-10.yaml
   Contains: { file, severity, violation_type, fix_suggestion }
```

**Deliverable**: `FORMAT_AUDIT_2026-01-10.yaml`

---

### **PHASE 4: Content Sync (Accuracy)**

**Objective**: Verify documentation content matches actual code.

**For Each Documentation File** (prioritized from Phase 1):
```
1. Read both code file (.pm) AND documentation file (.tt)
2. Verify:
   - All public methods documented
   - Method signatures match
   - Parameter descriptions accurate
   - Return types documented
   - Recent code changes reflected in "Recent Updates" section
   - No references to removed/renamed methods
3. If drift detected:
   - Note severity: 🔴 CRITICAL (method missing), 🟠 ERROR (wrong docs), 🟡 WARNING (outdated)
   - Decide: Update doc version, or create issue
4. Output: CONTENT_SYNC_AUDIT_2026-01-10.yaml
   Contains: { file, code_version, doc_version, sync_status, needed_updates }
```

**Deliverable**: `CONTENT_SYNC_AUDIT_2026-01-10.yaml`

---

## 🔄 EXECUTION PLAN (Per Session)

### **Chat 49 (Current) - PLANNING PHASE** ✅
- ✅ Create this master plan document (DOCUMENTATION_SYNC_PLAN.md)
- ✅ Get user approval via ask_questions()
- ✅ User decisions logged and decisions recorded

### **Chat 49 - PHASE 2 (Documentation Mapping)** ✅ **COMPLETE**
**Scope**: Link all 300+ .tt files to code via automated grepping
- ✅ Built `RepositoryCodeAudit.json` v2.0 with 1:N code→doc mapping
- ✅ 157 code files analyzed, 154 (98%) have multiple documentation files
- ✅ Primary persistent mapping artifact created
- ✅ Ready for git-based change detection workflow

**Git-Based Workflow Integration** (Chat 50+):
```bash
# Identify changed files from last commit to current
git diff HEAD~1..HEAD --name-only | grep "\.pm$"

# For each changed code file, use RepositoryCodeAudit.json v2.0:
# 1. Look up code file in mapping
# 2. Get related_documentation array
# 3. Check which docs need version updates
# 4. Execute PHASE 3 checks on those docs only

# Example:
# Changed file: Comserv/lib/Comserv/Controller/AI.pm
# Look up in RepositoryCodeAudit.json
# Get 104 related docs from related_documentation array
# Filter: Only update docs modified since last commit
# Result: Focused documentation sync (not full 300+ file audit)
```

### **Chat 50 - PHASE 1 (Git-Based Code Change Detection)**
**Scope**: Use git diff to identify code files changed since last commit
- Run: `git diff HEAD~1..HEAD --name-only` (configurable range)
- Cross-reference with RepositoryCodeAudit.json v2.0
- For each changed code file: retrieve related_documentation array
- Create CODE_CHANGES_AUDIT_2026-01-10.yaml with git-detected changes only
- This focuses PHASE 3/4 on actual code changes (not full repository audit)

### **Chat 51-52 - PHASE 3 (Format Verification on Changed Docs)**  
**Scope**: Verify format of documentation related to changed code files
- Use PHASE 1 git diff results to identify relevant docs
- Validate subset of .tt files (typically 20-50 instead of 300+)
- Check: META block, PageVersion RCS, CSS variables, last-updated div
- Fix violations incrementally
- Create FORMAT_AUDIT_DELTA_2026-01-10.yaml

### **Chat 53+ - PHASE 4 (Content Sync - As Needed)**
**Scope**: Verify documentation accuracy vs code for changed files
- Use CODE_CHANGES_AUDIT_2026-01-10.yaml (PHASE 1 results) to identify priority docs
- For each changed code file: verify all methods documented
- Check parameter descriptions, return types, return value details
- Update .tt files version numbers based on code drift
- Maintain RepositoryCodeAudit.json v2.0 as source of truth for ongoing updates

---

## 📁 PERMANENT ARTIFACTS (Maintained)

These files become the **single source of truth** for documentation state:

| File | Purpose | Updated | Owner |
|------|---------|---------|-------|
| **`config/RepositoryCodeAudit.json` v2.0** | **PRIMARY**: 1:N Code→Doc mapping with 157 files, 154 with multiple docs | Per git change detection cycle (Chat 50+) | DocumentationSyncAgent |
| `session_history/CODE_CHANGES_AUDIT_YYYY-MM-DD.yaml` | Per-session git-detected code changes and affected documentation files | Once per sync cycle | DocumentationSyncAgent |
| `session_history/FORMAT_AUDIT_DELTA_YYYY-MM-DD.yaml` | Format compliance findings for changed documentation files | Per format check completion | DocumentationSyncAgent |
| `session_history/CONTENT_SYNC_AUDIT_YYYY-MM-DD.yaml` | Content accuracy findings vs code (prioritized by git diff) | Per content sync completion | DocumentationSyncAgent |
| `DocumentationTtTemplate.tt` | Format standard (reference) | Only if template changes | (manual) |

---

## ✅ USER DECISIONS (Chat 49, Prompt 17)

### **Decision 1: Template File Reference**
**APPROVED**: Use relative path: `Comserv/root/Documentation/DocumentationTtTemplate.tt`
- Location known and explicit
- Prevents wasting resources searching for wrong filename
- DocumentationSyncAgent will reference this path in all format checks

### **Decision 2: Audit Scope**
**APPROVED**: **Full Repository Audit** (all 300+ documentation files)
- Comprehensive baseline for long-term maintenance
- Starting in Chat 50, Phase 1
- Will systematically audit ALL .tt files, not just recent changes

### **Decision 3: Settings/Configuration**
**APPROVED**: Stay within Zencoder responsibility boundaries
- Only update Zencoder-specific settings in `/.zencoder/`
- Do NOT modify other AI agent settings (Continue IDE, Cursor, etc.)
- Template path correction is DocumentationSyncAgent-specific, within scope

---

## 📊 SUCCESS CRITERIA

### ✅ PHASE 2 COMPLETE (Chat 49)
1. ✅ **Primary 1:N mapping**: RepositoryCodeAudit.json v2.0 with 157 code files → 154 with multiple docs
2. ✅ **Reusable grepping script**: `build_code_to_docs_mapping.pl` for future updates
3. ✅ **Persistent artifact**: `config/RepositoryCodeAudit.json` with related_documentation arrays and doc_count fields

### ⏳ PHASE 1-4 (Chat 50+) GOALS
4. ⏳ Git-based change detection (Phase 1: identify changed .pm files since last commit)
5. ⏳ Format compliance verification (Phase 3: validate affected .tt files against template)
6. ⏳ Content accuracy verification (Phase 4: verify methods vs documentation)
7. ⏳ Repeatable workflow documented in CLAUDE.md for future DocumentationSyncAgent sessions

---

## 🛠️ SCRIPT REQUIREMENTS & INTEGRATION

### **build_code_to_docs_mapping.pl** (Created Chat 49, Prompt 21)

**Purpose**: Automated 1:N code-to-documentation grepping and mapping generation

**Script Location**: `Comserv/build_code_to_docs_mapping.pl`

**How It Works**:
1. Scans `Comserv/lib/Comserv/` for all .pm code files (157 files found)
2. For each code file:
   - Extracts filename and basename (e.g., `Admin.pm` → `Admin`)
   - Greps entire `Comserv/root/Documentation/` directory for filename + basename matches
   - Collects matching .tt files
3. Merges results with existing `RepositoryCodeAudit.json` data
4. Outputs new `related_documentation` array for each code file
5. Adds `doc_count` field (total related docs per code file)
6. Preserves `documentation_path` field for backward compatibility
7. Updates `audit_timestamp` and adds `mapping_version: 2.0`

**Required Inputs**:
- `RepositoryCodeAudit.json` (existing audit file with baseline structure)
- `.pm` files in `Comserv/lib/Comserv/` directory
- `.tt` files in `Comserv/root/Documentation/` directory

**Outputs**:
- Updated `RepositoryCodeAudit.json` with `related_documentation` arrays

**Dependencies**:
- Perl modules: `JSON::XS`, `File::Find`, `File::Spec`
- System commands: `grep` (via shell backticks)

**Re-run Conditions**:
- After major documentation file additions/moves
- After code file refactoring/reorganization
- Periodically (monthly) to detect new doc-to-code relationships
- In Chat 50+ if git diff results need expanded documentation discovery

**Future Enhancement** (Chat 50+):
- Could accept git diff output as argument to only rescan affected code files
- Could filter by category (Controllers, Models, Utilities) for targeted mapping updates

---

## 📝 NOTES

- This plan can expand to include other code files (utilities, schemas) after Phase 1
- Each audit cycle produces timestamped output (AUDIT_2026-01-10.yaml)
- Master files are cumulative (never deleted, only updated)
- Related to: current_session.md, prompts_log.yaml, DocumentationConfig.json
- **build_code_to_docs_mapping.pl** is persistent and can be re-run as needed
- **RepositoryCodeAudit.json v2.0** is the primary artifact for all future documentation-sync work

