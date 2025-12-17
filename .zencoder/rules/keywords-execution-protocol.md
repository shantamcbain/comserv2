---
description: "Universal keyword execution protocol for all Zencoder workflows"
alwaysApply: true
---

# Zencoder Keyword Execution Protocol - UNIVERSAL RULES

**Purpose**: Central execution rules that apply to ALL Zencoder keywords across all agents

**Last Updated**: Thu Dec 11 2025  
**Version**: 1.0 (Modular version - extracted from keywords.md)

---

## EXECUTION PROTOCOL (MANDATORY FOR ALL AGENTS)

### Detection & Immediate Execution

**When Keyword Detected** (STOP - DO NOT ANALYZE):
1. STOP all analysis, explanations, and questions
2. READ the keyword definition immediately (reference keywords-global.md or keywords-disabled-tasks.md)
3. EXECUTE the steps immediately without any preamble or explanation

**Command Formats** (Both trigger immediate execution):
1. **Slash Command Format**: `/keywordname` (e.g., `/chathandoff`, `/sessionhandoff`)
2. **Legacy Format**: `Execute Keyword: [keyword name]` (e.g., `Execute Keyword: Chat Handoff`)

### Execution Rules

- When user uses EITHER format above, **IMMEDIATELY** execute without asking questions
- **ALL KEYWORD DEFINITIONS ARE HERE** - Reference appropriate file:
  - Global keywords: `keywords-global.md`
  - Disabled keywords: `keywords-disabled-tasks.md`
- **DO NOT** ask "where is the keyword documentation?" 
- **DO NOT** ask for clarification unless the keyword itself requires user input
- **DO NOT** explain what you're about to do - just do it
- **EXECUTE IMMEDIATELY** - this is a direct command, not a request for analysis

### Protocol Violation Response

- If AI asks ANY question after keyword command, user will respond with: `PROTOCOL VIOLATION - EXECUTE NOW`
- Upon receiving this response, AI must IMMEDIATELY execute the keyword and its inputs without further discussion
- **IMPORTANT**: When processing protocol violation response, AI must STILL parse and preserve all original command parameters including `note:`, `prompt:`, and other optional arguments from the initial command
- This is the final warning - execute or fail

---

## HYBRID PREVENTION

If both `/chathandoff` AND `/sessionhandoff` appear in same prompt:
- **IGNORE** `/chathandoff`
- **PROCESS ONLY** `/sessionhandoff` (session archive makes chat handoff redundant)

---

## File References for All Keyword Details

**Global Keywords** (Required for ALL agents):
- Read: `keywords-global.md`
- Contains: `/chathandoff`, `/sessionhandoff`, `/updateprompt`, `/validatett`
- All agents MUST know these

**Disabled/Task-Specific Keywords** (Reference only):
- Read: `keywords-disabled-tasks.md`
- Contains: `/checktodos`, `/dotodo`, `/createnewtodo`, `/createnewproject`
- Status: Awaiting Docker/application restoration

**Execution Rules** (All keywords):
- Read: This file (`keywords-execution-protocol.md`)
- Contains: Universal detection and execution protocol

---

## Agent Responsibilities

**For Zencoder Configuration Agents** (Cleanup Agent, etc.):
1. Read `keywords-global.md` at start of session
2. Understand execution protocol (this file)
3. Reference `keywords-disabled-tasks.md` only if user uses those keywords
4. Always route others to appropriate file when questions arise

**For All Other Agents** (MainAgent, Debug, etc.):
1. Read `keywords-global.md` at start of session
2. Understand execution protocol (this file)
3. Execute keywords immediately when detected
4. Do NOT analyze - immediate execution is the rule

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-11 | Extracted execution protocol from keywords.md into modular structure; consolidated universal rules |

