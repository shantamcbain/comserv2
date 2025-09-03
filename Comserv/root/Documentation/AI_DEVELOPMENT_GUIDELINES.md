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
   - Use markdown format

## Template System Guidelines

1. **Use Template Toolkit (.tt) files**
   - Follow patterns in existing templates
   - Use proper includes and template hierarchy

2. **Template Variables**
   - Access session data via `c.session`
   - Controller data via `c.stash`
   - Use consistent variable naming

3. **Error Handling**
   - Use TRY/CATCH blocks for potentially problematic includes
   - Provide fallback content

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

**Summary:** Enhanced guidelines to require documentation of code changes between AI agent sessions since chat history is not accessible across sessions.

**Notes:** This addresses the continuity issue where AI agents need to understand what changes were made in previous sessions when writing commit messages or continuing development work.