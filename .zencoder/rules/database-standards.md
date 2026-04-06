---
description: Database Development Standards and Best Practices
globs: ["**/*.pm", "**/*.pl"]
alwaysApply: true
---

# Database Development Standards

## Query Standards
- **Table Aliases:** Use table aliases in all queries to avoid ambiguity (e.g., 'me.column_name')
- **Error Handling:** Implement proper error handling with eval blocks and try/catch
- **Parameterized Queries:** Use parameterized queries to prevent SQL injection

## Schema Management
- **Naming Conventions:** Follow naming conventions for tables, columns, and relationships
- **Documentation:** Document schema changes and rationale for future reference
- **Performance:** Regularly optimize database performance and indexes
- **Version Control:** Use Git to track schema changes with proper tagging
- **Backup Protocol:** Always backup database before making schema changes

## Model Standards (DBIx::Class)
- **Result Classes:** Located in `/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema/Ency/Result/`
- **Relationships:** Define proper relationships between tables
- **Validation:** Implement data validation in model classes

## Configuration Priority
- **Primary:** ZeroTier production server (172.30.161.222) - works from any network
- **Secondary:** Local network production server (192.168.1.198) - home/office only
- **Tertiary:** localhost MySQL (development)
- **Fallback:** SQLite (offline mode)

## Security Protocols
- **Input Validation:** Validate all user inputs before database operations
- **Access Controls:** Implement proper access controls based on user roles
- **Regular Reviews:** Regularly review and update security protocols