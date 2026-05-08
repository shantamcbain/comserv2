---
description: "Documentation editing and Template Toolkit (.tt) standards"
globs: ["Comserv/root/Documentation/**"]
alwaysApply: false
---

# Documentation Standards

## Required PageVersion Header Format
All .tt files must include this exact format:
```
[% META title = 'Page Title Here' %]
[% PageVersion = 'relative/path/filename.tt,v 0.01 YYYY/MM/DD author Exp author ' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]
```

When editing or creating files in Comserv/root/Documentation/, strictly adhere to these tuned standards to ensure consistency, manageability, and efficiency. Prioritize file reads over chat history; standardize versions/dates to reduce drift.

## General Principles

1. **Format and Layout Consistency**: All files MUST be Template Toolkit (.tt) ONLY for live docs. .md is STRICTLY for Zencoder/AI drafts—NEVER edit/reference .md for publication. Base EVERY file on 'documentation_tt_template.tt' EXACTLY: [% META %] block, [% PageVersion %] RCS line, debug [% IF %], <div class="container"> with .row/.col grid, inline CSS vars (var(--text-color), etc.), metadata div, sections (Overview, Prerequisites, Key Features, Getting Started with steps/code, Advanced, Troubleshooting with warning/info divs, Config Table, See Also success div, Footer). For readability: Use semantic HTML (<h2 id="...">, <ul>, <pre><code>); add unique TOC (id="toc") with absolute anchors.

2. **Content Accuracy and File Reads**: BEFORE ANY EDIT, ALWAYS read the file with read_file and verify state with parallel tools (codebase for code, file_glob_search for structure, run_terminal_command("date") for current time). IGNORE chat history if it conflicts—treat files as source of truth. Reflect LIVE code (e.g., routes from controllers); fix past errors (e.g., demote .md to 'staging only; merge to .tt'). Log changes in metadata/changelog refs. For evolution: Break fixes into minor versions (e.g., .01 for readability tweaks).

3. **Navigation**: Each .tt MUST have self-contained TOC (id="toc") post-metadata, with absolute anchors (<a href="#id">) and app links (<a href="/Documentation/page">). Ensure works standalone or [% INCLUDE %]d—no relative paths.

4. **No .md Usage**: Reject .md for live. If .md draft (Zencoder workaround), read it, merge to .tt (adapt Markdown to HTML/grid), then SUGGEST deletion (run_terminal_command("rm path") after user confirm). Update all refs to .tt primary.

5. **User Visibility and Editing**: ALWAYS provide diff summary (+/- style) AFTER tool apply. Use edit_existing_file/single_find_and_replace with placeholders (e.g., [% ... existing ... %]). For complex (e.g., merges), break into steps/sub-rules; get approval before final. Notify mismatches (e.g., "History said X, file is Y").

6. **Token Conservation and Readability**: Limit to essentials: Read/verify → minimal edit → summary. For large tasks, create temp sub-rules (e.g., "Temp_Merge_MD"). Prioritize: Human readability (clear sections, tables); AI (structured TT, no ambiguity). Use X.YY versions (1.01 style for daily minors; increment .01 per edit); dates from system (YYYY-MM-DD for div; full "Fri MMM DD HH:MM:SS TZ YYYY" for META; "YYYY/MM/DD" for PageVersion RCS line—no variations).

## Documentation File Rules - CRITICAL

- **File Format**: ONLY `.tt` files for application documentation - NO `.md` files.
- **EXISTING FILES FIRST**: ALWAYS search for and use existing files before creating new ones.
- **Naming Consistency**: Use same file names across AI sessions to prevent content loss.
- **Content Priority**: Always improve existing files rather than creating new ones.
- **Role-Based Access**: Respect existing Documentation/index.tt role-based structure.
- **Directory Consolidation**: Use established directory structure - don't create new directories.
- **MANDATORY SYNC**: Always verify documentation matches actual code functionality.
- **DISCREPANCY TRACKING**: Document all differences between docs and code.
- **UPDATE PRIORITY**: Fix documentation discrepancies before implementing new features.

## Documentation Synchronization Protocol

1. **Read Current Documentation**: Understand documented behavior.
2. **Read Actual Code**: Understand actual implementation.
3. **Compare States**: Identify discrepancies.
4. **Fix Documentation**: Update docs to match current code state.
5. **Implement Changes**: Make code modifications.
6. **Update Documentation**: Reflect new functionality.
7. **Verify Consistency**: Ensure docs and code align.

## File Creation Protocol

1. **Search First**: Use file search tools to find existing similar files.
2. **Check Directory**: Look at existing directory structure in target location.
3. **Ask User**: If multiple similar files exist, ask which should be updated.
4. **Update Existing**: Improve existing files rather than creating duplicates.

## Documentation Configuration Management - CRITICAL

When adding new documentation files (.tt):
- **ALWAYS update**: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/config/documentation_config.json`
- **NEVER update**: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/documentation_config.json` (legacy file)
- **Required fields**: id, title, description, path, categories, roles, site, format
- **Format**: "template" for .tt files, "markdown" for .md files
- **Categories**: Use existing categories: user_guides, admin_guides, developer_guides, tutorials, modules, controllers, models, changelog, proxmox, documentation, templates
- **Roles**: ["developer", "admin"] for technical docs, ["normal", "editor", "admin", "developer"] for user docs
