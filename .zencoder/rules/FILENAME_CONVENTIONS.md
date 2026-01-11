# ⚡ FILENAME CONVENTIONS - Quick Reference

**Status**: 🟢 ACTIVE (2025-12-28)  
**Authority**: `/Comserv/root/coding-standards-comserv.yaml` (Section 1A - Primary source)  
**Enforcement**: MANDATORY for all new files (Cleanup Agent responsibility)

---

## 🎯 The Standard: PascalCase

```
✅ CORRECT                          ❌ WRONG
CleanupAgentRole.md                 cleanup-agent-role.md      (hyphens)
VirtualMachineDataFetch.tt          virtual_machine_data_fetch.tt  (underscores)
NetworkDeviceManager.pm             network-device-manager.pm   (hyphens)
CreateSupervisorConfig.sh           create_supervisor_config.sh (underscores)
DailyAuditReport.yaml               daily-audit-report.yaml    (hyphens)
AddNetworkDevice.tt                 add_network_device.tt      (underscores)
GitPull.tt                          git_pull.tt                (underscores)
```

**Rule**: CapitalizedWords + NoSpaces + NoHyphens + NoUnderscores

---

## 📋 Quick Checklist (Use BEFORE Creating Files)

When you're about to create a file, ask yourself:

- [ ] Does the filename start with a capital letter?
- [ ] Are all word boundaries marked with capital letters (PascalCase)?
- [ ] Does it contain **NO hyphens** (`-`)?
- [ ] Does it contain **NO underscores** (`_`)?
- [ ] Does it contain **NO spaces**?

**If ANY answer is "No"** → Rename to PascalCase before creating the file.

---

## 🎓 Edge Cases & Examples

### Acronyms
- **✅ Correct**: `AIController.pm`, `SQLManager.pm`, `XMLParser.pm`
- **❌ Wrong**: `AiController.pm`, `aiController.pm`
- **Rule**: Each acronym is capitalized as a unit

### Single Words
- **✅ Correct**: `controller.pm` (single word, lowercase first letter)
- **❌ Wrong**: `Controller.pm` (PascalCase is for MULTIPLE words)
- **Rule**: Only capitalize first letter when combining with other words

### Dates in Filenames
- **✅ Correct**: `DailyAudit2025-12-28.md` (date can use hyphens for readability)
- **Alternative**: `DailyAudit20251228.md` (all numeric)
- **Rule**: PascalCase applies to word boundaries, dates can use dashes if needed for clarity

### Numbers
- **✅ Correct**: `Phase2Documentation.tt`, `Version3Config.yaml`
- **❌ Wrong**: `phase_2_documentation.tt`

---

## 🚀 Implementation Checklist for AI Assistants

**Before writing ANY file:**

1. **Verify filename format**
   ```
   filename = "VirtualMachineDataFetch.tt"  ← PascalCase? ✅
   ```

2. **Check against standard**
   - Is it PascalCase? 
   - Does it have hyphens or underscores? 
   - If yes to #2: STOP and rename

3. **Document in audit logs**
   - When creating new files, record:
     ```
     File Created: VirtualMachineDataFetch.tt
     Format: PascalCase ✅
     Rationale: [Brief reason for filename]
     ```

4. **Flag legacy filenames**
   - If you see files like `virtual_machine_data.tt` during work:
     - Don't rename immediately (preserve git history)
     - Document in audit logs: "Found legacy: `virtual_machine_data.tt` (rename candidate)"
     - Zencoder cleanup agent will schedule migration

---

## 📊 Migration Strategy

| Phase | Timeline | Action |
|-------|----------|--------|
| **Phase 1** | 2025-12-28 onwards | ✅ All NEW files use PascalCase |
| **Phase 2** | Next 2-4 weeks | When editing existing files, rename to PascalCase |
| **Phase 3** | Q1 2026 | Batch rename remaining legacy files |
| **Phase 4** | Q1 2026 | Verification & exception documentation |

---

## 🔧 Automation & Tooling

### Pre-commit Hook (PLANNED)
```bash
# Will auto-reject new files with - or _ in name
# Status: 🟡 PLANNED (to be implemented in .githooks/)
```

### Zencoder Enforcement (ACTIVE NOW)
The **Cleanup Agent** checks this on every file creation:
1. Verify filename is PascalCase
2. Reject creation if not
3. Document all filename decisions

### External Tool Configuration (Continue, Cursor, etc.)
⚠️ **IMPORTANT**: Zencoder does NOT manage `.continue/`, `.cursor/`, or other IDE tool configurations. Each tool is responsible for its own rules. Filename conventions shown here apply ONLY to Zencoder-managed files (`.zencoder/`, `/Comserv/root/`).

---

## 📎 Related References

- **Primary Authority**: `/Comserv/root/coding-standards-comserv.yaml` (Section 1A)
- **Zencoder Rules**: `coding-standards.yaml` agents:cleanup section (enforcement responsibility)
- **Migration Log**: `/Comserv/root/Documentation/session_history/FilenameConversionLog.md` (audit trail)
- **Enforcement Keywords**: `coding-standards.yaml` Rule 5 (global keywords and execution patterns)

---

## ❓ When in Doubt

**Ask the user** for filename confirmation:

```
User wants to create: "virtual_machine_setup.tt"

I notice this filename uses underscores. According to our PascalCase standard, 
this should be: "VirtualMachineSetup.tt"

Confirm: Should I create it as "VirtualMachineSetup.tt"?
```

---

**Last Updated**: 2025-12-28  
**Maintained By**: Cleanup Agent  
**Questions**: See `/Comserv/root/coding-standards-comserv.yaml` Section 1A
