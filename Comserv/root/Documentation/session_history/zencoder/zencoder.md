---
name: zencoder
description: Provides context and instructions for accessing and handling all files in the .zencoder directory, which contains configuration files above the application root.
globs: [".zencoder/**"]
alwaysApply: true
---

# .zencoder Directory Overview

This directory contains configuration files above the application root and is part of the project. The AI agent can read and edit any file within this directory as needed for queries related to configuration, keywords, or Zencoder functionality.

Key files and subdirectories include:

- rules/keywords: Contains all the keywords used in Zencoder.
- rules/repo.md: The main configuration file for Zencoder.

For a full list of files, you can reference them using patterns like `.zencoder/*` or `.zencoder/rules/*` in context providers such as `@file` or when searching the codebase.

Use these files when handling queries related to Zencoder configuration, encoding processes, or any relevant topics. The agent has full access to read, analyze, and suggest edits to any file in this directory.