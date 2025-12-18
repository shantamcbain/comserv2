---
description: "Mandatory /updateprompt workflow for all agents—tracking chat progress and violations"
alwaysApply: true
---

# /updateprompt Workflow - MANDATORY FOR ALL AGENTS
**Version**: 1.0  
**Updated**: December 14, 2025  
**Enforcement Level**: 🔴 CRITICAL - Required at end of every prompt

⚠️ **THIS IS NOT A KEYWORD** - This is an **executable workflow action** all agents must perform.

---

## THE ACTION (Non-Negotiable)

At the **end of every prompt**, before finishing output, execute:

```
[/updateprompt executed]
```

This signals that the agent is:
1. Logging the prompt action to session tracking
2. Clearing the prompt for continuation or completion
3. Following the mandatory workflow path (A/B/C)

---

## WHEN TO EXECUTE /updateprompt

**At the END of EVERY prompt you generate**, unless:
- The prompt is your FIRST output (you must initialize first)
- The prompt is truly minimal (< 1 sentence - rare)

**Mandatory Timing**:
- ✅ Execute before stating "Prompt complete"
- ✅ Execute before calling `ask_questions()` function
- ✅ Execute before moving to next task
- ✅ Execute if prompt is long (>500 words)
- ❌ NEVER skip at end of significant output

---

## EXECUTION SEQUENCE (Step-by-Step)

### Step 1: Perform Your Work
Whatever the prompt is (code, analysis, questions, edits):
- Analyze files
- Make decisions
- Edit code
- Answer questions
- Use tools as needed

### Step 2: Determine the Path
Before finishing, ask yourself:

**PATH A - User Input Needed?**
```
Did I need to ask the user something?
→ YES: Use ask_questions() function + execute /updateprompt
```

**PATH B - Work Complete?**
```
Did I finish the work without needing user input?
→ YES: State "Prompt complete" + execute /updateprompt
```

**PATH C - More Work in Next Prompt?**
```
Did I do work but not finish everything?
→ YES: Execute /updateprompt + indicate continuation
```

### Step 3: Add Execution Statement
At the **END of your response**, add:

```
[/updateprompt executed] → [followed by which path (A/B/C)]
```

---

## CORRECT FORMAT EXAMPLES

### Example 1: Using ask_questions() (PATH A)
```
I've analyzed the file and found the issue. Requesting user confirmation:

<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{"question": "Apply the fix?", "options": ["Yes", "No", "Show me first"]}]</parameter>
</invoke>
</function_calls>

<invoke name="Bash">
<parameter name="command">perl /Comserv/script/updateprompt.pl \
  --action "Asked user confirmation for fix" \
  --description "Analyzed issue in file and requested user input via ask_questions()" \
  --files "srcfile.ts" \
  --tools "Read, ask_questions" \
  --success 1</parameter>
</invoke>
</function_calls>

PATH A: Awaiting user response (script executed)
```

### Example 2: Work Complete (PATH B)
```
Applied the fix to src/file.ts. All tests pass. Edits logged.

<function_calls>
<invoke name="Bash">
<parameter name="command">perl /Comserv/script/updateprompt.pl \
  --action "Fix applied and tested" \
  --description "Applied fix to src/file.ts and verified all tests pass" \
  --files "src/file.ts" \
  --tools "Read, Edit, Bash" \
  --success 1</parameter>
</invoke>
</function_calls>

PATH B: Prompt complete (script executed)
```

### Example 3: Continuing Work (PATH C)
```
Created the first module. Now handling dependencies.

<function_calls>
<invoke name="Bash">
<parameter name="command">perl /Comserv/script/updateprompt.pl \
  --action "Created first module" \
  --description "Implemented Module1.pm with full ORM integration; preparing for dependency resolution" \
  --files "Module1.pm" \
  --tools "Write, Read" \
  --success 1</parameter>
</invoke>
</function_calls>

PATH C: Continuing to next task (script executed)
```

---

