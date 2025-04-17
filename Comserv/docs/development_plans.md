# Comserv Development Plans

This document serves as an index for all ongoing and planned development initiatives for the Comserv application.

## Current Initiatives

### 1. Controller Routing Standardization

**Status**: In Progress  
**Priority**: High  
**Lead**: Development Team  
**Documentation**: [Controller Routing Standardization](controller_routing_standardization.md)

**Description**:  
Standardizing controller routing across the application using Catalyst's chained actions for better organization, maintainability, and scalability.

**Progress**:
- ✅ MCoop controller updated as pilot implementation
- ⬜ Update high-traffic controllers (CSC, USBM, BMaster)
- ⬜ Update remaining controllers
- ⬜ Add automated tests to verify routing functionality

### 2. Theme Handling Improvements

**Status**: Planned  
**Priority**: Medium  
**Lead**: TBD  
**Documentation**: TBD

**Description**:  
Improving theme handling to ensure consistent theme application across the application, including updating theme_mappings.json to use consistent case for site names.

**Planned Tasks**:
- ⬜ Audit current theme handling across controllers
- ⬜ Update theme_mappings.json for consistent case
- ⬜ Centralize theme handling logic
- ⬜ Add theme validation and error handling

## Completed Initiatives

### 1. MCoop Controller Fix

**Status**: Completed  
**Priority**: High  
**Lead**: Development Team  
**Documentation**: [MCoop Controller Fix](mcoop_controller_fix.md)

**Description**:  
Fixed site name case handling and routing in the MCoop controller, implementing chained routing as a pilot for the Controller Routing Standardization initiative.

**Completed Tasks**:
- ✅ Fixed site name case handling
- ✅ Implemented chained routing
- ✅ Removed redundant SiteName setting
- ✅ Added backward compatibility methods
- ✅ Documented changes and standardization plan

## Planned Future Initiatives

### 1. API Standardization

**Status**: Planned  
**Priority**: Medium  
**Lead**: TBD  
**Documentation**: TBD

**Description**:  
Standardizing API endpoints and response formats across the application for better integration with frontend and third-party systems.

### 2. Performance Optimization

**Status**: Planned  
**Priority**: Medium  
**Lead**: TBD  
**Documentation**: TBD

**Description**:  
Identifying and addressing performance bottlenecks in the application, including database queries, template rendering, and API calls.

### 3. Security Enhancements

**Status**: Planned  
**Priority**: High  
**Lead**: TBD  
**Documentation**: TBD

**Description**:  
Enhancing security measures across the application, including input validation, authentication, authorization, and data protection.

## How to Contribute

If you would like to contribute to any of these initiatives or propose a new one, please follow these steps:

1. Review the existing documentation for the initiative
2. Discuss your ideas with the development team
3. Create a detailed proposal for your contribution
4. Submit a pull request with your changes

## Initiative Template

When proposing a new initiative, please use the following template:

```markdown
### Initiative Name

**Status**: [Planned/In Progress/Completed]  
**Priority**: [Low/Medium/High]  
**Lead**: [Name or Team]  
**Documentation**: [Link to Documentation]

**Description**:  
[Brief description of the initiative]

**Tasks**:
- ⬜ [Task 1]
- ⬜ [Task 2]
- ⬜ [Task 3]

**Success Criteria**:
- [Criterion 1]
- [Criterion 2]
- [Criterion 3]
```