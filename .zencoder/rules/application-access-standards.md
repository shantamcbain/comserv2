---
description: "Application access standards and local development URLs"
globs: ["**/*.pm", "**/*.tt", "**/*.conf", "**/*.yaml"]
alwaysApply: true
---

# Application Access Standards

Access the application via workstation.local:3001 for local development and testing. Use this URL in all suggestions for API calls, browser testing, or configurations. Note future plans to implement api.hostname for whitelisting sites with API access; currently, allow workstation.local as it resolves via hosts file (not DNS). When suggesting API-related code, prioritize secure, centralized access controls (e.g., in controllers or config files) to enforce host whitelisting.
