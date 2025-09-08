# AI Assistant Guidelines for Comserv System

## IMPORTANT: File Modification Guidelines

**WARNING TO ALL AI ASSISTANTS**: Never replace or modify existing files without explicit permission from the user. Always ask for confirmation before making changes to the codebase.

## Development Guidelines

For comprehensive development guidelines specific to the Comserv2 system, refer to:
- [AI Development Guidelines](/Documentation/AI_DEVELOPMENT_GUIDELINES.md)

These guidelines cover:
- Following existing code patterns
- Reusing existing components
- Respecting directory structure
- Maintaining naming conventions
- Proper workflow for limited-prompt sessions

## Filename and Package Consistency

When working with Perl modules in the Comserv system, ensure that filenames match their package declarations:

- **Correct**: A file named `Documentation.pm` should contain the package `Comserv::Controller::Documentation`
- **Incorrect**: A file named `Documantation.pm` containing the package `Comserv::Controller::Documentation`

### Known Issue Example

The system previously had an issue where:
- The controller file was named `Documantation.pm` (with an 'a')
- But the package inside was declared as `Comserv::Controller::Documentation` (with an 'o')

This mismatch caused both the `/documentation` and `/Documentation` routes to fail.

## Logging Best Practices

Always use the `log_with_details` method for comprehensive logging:

```perl
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'method_name',
    "Detailed message with relevant information");
```

This ensures that:
1. The log level is properly set
2. File and line information is captured
3. The method name is recorded
4. A detailed message is provided

## Error Handling

When encountering errors:

1. Log the error with appropriate details
2. Add the error message to the stash for display to the user
3. Use debug messages for additional context

Example:
```perl
# Log the error
$self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'method_name', 
    "Error occurred: $error_message");

# Add to stash for display
$c->stash(
    error_msg => "An error occurred: $error_message",
    debug_msg => "Technical details: $technical_details" # Only shown in debug mode
);
```

## Documentation System Structure

The documentation system is organized into categories:
- User guides
- Admin guides
- Developer guides
- Tutorials
- Site-specific documentation
- Module documentation
- Controller documentation
- Model documentation
- Changelog

Each category has role-based access control to ensure users only see relevant documentation.

For more details, see:
- [Documentation System Overview](/Documentation/documentation_system_overview)
- [Documentation Filename Issue](/Documentation/documentation_filename_issue)
- [Controller Routing Guidelines](/Documentation/controller_routing_guidelines)
- [Controllers Documentation](/Documentation/controllers)

## File Naming Conventions

Follow these conventions for documentation files:
- Use lowercase with underscores for filenames
- Use `.md` for Markdown files
- Use `.tt` for Template Toolkit files
- Include the category in the filename when appropriate

Example: `user_guide_login.md`, `admin_installation.tt`

## Data Storage Patterns

### JSON to MySQL Transition Pattern

The Comserv2 system uses a development pattern where:

1. **Initial Implementation**: New features often start with JSON file storage
   - Example: `NetworkMap.pm` uses JSON for storing network device information
   - JSON files are typically stored in `Comserv/config/` directory
   - This allows for rapid prototyping and iteration

2. **Database Migration**: As features mature, data is migrated to MySQL
   - Database models are created in `Comserv/lib/Comserv/Model/`
   - Database configuration is managed via `db_config.json`
   - The application supports multiple database connections

When implementing new features:
- Follow this pattern of starting with JSON if appropriate
- Reuse existing JSON handling code (see `NetworkMap.pm` as an example)
- Document the planned transition to database storage