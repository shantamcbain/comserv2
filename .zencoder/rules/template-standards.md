---
description: Template Toolkit Standards and Requirements
globs: ["**/*.tt"]
alwaysApply: true
---

# Template Toolkit (.tt) Standards

## Required PageVersion Header Format
All .tt files must include this exact format:
```
[% META title = 'Page Title Here' %]
[% PageVersion = 'relative/path/filename.tt,v 0.01 YYYY/MM/DD author Exp author ' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]
```

## Template Standards
- **Theme Compliance:** Use theme system variables for styling - NO page-specific CSS
- **Debug Mode:** Include debug mode blocks for development visibility
- **Responsive Design:** Implement mobile-first responsive design patterns
- **HTML Structure:** Use proper semantic HTML structure
- **Template Toolkit:** Follow Template Toolkit best practices

## Navigation Integration
When working with navigation templates:
- **Main Navigation:** Include via `/Navigation/navigation.tt`
- **Admin Menu:** Use `/Navigation/admintopmenu.tt` for admin-only sections
- **Dropdown Menus:** Reference existing dropdown templates in `/Navigation/` directory

## Documentation File Rules - CRITICAL
- **File Format:** ONLY `.tt` files for application documentation - NO `.md` files
- **EXISTING FILES FIRST:** ALWAYS search for and use existing files before creating new ones
- **Naming Consistency:** Use same file names across AI sessions to prevent content loss
- **Content Priority:** Always improve existing files rather than creating new ones
- **Role-Based Access:** Respect existing Documentation/index.tt role-based structure
- **Directory Consolidation:** Use established directory structure - don't create new directories
- **MANDATORY SYNC:** Always verify documentation matches actual code functionality
- **DISCREPANCY TRACKING:** Document all differences between docs and code
- **UPDATE PRIORITY:** Fix documentation discrepancies before implementing new features

## Documentation Synchronization Protocol
1. **Read Current Documentation:** Understand documented behavior
2. **Read Actual Code:** Understand actual implementation
3. **Compare States:** Identify discrepancies
4. **Fix Documentation:** Update docs to match current code state
5. **Implement Changes:** Make code modifications
6. **Update Documentation:** Reflect new functionality
7. **Verify Consistency:** Ensure docs and code align

## File Creation Protocol
1. **Search First:** Use file search tools to find existing similar files
2. **Check Directory:** Look at existing directory structure in target location
3. **Ask User:** If multiple similar files exist, ask which should be updated
4. **Update Existing:** Improve existing files rather than creating duplicates

## Documentation Configuration Management - CRITICAL
When adding new documentation files (.tt):
- **ALWAYS update:** `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/config/documentation_config.json`
- **NEVER update:** `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/documentation_config.json` (legacy file)
- **Required fields:** id, title, description, path, categories, roles, site, format
- **Format:** "template" for .tt files, "markdown" for .md files
- **Categories:** Use existing categories: user_guides, admin_guides, developer_guides, tutorials, modules, controllers, models, changelog, proxmox, documentation, templates
- **Roles:** ["developer", "admin"] for technical docs, ["normal", "editor", "admin", "developer"] for user docs