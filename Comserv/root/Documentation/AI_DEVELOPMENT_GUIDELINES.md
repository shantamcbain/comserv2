# AI Development Guidelines for Comserv2

**Version:** 1.0  
**Last Updated:** 2025-09-20  
**Author:** Development Team

## Core Principles

1. **Follow Existing Patterns**: Always examine and follow existing code patterns before creating new ones.
2. **Reuse Existing Code**: Identify and reuse existing modules, utilities, and templates.
3. **Respect Directory Structure**: Place new files in the appropriate existing directories.
4. **Maintain Naming Conventions**: Follow established naming patterns for files, classes, and methods.
5. **Request Permission for Structural Changes**: Obtain explicit permission before creating new directories or changing established patterns.

## File Modification Guidelines

### CRITICAL: No .backup File Creation
- **NEVER create .backup files** when modifying existing files
- .backup files eliminate user's ability to read changes
- .backup file creation consumes unnecessary resources
- Instead: Provide exact changes in +/- diff format for copy-paste ready application
- Show before/after code blocks when beneficial for clarity
- Use ExecuteShellCommand only for viewing file contents, not for creating backup copies

### Preferred Change Documentation Format
```diff
- old code line
+ new code line
```

### Resource Conservation
- Each tool call counts as 1 operation toward the 10-15 operation limit
- Avoid unnecessary file operations
- Combine multiple changes into single clear documentation

## Session Workflow (5-10 Prompts)

Given the limited number of interactions in each session (5-10 prompts), follow this workflow:

### Long Chat Warning
- **Prompts 1-10**: Optimal working range
- **Prompts 11-15**: Acceptable but approaching limits  
- **Prompts 16+**: LONG CHAT ZONE - High risk of resource exhaustion and context drift
- **When entering long chats**: Focus on completing current task efficiently, avoid scope creep
- **Resource management becomes critical** - each tool call must be essential

1. **Read Documentation & Code** (1-2 prompts)
   - Examine relevant documentation in `/Comserv/root/Documentation/`
   - Review existing code patterns in related modules
   - Identify reusable components

2. **Propose Solution** (1 prompt)
   - Outline approach based on existing patterns
   - Identify files to modify
   - Highlight any reused components

3. **Implement Solution** (2-3 prompts)
   - Make minimal necessary changes
   - Follow existing code style and patterns
   - Document code with appropriate comments

4. **Test & Debug** (1-2 prompts)
   - Verify functionality
   - Address any issues

5. **Update Documentation** (1 prompt)
   - Update relevant documentation files
   - Create commit message

## Authentication System

Authentication approach is defined in `authentication_evolution_plan.md`:
- **Current phase**: Phase 1 (compatibility layer)
- **DO NOT** change authentication approach without reading the plan first
- **DO NOT** modify templates for authentication in current phase  
- **ASK PERMISSION** before changing documented authentication strategy
- **Templates expect** session-based authentication: `c.session.username`, `c.session.roles`

## File Storage Guidelines

### Database vs. JSON Storage

1. **Database Storage**:
   - Use for persistent data requiring complex queries
   - Follow existing database models in `Comserv/lib/Comserv/Model/`
   - Access via the configured database connections in `db_config.json`

2. **JSON File Storage**:
   - Appropriate for configuration data and simple data models
   - Use for prototyping before implementing database storage
   - Store in `Comserv/config/` directory with descriptive filenames
   - Follow the pattern in `NetworkMap.pm` for loading/saving JSON data

## Directory Structure Guidelines

1. **Controllers**: `/Comserv/lib/Comserv/Controller/`
   - One controller per functional area
   - Follow RESTful action naming when possible

2. **Models**: `/Comserv/lib/Comserv/Model/`
   - Database models in appropriate subdirectories
   - Result classes for database tables

3. **Utilities**: `/Comserv/lib/Comserv/Util/`
   - Reusable helper functions
   - Standalone functionality

4. **Templates**: `/Comserv/root/[Module]/`
   - Template files (.tt) for each module
   - Follow existing template patterns

5. **Documentation**: `/Comserv/root/Documentation/`
   - Organized by category/role  
   - Use Template Toolkit (.tt) format for all documentation files
   - Follow proper HTML structure with Template Toolkit variables

## Template System Guidelines

1. **Use Template Toolkit (.tt) files**
   - Follow patterns in existing templates
   - Use proper includes and template hierarchy
   - All documentation files must use .tt format with proper HTML structure

2. **Template Variables**
   - Access session data via `c.session`
   - Controller data via `c.stash`
   - Use consistent variable naming
   - Include PageVersion variable for version tracking

3. **Error Handling**
   - Use TRY/CATCH blocks for potentially problematic includes
   - Provide fallback content

