---
description: Systematic Debugging and Documentation Sync Protocols
globs: ["**/*.pm", "**/*.pl", "**/*.t", "**/*.tt"]
alwaysApply: true
priority: 2
---

# Systematic Debugging Protocol

## MANDATORY DEBUGGING WORKFLOW

### Step 1: Complete Analysis Phase
1. **Read Zencoder Guidelines:** Review all .zencoder/rules/ files
2. **Read Application Documentation:** Study relevant .tt documentation files
3. **Read Codebase Components:**
   - Controllers (*.pm in Controller/)
   - Models (*.pm in Model/)
   - Templates (*.tt in root/)
   - Schema files (Result/*.pm)
4. **Application Log Analysis:** Read `/Comserv/logs/application.log`
5. **Trace Execution Path:** Follow code path that leads to error

### Step 2: State Comparison & Documentation
1. **Document Current State:** What the code actually does
2. **Document Expected State:** What documentation says it should do
3. **List Discrepancies:** All differences between docs and code
4. **Error Analysis:** Actual errors vs expected behavior
5. **Create Fix Plan:** Include both code fixes and documentation updates

### Step 3: Implementation Priority
1. **Fix Documentation Discrepancies FIRST:** Align docs with current code
2. **Implement Bug Fix:** Apply necessary code changes
3. **Update Documentation:** Reflect new functionality
4. **Test Implementation:** Verify fix works correctly
5. **Document Changes:** Record what was changed and why

### Step 4: Verification & Commit
1. **Final State Check:** Ensure docs and code are synchronized
2. **Test Complete Workflow:** Verify end-to-end functionality
3. **Present Changes:** Show all modifications in diff format
4. **Commit Preparation:** Ready for version control
5. **Update Task Status:** Mark completed items, note remaining work

## Log Analysis Protocol
- **Primary Log:** `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log`
- **Error Patterns:** Look for stack traces, method calls, variable states
- **Execution Flow:** Trace request path through controllers and models
- **Debug Mode:** Enable session debug_mode for detailed output

## Documentation Sync Requirements
- **NEVER ignore documentation discrepancies**
- **ALWAYS fix docs before implementing new features**
- **TRACK all changes made to maintain consistency**
- **UPDATE documentation to reflect new code behavior**

## Code Change Format
Present all changes using +- diff format:
```diff
--- original/file/path
+++ modified/file/path
@@ -line,count +line,count @@
-removed line
+added line
 unchanged line
```

## Performance Issues
- **Database Queries:** Check for slow queries
- **Memory Usage:** Monitor memory consumption
- **Template Rendering:** Check template compilation times
- **Network Latency:** Consider network-related delays