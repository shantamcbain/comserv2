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

## Session Workflow (5-10 Prompts)

Given the limited number of interactions in each session (5-10 prompts), follow this workflow:

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