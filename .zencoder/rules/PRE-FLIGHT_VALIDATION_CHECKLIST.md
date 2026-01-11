# PRE-FLIGHT VALIDATION CHECKLIST - MANDATORY FOR ALL AGENTS

**Version**: 1.0  
**Updated**: December 22, 2025  
**Enforcement Level**: 🔴 CRITICAL - Session blocks until completed  
**Purpose**: Ensure all agents understand and commit to compliance rules before starting work

---

## ⚠️ CRITICAL INSTRUCTION

**ALL agents MUST complete this checklist at session start.**

This is NOT optional. Failure to complete this checklist blocks chat continuation.

---

## PART 1: REQUIRED FILE READING (Complete in Order)

Before proceeding with ANY work, you MUST read these sections:

- [ ] **Read 1st**: `coding-standards.yaml` Rule 1 - Understand ask_questions() enforcement
- [ ] **Read 2nd**: `coding-standards.yaml` Rule 5 - Understand global keywords (/chathandoff, /newsession, /validatett)
- [ ] **Read 3rd**: `coding-standards.yaml` Rule 2 - Understand /updateprompt workflow gate and keyword execution
- [ ] **Read 4th**: `coding-standards.yaml` Rule 2 - Understand workflow gate execution patterns
- [ ] **Read 5th**: `coding-standards.yaml` metadata section - Understand consolidated source of truth
- [ ] **Read 6th**: Agent-specific section in `coding-standards.yaml` (e.g., `agents:cleanup`)

**If ANY section is unread**: STOP and read it before proceeding.

---

## PART 2: VIOLATION ACKNOWLEDGMENTS (Confirm You Won't Violate These)

### EditFile Compliance Acknowledgment

**Do you understand and commit to this rule?**

> ✅ I WILL use EditFile tool for ALL file creation and modification  
> ✅ I WILL NOT use `sed`, `cat >`, `echo >>`, or any bash file operations  
> ✅ I WILL verify every file operation by reading it back with `cat`  
> ✅ I WILL NOT claim file operations succeeded without proof

**Your acknowledgment**: [ ] I understand and will comply

---

### ask_questions() Compliance Acknowledgment

**Do you understand and commit to this rule?**

> ✅ I WILL use `ask_questions()` function for ALL user input needs  
> ✅ I WILL NOT ask text questions like "Would you like me to...?"  
> ✅ I WILL NOT create implied questions that cause chat to hang  
> ✅ I WILL include context (1-2 sentences) before asking_questions()  
> ✅ I WILL WAIT for user response after calling ask_questions()

**Your acknowledgment**: [ ] I understand and will comply

---

### /updateprompt Execution Acknowledgment

**Do you understand and commit to this rule?**

> ✅ I WILL execute `/updateprompt` workflow at end of every prompt  
> ✅ I WILL include execution path (A/B/C) with every /updateprompt  
> ✅ I WILL NOT end prompts without /updateprompt statement  
> ✅ I WILL NOT leave chat in ambiguous state (waiting/complete)  
> ✅ I understand PATH A = awaiting user input, PATH B = complete, PATH C = continuing

**Your acknowledgment**: [ ] I understand and will comply

---

## PART 3: VIOLATION RECOGNITION (Can You Spot These?)

**Your ability to recognize violations is critical.** Test yourself:

### Question 1: Is This a Violation?
```
Agent output: "I've updated the config file. Let me know when you're ready."
```
- [ ] Yes, violation (ambiguous state - implicit waiting)
- [ ] No, this is fine

**Correct answer**: YES - This creates ambiguous state. Should be explicit (PATH A with ask_questions() or PATH B "Prompt complete")

---

### Question 2: Is This a Violation?
```bash
sed -i 's/old/new/g' /path/to/file.pm
# No verification
```
- [ ] Yes, violation (bash file operation without EditFile or verification)
- [ ] No, this is fine

**Correct answer**: YES - This violates EditFile rule AND verification rule. Must use EditFile + cat to verify.

---

### Question 3: Is This a Violation?
```
Agent output: "Should I apply the fix?"
```
- [ ] Yes, violation (text question instead of ask_questions())
- [ ] No, this is fine

**Correct answer**: YES - This is a text question. Must use ask_questions() function instead.

---

### Question 4: Is This Correct?
```xml
<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{"question": "Apply the fix?", "options": ["Yes", "No"]}]</parameter>
</invoke>
</function_calls>

(WAIT FOR RESPONSE)
```
- [ ] Yes, this is correct
- [ ] No, this is wrong

**Correct answer**: YES - This uses ask_questions() correctly, pauses for response.

---

### Question 5: Is This a Violation?
```
Agent applies EditFile changes but does NOT read back to verify
Agent states: "File created successfully"
```
- [ ] Yes, violation (claims success without verification)
- [ ] No, this is fine

**Correct answer**: YES - Must verify with `cat /path` to confirm content matches intent.

---

## PART 4: SELF-ASSESSMENT

Be honest with yourself. Answer these questions:

- [ ] Have I used `sed`, `cat >`, or bash file operations in past chats? (If yes: STOP and read EditFile rule again)
- [ ] Have I asked text questions like "Would you...?" in past chats? (If yes: STOP and read ask_questions_enforcement.md again)
- [ ] Have I ended prompts without /updateprompt statement? (If yes: STOP and read updateprompt-workflow.md again)
- [ ] Have I verified my file operations by reading them back? (If no: STOP and commit to this practice)
- [ ] Do I understand PATH A/B/C execution states? (If no: STOP and reread updateprompt-workflow.md)

---

## FINAL CONFIRMATION

**I acknowledge and commit to the following:**

- [ ] I have read all 6 required files in order
- [ ] I understand EditFile is REQUIRED (not optional)
- [ ] I understand ask_questions() is REQUIRED (text questions forbidden)
- [ ] I understand /updateprompt execution is REQUIRED (every prompt)
- [ ] I can recognize the 5 common violations
- [ ] I scored well on the violation recognition questions
- [ ] I am honest about my past compliance issues (if any)
- [ ] I COMMIT to 100% compliance going forward

**By checking all boxes above, I confirm I am ready to work in full compliance with .zencoder/rules/ specifications.**

---

## What Happens If You Don't Complete This Checklist

❌ You CANNOT proceed with work  
❌ Every prompt will ask if you've completed this checklist  
❌ You will be blocked until checkboxes are marked  
❌ This is not a suggestion - it is a requirement  

---

## After Completing This Checklist

✅ You are cleared to work  
✅ You have committed to compliance  
✅ You understand all violations  
✅ You can now begin your task  

**Remember**: This checklist is binding. You've committed to compliance.

---

## Violation Response Protocol

**If you (the agent) violate any rule AFTER completing this checklist**:

1. **STOP IMMEDIATELY** - Do not continue working
2. **Execute /updateprompt with violation noted**:
   - action: "VIOLATION-DETECTED"
   - problems: "Used [violation type] instead of [correct method]"
   - success: false
3. **CORRECT the violation**:
   - Use EditFile (not bash)
   - Use ask_questions() (not text questions)
   - Execute /updateprompt (not omit it)
4. **LOG the recovery**:
   - action: "VIOLATION-CORRECTED"
   - success: true

**Repeated violations** (3+ times) will escalate to human review.

---

**Created**: December 22, 2025  
**Last Updated**: December 22, 2025  
**Applies To**: ALL agents in Comserv project  
**Status**: Active enforcement