4. **Documentation Template Structure**
   - Include proper HTML markup with semantic elements
   - Use CSS classes for consistent styling
   - Add debug information blocks for troubleshooting

## Change Documentation & Session Continuity

### CRITICAL: Cross-Session Change Tracking
- **AI agents cannot access previous chat histories** between sessions
- **MUST document all code changes** in this file or create a dedicated change log
- **Before ending a session**: Update this guidelines file with:
  - List of modified files
  - Summary of changes made
  - Any new patterns or conventions established
- **At start of new session**: Review recent changes documented here
- **Use a dedicated "Recent Changes" section** at the end of this file for temporary change tracking

### Change Log Format
```markdown
### Recent Changes (Session Date: YYYY-MM-DD)
**Modified Files:**
- path/to/file1: Description of change
- path/to/file2: Description of change

**Summary:** Brief overview of what was accomplished
**Notes:** Any important context for future sessions
```

## Commit Message Format

```
[Module] Brief description of changes

- Detailed bullet point of change 1
- Detailed bullet point of change 2

Related files:
- path/to/modified/file1.pm
- path/to/modified/file2.tt

Documentation updates:
- Updated path/to/documentation.md
```

## Example: Adding a Feature to NetworkMap

### Good Approach:
1. Examine existing `NetworkMap.pm` utility and controller
2. Reuse the JSON storage pattern
3. Add new methods to existing classes
4. Update existing templates
5. Document in the appropriate documentation files

### Avoid:
1. Creating new directories without clear need
2. Implementing different storage mechanisms
3. Duplicating existing functionality
4. Using different naming conventions
5. Creating new templates when existing ones can be modified

## Chat Session Handoff Procedure

When approaching chat limits (typically 20+ prompts), follow this handoff procedure:

### Pre-Handoff Checklist:
1. **Update Recent Changes** - Document all work completed in current session
2. **Create Handoff Summary** - Write detailed continuation instructions
3. **Note Current State** - Document exactly where work stopped
4. **List Next Steps** - Prioritized action items for next session

### Handoff Summary Format:
```
### HANDOFF TO NEXT SESSION (Date: YYYY-MM-DD)
**Current Issue:** [Brief description]
**Root Cause:** [What was identified]
**Files Analyzed:** [Key files examined]
**Solution Ready:** [What needs to be implemented]
**Next Steps:** [Prioritized action list]
**Testing Required:** [What needs verification]
```

## Final Checklist

Before submitting changes, verify:

- [ ] Code follows existing patterns and conventions
- [ ] No unnecessary new files or directories created
- [ ] Existing code reused where appropriate
- [ ] Documentation updated
- [ ] Commit message prepared according to format
- [ ] Changes documented in Recent Changes section for future sessions

## Recent Changes

### Recent Changes (Session Date: 2025-01-10)
**Modified Files:**
- Comserv/root/Documentation/AI_DEVELOPMENT_GUIDELINES.md: Added cross-session change tracking requirements and Recent Changes section
- Comserv/root/Documentation/documentation_config_guide.md: Converted from .md to .tt format with proper Template Toolkit structure
- Comserv/root/Documentation/controllers/README.md: Converted from .md to .tt format with HTML structure and debug blocks
- Comserv/root/Documentation/models/README.md: Converted from .md to .tt format with enhanced content structure

**Summary:** Enhanced guidelines to require documentation of code changes between AI agent sessions since chat history is not accessible across sessions. Began systematic conversion of documentation files from .md to .tt format per guidelines requirement.

**Notes:** This addresses the continuity issue where AI agents need to understand what changes were made in previous sessions when writing commit messages or continuing development work. Updated Template System Guidelines to specify that all documentation must use .tt format with proper HTML structure.

### Documentation Format Conversion (Session Date: 2025-01-10)
**Modified Files:**
- Comserv/root/Documentation/AI_DEVELOPMENT_GUIDELINES.md: Updated Template System Guidelines to specify .tt format requirement for all documentation
- Comserv/root/Documentation/documentation_config_guide.tt: Converted from .md to proper Template Toolkit format
- Comserv/root/Documentation/controllers/README.tt: Converted from .md with enhanced structure
- Comserv/root/Documentation/models/README.tt: Converted from .md with model documentation overview

**Summary:** Systematically converted key documentation files from .md to .tt format as required by AI guidelines. Updated guidelines to clarify that all documentation must use Template Toolkit format with proper HTML structure.

**Implementation Details:**
- Added proper Template Toolkit PageVersion variables
- Included HTML semantic structure with CSS classes
- Added debug information blocks for troubleshooting
- Enhanced content structure for better readability
- Updated file extensions from .md to .tt

**Next Steps:** Continue converting remaining .md files in Documentation directory to .tt format, prioritizing frequently accessed documentation files.

