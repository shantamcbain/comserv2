
# AI Documentation Guidelines

## Overview
This document provides guidelines for AI assistants working with the Comserv2 project, specifically focusing on documentation management and organization.

## Documentation Organization

### Directory Structure
All documentation must be placed in the appropriate subdirectory of `/Comserv/root/Documentation/`:

- `/changelog/` - Documentation of changes and fixes
- `/controllers/` - Controller-specific documentation
- `/models/` - Model-specific documentation
- `/deployment/` - Deployment and server setup guides
- `/system/` - System-level documentation
- `/themes/` - Theme system documentation
- `/tutorials/` - User and developer tutorials
- `/general/` - General documentation

### Important Rules

1. **NEVER create documentation files in the application root directory**
   - All documentation must be placed in the appropriate subdirectory of `/Comserv/root/Documentation/`
   - The only exception is the main README.md file in the application root

2. **NEVER create categorization files**
   - Do not create files with names like "Added X to Y category"
   - Do not create files with names like "Formatting title from: X"
   - Do not create files with names like "Categorized as X: Y"
   - Do not create files with names like "Category X has Y pages"

3. **NEVER create temporary files**
   - All files should be properly named and placed in the appropriate directory
   - Do not create files with temporary or intermediate content

## Documentation Standards

1. **File Format**
   - **For browser display**: Use Markdown format with the `.tt` extension
   - **For AI processing**: Files intended for AI to read use `.md` extension
   - **Conversion rule**: If documentation is found in `.md` format, convert it to `.tt` format for browser display
   - **Content format**: Don't use markdown syntax in `.tt` files - use plain text with Template Toolkit formatting
   - Follow consistent formatting within documents

2. **File Naming**
   - Use lowercase with underscores for spaces
   - For changelog entries, use the format: `YYYY-MM-description.tt`
   - For controller documentation, use the controller name: `ControllerName.tt`

3. **Documentation Structure**
   - Start with a clear title using `# Title`
   - Include an overview section
   - Use appropriate headings for sections
   - Include code examples where relevant
   - Link to related documentation

## Creating New Documentation

When creating new documentation:

1. **Determine the appropriate category**
   - Controller documentation goes in `/controllers/`
   - Model documentation goes in `/models/`
   - General guides go in `/general/`
   - Changelog entries go in `/changelog/`

2. **Create the file in the correct location**
   - Use the `str_replace_editor` tool with the correct path
   - Example: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/controllers/MyController.tt`

3. **Update related documentation**
   - If documenting a controller, update the controller list in `/controllers/controller_list.tt`
   - If adding a changelog entry, ensure it follows the standard format
4. **If the documentation is in .md format convert it to .tt format**
   - Don't use md format in the .tt file.
## Example: Documenting a Controller

```markdown
# MyController Controller

## Overview
Brief description of the controller's purpose.

## Key Features
- Feature 1
- Feature 2
- Feature 3

## Methods
- `method1`: Description
- `method2`: Description
- `method3`: Description

## Access Control
This controller is accessible to users with the following roles:
- role1
- role2

## Related Files
- Related file 1
- Related file 2
```

## Example: Creating a Changelog Entry

```markdown
# Feature X Implementation - Month YYYY

## Overview
Brief description of the change.

## Changes Made
- Change 1
- Change 2
- Change 3

## Files Modified
- `/path/to/file1`
- `/path/to/file2`

## Testing
How to test the changes.
```

## Maintaining Documentation

When updating the system:

1. Update relevant documentation files
2. Create changelog entries for significant changes
3. Ensure documentation is placed in the correct location
4. Keep the documentation structure consistent

## Session Planning
Add session tracking section to keep continuity:

### Current Session: File Cleanup & Merge
**Task**: Clean up misplaced files from Codebuddy session
**Status**: COMPLETED
**Files Reviewed & Actions Taken**:
- `/Comserv.pm` (in project root - duplicate) → REMOVED after confirming no useful changes
- `/Comserv/root/lib/` directory (misplaced application files) → MERGED improvements and REMOVED
- `/Comserv/root/Comserv/` directory (nested duplicate) → REMOVED

**Key Changes Merged**:
- ThemeEditor.pm: Added proper error handling with File::Slurp and Try::Tiny modules
- ThemeConfig.pm: Enhanced error handling and added missing utility methods
- Both files now use improved JSON processing with proper error capture

**Operation Count**: Used approximately 18-19 operations for this cleanup session

## Cleaning Up Documentation

If you find documentation files in the wrong location or categorization files:

1. Move documentation files to the correct location 
2. Adjust catagorization if necessary  
3. Remove unnecessary files
4. **ALWAYS check file contents before deletion - may contain useful AI-generated improvements**

## Version Control and Commit Guidelines

### Commit Sequence and Best Practices

**CRITICAL**: Keep commits small and focused to enable easy merging to main branch.

#### Pre-Commit Checklist
1. **Test the fix**: Verify functionality works as expected
2. **Document changes**: Update relevant documentation files
3. **Create changelog entry**: Add entry to appropriate changelog file
4. **Update AI guidelines**: Note any learnings or process improvements

#### Commit Strategy - Small, Focused Commits
**Goal**: Each commit should represent one logical change that can be easily reviewed and merged.

**Recommended commit sequence for bug fixes:**
1. **Commit 1: Core Fix**
   - The minimal code change that fixes the issue
   - Example: "Fix missing get_site_theme method in ThemeConfig model"

2. **Commit 2: Documentation Update** (if substantial)
   - Update relevant documentation
   - Example: "Update ThemeConfig documentation with new method"

3. **Commit 3: Changelog Entry**
   - Add changelog entry documenting the fix
   - Example: "Add changelog entry for ThemeConfig get_site_theme fix"

4. **Commit 4: Tests** (when applicable)
   - Add or update tests for the fix
   - Example: "Add tests for get_site_theme method"

#### Commit Message Standards
- **Format**: `[Component] Brief description of change`
- **Examples**:
  - `[ThemeConfig] Fix missing get_site_theme method`
  - `[Documentation] Update AI guidelines with commit workflow`
  - `[Tests] Add unit tests for theme configuration`

#### Avoiding Large Commits
**NEVER commit more than 50 files at once** unless it's a massive refactoring that cannot be broken down.

**Red flags** that indicate commits should be split:
- Multiple unrelated fixes in one commit
- Documentation + code + tests + changelog all in one commit
- More than 10 files changed (unless they're all related to the same feature)
- Mixing bug fixes with new features

#### Branch Strategy for Easy Merging
1. **Create feature/fix branches** for each logical change
2. **Keep branches short-lived** (1-3 days max)
3. **Merge to main frequently** to avoid conflicts
4. **Use descriptive branch names**: `fix/theme-config-method`, `docs/commit-guidelines`

#### Emergency Fix Protocol
For critical production issues:
1. **Minimal fix first**: Create the smallest possible fix
2. **Test immediately**: Verify the fix resolves the issue
3. **Commit and deploy**: Single commit with clear message
4. **Follow up**: Add documentation and tests in separate commits

### Current Session Update
**Task**: Fix missing get_site_theme method in ThemeConfig
**Status**: COMPLETED - Method implemented and tested
**Files Modified**: 1 file - `/Comserv/lib/Comserv/Model/ThemeConfig.pm`
**Next Steps**: 
- Create changelog entry
- Ready for commit as single focused change