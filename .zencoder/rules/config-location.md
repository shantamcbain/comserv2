---
description: "Configuration file location and naming standards"
globs: ["**/*Controller*.pm", "**/*Util*.pm", "**/*.tt", "config/*"]
alwaysApply: true
---

# Configuration Location Standards

All configuration files (JSON, YAML, etc.) must be placed in the root/config/ directory relative to the app root (Comserv/root/config/). Use $c->path_to('root', 'config', 'filename') for resolution. For sub-configs like infrastructure, use root/config/infrastructure/. Ensure directories are created with mkdir -p and files chmod 644. Prefer YAML for human-readable configs; fallback to JSON if needed.
