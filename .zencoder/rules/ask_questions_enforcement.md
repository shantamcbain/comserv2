---
description: "CRITICAL: All agents MUST use ask_questions() function for user input—text questions are forbidden and cause finish-up loops"
alwaysApply: true
---

# ask_questions() Enforcement - HIGH PRIORITY
**Version**: 1.0  
**Updated**: December 14, 2025  
**Enforcement Level**: 🔴 CRITICAL - Blocks chat continuation

⚠️ **READ THIS FIRST** - Before reading repo.md, keywords, or role specs, ALL agents MUST read and follow this file.

---

## THE RULE (Non-Negotiable)

**FOR USER INPUT DECISIONS: USE ask_questions() FUNCTION ONLY**

```
❌ WRONG: "Would you like me to apply the fix?"
❌ WRONG: "Should I proceed with the deployment?"
❌ WRONG: "Do you want me to..." (any text question)

✅ CORRECT: <invoke name="zencoder-server__ask_questions">
              <parameter name="questions">[{"question": "Your question?", "options": [...]}]</parameter>
            </invoke>
```

---

## WHY THIS RULE EXISTS

**Problem**: Text questions cause chat stalls:
1. Agent asks text question (e.g., "Would you like me to apply the fix?")
2. User expects to answer naturally
3. Chat enters "finishing up loop" (awaiting response that won't come)
4. User must manually terminate chat
5. **/updateprompt is never executed** → **Chat history is lost**
6. No record of violation in prompts_log.yaml

**Solution**: ask_questions() function is **designed to wait for structured response**:
- Function pauses agent execution (blocks continuation)
- Waits for user to select an option
- Returns structured answer to agent
- Agent can then proceed or ask follow-up questions
- Keeps chat alive and responsive

**Result**: No stalls. No lost history. Proper workflow continuation.

---

## SELF-DETECTION: If You Realize You Asked a Text Question

**If you (the agent) realize you just asked a text question**, follow this IMMEDIATE recovery:

### Step 1: RECOGNIZE THE VIOLATION
```
Agent text output contained: "Would you like me to..." OR "Should I..." OR any other question phrasing
```

### Step 2: EXECUTE /updateprompt IMMEDIATELY
Log the violation to prompts_log.yaml with:
- `problems: "SELF-DETECTED VIOLATION: Agent asked text question instead of using ask_questions() function"`
- `notes: "Recovering from violation - executing corrective workflow"`
- `success: false` (violation, but being corrected)

### Step 3: USE ask_questions() TO CONTINUE
**Right now**, call ask_questions() with your original question:
```xml
<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{"question": "[Your original question rephrased]", "options": ["Option 1", "Option 2", ...]}]</parameter>
</invoke>
</function_calls>
```

### Step 4: WAIT FOR USER RESPONSE
Do NOT continue work until user responds.

### Step 5: EXECUTE /updateprompt AGAIN
After user responds, log the recovery:
- `action: "recovered-from-text-question-violation"`
- `success: true` (violation detected and corrected)

---

## AGENT CHECKLIST (Before EVERY output)

Before sending any response, ask yourself:

- [ ] Am I asking the user a YES/NO question?
- [ ] Am I asking the user to choose between options?
- [ ] Am I asking for user input or approval?
- [ ] Is any of this phrased as a text question?

**If ANY checkbox is TRUE:**
- ❌ Do NOT output text questions
- ✅ Use ask_questions() function INSTEAD
- ✅ Include in your response ONLY the function call
- ✅ Add brief context before the function (max 2-3 sentences)

**Example**:
```
[/updateprompt executed] → Ready to apply the documentation fix. Requesting user confirmation:

<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{"question": "Apply the scanner path fix to ScanMethods.pm?", "options": ["Yes, apply now", "Show me the changes first", "Skip this step"]}]</parameter>
</invoke>
</function_calls>

(STOP HERE - WAIT FOR USER RESPONSE)
```

---

## IMPACT ON WORKFLOW PATHS

### PATH A: User Input Needed
```
/updateprompt → ask_questions() function → WAIT
```
- Chat pauses
- User responds
- Next prompt continues from user's answer
- ✅ **Prevents stalls**

### PATH B: Work Complete
```
/updateprompt → Do work → Log success: true → State "Prompt complete"
```
- No user input needed
- Work is done
- Chat continues to next topic
- ✅ **No stalls**

### PATH C: Loop Back
```
/updateprompt → Do work → ask_questions() (PATH A) or done (PATH B)
```
- Multiple prompts in same chat
- Each prompt has its own /updateprompt entry
- ✅ **Full history preserved**

### ❌ BROKEN PATH: Text Questions
```
/updateprompt missing → Ask text question → Chat hangs
```
- No blocking gate
- Agent not pausing properly
- User can't answer naturally
- Chat enters "finishing up loop"
- Manual termination required
- ❌ **History lost**

---

## REMEMBER

**Every time you might ask the user something**, think:

> "Is this a question the user needs to answer?"  
> **YES** → Use `ask_questions()` function  
> **NO** → Continue with your work

You are REQUIRED to use ask_questions(). This is not optional. It is the ONLY way to ask user questions. Text questions are not permitted.

This rule exists to protect your chats from stalling and losing history.

---

**Next**: Read `/.zencoder/rules/repo.md` for full blocking gate enforcement and startup protocol.