## WHY THIS IS MANDATORY

**Without /updateprompt execution statement**:
- 🔴 Agents don't indicate completion status
- 🔴 Users don't know if agent is waiting or done
- 🔴 Chat history becomes unclear
- 🔴 IDE locks in ambiguous states
- 🔴 Multiple agents violate workflow (Chat 36 problem)

**With /updateprompt execution statement**:
- ✅ Clear indication of prompt completion
- ✅ Explicit path (A/B/C) prevents ambiguity
- ✅ Session tracking works correctly
- ✅ User knows exactly what agent did
- ✅ No IDE lockups from unclear states

---

## AGENT CHECKLIST (Before Ending Prompt)

Before outputting `[/updateprompt executed]`:

- [ ] Have I finished the main work of this prompt?
- [ ] Do I need user input to continue? (PATH A)
- [ ] Is the work complete? (PATH B)
- [ ] Will I continue in next prompt? (PATH C)
- [ ] Have I stated which path clearly?

**If ALL checked**: Output `/updateprompt executed` statement

**If ANY unchecked**: Continue working before executing

---

## COMMON MISTAKES TO AVOID

❌ **WRONG**: Just text output (no script execution)
```
I've made the changes. Let me know if you need anything else.

[/updateprompt executed] → PATH B: Prompt complete
```
**Problem**: Script never runs. YAML file never updates. Chat locks.

✅ **CORRECT**: Execute Bash script with parameters
```
I've made the changes to the database models.

<function_calls>
<invoke name="Bash">
<parameter name="command">perl /Comserv/script/updateprompt.pl \
  --action "Database models updated" \
  --description "Fixed DocumentationIndex.pm and CodeSearchIndex.pm with proper DBIC relationships" \
  --files "Comserv/lib/Comserv/Model/Schema/Ency/Result/DocumentationIndex.pm, Comserv/lib/Comserv/Model/Schema/Ency/Result/CodeSearchIndex.pm" \
  --tools "Read, Edit, Bash" \
  --success 1</parameter>
</invoke>
</function_calls>

PATH B: Prompt complete (script executed, YAML updated)
```

---

❌ **WRONG**: Text question instead of ask_questions()
```
Ready to apply the fix?
[/updateprompt executed]
```

✅ **CORRECT**: Use ask_questions() function + execute script
```
<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{"question": "Ready to apply the fix?", "options": ["Yes", "No"]}]</parameter>
</invoke>
</function_calls>

<function_calls>
<invoke name="Bash">
<parameter name="command">perl /Comserv/script/updateprompt.pl \
  --action "Requested user approval for fix" \
  --description "Analyzed issue and requested user confirmation before applying" \
  --files "problem_file.pm" \
  --tools "Read, ask_questions" \
  --success 1</parameter>
</invoke>
</function_calls>

PATH A: Awaiting user response (script executed, awaiting input)
```

---

## RELATIONSHIP TO ask_questions()

**Timing Order**:
1. Do work
2. If user input needed → call `ask_questions()` function
3. Execute Bash script (with "success": 1 even though awaiting response)

**Both Are Required Together** - Script logs the ask_questions() call; user response drives next action

---

## MANDATORY FOR ALL AGENTS

This workflow applies to **every Zencoder agent**:
- ✅ MainAgent
- ✅ Cleanup Agent
- ✅ Docker Agent
- ✅ Documentation Agent
- ✅ Debug Agent
- ✅ Any future agents

No exceptions. No agent can opt out of this workflow.

---

## REMEMBER

> Every prompt must END by EXECUTING the updateprompt.pl script, not just outputting text.

**The script MUST run** - Not optional, not "executed" as text.

```bash
perl /Comserv/script/updateprompt.pl --action "..." --description "..." --files "..." --tools "..." --success 1
```

This is how you actually log your work to the session tracking system and prevent IDE lockups.

---

**Next**: Add this workflow requirement to all agent role specifications (cleanup-agent-role.md, docker-agent-role.md, etc.)