### Theme System Issue Analysis (Session Date: 2025-01-10)
**Problem Identified:**
- Themes not displaying correctly for SiteName sites
- Found conflicting theme configuration files:
  - `/static/config/theme_definitions.json` (flat structure, incomplete)  
  - `/static/css/themes/theme_definitions.json` (proper structure with "themes" wrapper)
- ThemeConfig.pm model looking for file in `/static/config/` but proper file is in `/static/css/themes/`

**Root Cause:** 
- Theme configuration file location mismatch
- Missing proper "themes" wrapper and "site_themes" mapping in config file

**Solution Required:**
- Either move proper theme_definitions.json to `/static/config/` directory
- Or update ThemeConfig.pm to look in `/static/css/themes/` directory
- Consolidate to single authoritative theme configuration file

### HANDOFF TO NEXT SESSION (Date: 2025-01-10)

**Current Issue:** Themes not displaying correctly for SiteName sites due to theme configuration file location mismatch.

**Root Cause:** ThemeConfig.pm model is configured to load theme definitions from `/static/config/theme_definitions.json`, but the complete and correct configuration file is located at `/static/css/themes/theme_definitions.json`. The config file has incomplete/flattened structure missing crucial elements.

**Files Analyzed:**
- `/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/ThemeConfig.pm` (line 20: file path)
- `/home/shanta/PycharmProjects/comserv2/Comserv/root/static/config/theme_definitions.json` (incomplete structure)
- `/home/shanta/PycharmProjects/comserv2/Comserv/root/static/css/themes/theme_definitions.json` (complete structure)
- `/home/shanta/PycharmProjects/comserv2/Comserv/root/Header.tt` (theme CSS loading)
- `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/theme_system.tt` (theme documentation)

**Key Evidence:**
- .tt documentation consistently points to `/static/css/themes/` as authoritative location
- Complete theme_definitions.json has "themes" wrapper, "site_themes" mappings, all themes including "mcoop"
- Incomplete config version missing "themes" wrapper and "site_themes" object
- Individual theme CSS files exist and are properly referenced in Header.tt

**Solution Ready:** Two options identified:
1. **RECOMMENDED**: Copy complete theme_definitions.json from `/static/css/themes/` to `/static/config/`
2. Update ThemeConfig.pm line 20 to point to `/static/css/themes/theme_definitions.json`

**Next Steps:**
1. **PRIORITY 1**: Execute: `cp /home/shanta/PycharmProjects/comserv2/Comserv/root/static/css/themes/theme_definitions.json /home/shanta/PycharmProjects/comserv2/Comserv/root/static/config/theme_definitions.json`
2. Test theme loading by starting dev server and checking SiteName-based sites (CSC, USBM, APIs, MCoop)
3. Verify theme CSS loading in browser dev tools
4. Write E2E test for theme functionality with user permission
5. Clean up - remove duplicate theme_definitions.json from `/static/css/themes/` if desired

**Testing Required:**
- Start dev server in background
- Navigate to different SiteName sites
- Verify correct theme CSS files are loaded
- Check browser dev tools for CSS file requests
- Test theme switching functionality

**File Structure Context:**
- Theme CSS files: `/static/css/themes/*.css` (exist and working)
- Theme configuration: Should be in `/static/config/theme_definitions.json` per ThemeConfig.pm
- Theme mappings: `/static/config/theme_mappings.json` (exists, simple site-to-theme mapping)

### CSS Theme System Documentation Conversion (Session Date: 2025-01-19)
**Modified Files:**
- Comserv/root/Documentation/admin/theme_mappings_handling.tt: Converted from .md to proper Template Toolkit format with HTML structure
- Comserv/root/Documentation/ThemeConfig.tt: Converted from .md to Template Toolkit format with enhanced styling classes  
- Comserv/root/static/css/README_THEME_SYSTEM.tt: Converted from .md to Template Toolkit format with semantic HTML structure

**Summary:** Completed conversion of CSS theme system documentation files from .md to .tt format as required by AI guidelines. All files now use proper Template Toolkit structure with HTML semantic elements, CSS classes, debug blocks, and PageVersion variables.

**Implementation Details:**
- Added proper Template Toolkit headers with META title and PageVersion variables
- Implemented semantic HTML structure with section elements and CSS classes
- Added debug information blocks for troubleshooting
- Enhanced content structure with alert boxes and feature lists
- Updated cross-references to use .tt extensions
- Maintained all original content while improving presentation structure

**Files Converted:**
1. **theme_mappings_handling.tt** - Git pull operations and theme mapping management
2. **ThemeConfig.tt** - Theme configuration overview and related documentation links
3. **README_THEME_SYSTEM.tt** - Comprehensive theme system technical documentation

**Notes:** This completes the CSS theme system documentation conversion portion of the broader .md to .tt conversion project. All theme-related documentation is now in Template Toolkit format consistent with project guidelines.