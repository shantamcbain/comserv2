# Changelog

All notable changes to the Comserv project will be documented in this file.

## [Unreleased]

### Fixed
- Documentation display and markdown rendering
  - Fixed markdown content display in documentation viewer
  - Added dedicated CSS for markdown viewer (markdown-viewer.css)
  - Modified JavaScript to properly display section content
  - Set sections to be expanded by default
  - Fixed toggle functionality for collapsible sections
- Template error in pagetop.tt
  - Fixed "Argument isn't numeric in numeric gt (>)" error
  - Added proper checks for session roles before using grep method
  - Improved template stability for guest users and incomplete sessions

### Added
- Enhanced Documentation_Workflow.md with comprehensive development workflow
  - Added detailed steps for creating, testing, and maintaining documentation
  - Included guidelines for changelog updates and Git commit messages
  - Added new sections on logging, debugging, and maintenance
  - Improved troubleshooting section with additional checks
- Documentation organization script
  - Created script to move markdown files from root to docs directory
  - Implemented intelligent file categorization and naming preservation
  - Added logging for file operations

## [2025-04-08]

### Fixed
- Documentation display and markdown rendering issues
  - Fixed CSS path references in the markdown viewer template
  - Improved section display and collapsible content
  - Enhanced overall user experience when viewing documentation

### Added
- Comprehensive documentation workflow guidelines
  - Step-by-step process for documentation development
  - Testing procedures for documentation changes
  - Changelog update guidelines
  - Git commit message standards for documentation

## [2025-04-02]

### Changed
- Documentation template refactoring
- Documentation admin visibility improvements

## [2024-07-15]

### Fixed
- Project ID handling in forms
- Proxmox controller issues

## [2024-06-20]

### Fixed
- Project edit functionality