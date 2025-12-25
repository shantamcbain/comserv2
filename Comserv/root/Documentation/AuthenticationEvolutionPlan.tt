# Comserv Authentication Evolution Plan

**File:** `/Comserv/root/Documentation/authentication_evolution_plan.md`  
**Version:** 1.0  
**Last Updated:** January 2025  
**Status:** ACTIVE - DO NOT CHANGE WITHOUT EXPLICIT PERMISSION

## Overview

This document defines the authentication evolution strategy for Comserv to maintain session-to-session consistency and prevent AI from constantly reinventing the authentication approach.

## Current State

**Problem:** Authentication broke in menu system branch due to AI introducing Catalyst authentication framework while templates expect simple session-based auth.

**Root Cause:** Templates (.tt files) are the application documentation and expect:
- `c.session.username`
- `c.session.roles` 
- Simple session checks

Current code implements complex Catalyst framework with DBEncy model that templates don't support.

## Evolution Phases

### Phase 1: Menu System Branch (CURRENT)
**Goal:** Fix authentication to continue menu development  
**Approach:** Hybrid compatibility layer  
**Implementation:**
- Keep Catalyst authentication framework in controller
- Populate session variables for template compatibility
- Document as "transition architecture"

**Code Pattern:**
```perl
# In User.pm controller after successful $c->authenticate()
$c->session->{username} = $user->username;
$c->session->{user_id}  = $user->id;
$c->session->{roles}    = $user->roles; # properly formatted array
```

**Files to modify:** `Comserv/lib/Comserv/Controller/User.pm` only  
**Templates:** NO CHANGES - continue using session variables

### Phase 2: Security Branch (FUTURE)
**Goal:** Complete modern authentication system  
**Approach:** Full Catalyst auth with template migration  
**Scope:** New branch dedicated to authentication improvements

## Implementation Rules

### For AI Sessions:
1. **READ THIS DOCUMENT FIRST** before making any authentication changes
2. **Phase 1 ONLY** - implement compatibility layer, DO NOT change templates
3. **NO DBEncy references** - use existing working database models
4. **ASK PERMISSION** before changing authentication approach
5. **UPDATE THIS DOCUMENT** when making approved changes

### For Developers:
1. Authentication approach is documented here
2. Changes require updating this document
3. Templates are documentation - changing them requires Phase 2 branch

## Current Implementation Requirements

### Controller Must:
- Use existing database models (not DBEncy)
- Populate session variables after authentication
- Maintain backward compatibility with templates
- Handle login/logout/register endpoints

### Templates Expect:
- `c.session.username` for user identification
- `c.session.roles` as array for role checking
- Standard session-based patterns

### Database:
- Use existing user table structure
- No DBEncy model references
- Standard password hashing

## Success Criteria Phase 1

- [ ] Login works with username/password
- [ ] Session variables populated correctly  
- [ ] Templates display user info properly
- [ ] Role-based access works
- [ ] Logout clears session appropriately
- [ ] Menu system development can continue

## Evolution Guidelines Updates

Add to `/Comserv/root/Documentation/AI_DEVELOPMENT_GUIDELINES.md`:

```markdown
## Authentication System

Authentication approach is defined in `authentication_evolution_plan.md`.
- Current phase: Phase 1 (compatibility layer)
- DO NOT change authentication approach without reading the plan
- DO NOT modify templates for authentication in current phase
- ASK PERMISSION before changing documented authentication strategy
```

## Change Log

- 2025-01-XX: Initial plan created to address session consistency issues
- [Future changes go here]

---

**IMPORTANT:** This document exists to prevent AI from constantly changing authentication approaches. Any changes to authentication strategy must update this document and get explicit approval.