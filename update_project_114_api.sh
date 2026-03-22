#!/bin/bash
# Update Project #114 (AI Chat Integration) via API
# Using workstation.local for proper SiteName access

echo "=== UPDATING PROJECT #114 VIA API ==="
echo ""

# Get current project data first
echo "Current project data:"
curl -s http://workstation.local:4001/api/projects | jq '.projects[] | select(.id == 114) | {id, name, status, sitename}'
echo ""
echo "---"
echo ""

# Update project with new data
# Note: update_project requires ALL fields, not just changed ones
echo "Sending update request..."
echo ""

curl -X POST "http://workstation.local:4001/project/update_project" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "project_id=114" \
  -d "sitename=CSC" \
  -d "name=AI Chat System Enhancement" \
  -d "description=Enhanced AI Chat system with multi-agent architecture, external API integration, and conversation management.

**Phase 1 - Foundation (Current)**
- Database setup (user_api_keys table migration)
- API key management with AES-256 encryption
- Conversation persistence and resume functionality
- Ollama 500 error fix (completed)

**Phase 2 - Agent System**
- Agent routing and configuration (.zencoder/coding-standards.yaml)
- Agent selection UI with role-based filtering
- @agent mention parsing
- Agent metadata tracking in database

**Phase 3 - Advanced Features**
- Agent handoff commands (Pass to [agent])
- Multi-provider support (X.AI/Grok, OpenAI, Claude)
- Enhanced model selection with provider grouping
- External API integration and testing

**Phase 4 - Integration & Polish**
- Security audit (API key exposure, SQL injection, XSS)
- Performance testing and optimization
- End-to-end integration testing
- Documentation updates

**Technical Stack:**
- Backend: Perl Catalyst (AI.pm 2932 lines, AIAdmin.pm 318 lines)
- Database: ai_conversations, ai_messages, ai_model_config, user_api_keys
- Frontend: Template Toolkit (ai/index.tt, manage_api_keys.tt)
- Models: Ollama (working), Grok (partial), OpenAI (planned), Claude (planned)

**Status Tracking:**
- Zenflow Branch: aichatsystem-ef4e (port 4001)
- Previous Work: ai-chat-system-8434 (fully integrated into main)
- Documentation: .zenflow/tasks/aichatsystem-ef4e/
- Planning: /admin/documentation/planning#anchor-aichat-system" \
  -d "start_date=2026-02-06" \
  -d "end_date=2026-02-28" \
  -d "status=In-Process" \
  -d "project_code=AIC-ENH" \
  -d "project_size=10" \
  -d "estimated_man_hours=160" \
  -d "developer_name=Shanta" \
  -d "client_name=internal" \
  -d "parent_id=63" \
  -d "comments=Zenflow: aichatsystem-ef4e (port 4001) | Branch Review: .zenflow/tasks/aichatsystem-ef4e/branch-review-findings.md | Database: user_api_keys migration required | Replaces: ai-chat-system-8434 branch work"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Update request sent successfully"
    echo ""
    echo "Fetching updated project data..."
    sleep 1
    curl -s http://workstation.local:4001/api/projects | jq '.projects[] | select(.id == 114) | {id, name, status, start_date, end_date, estimated_man_hours, project_code}'
    echo ""
    echo ""
    echo "View updated project at:"
    echo "  http://workstation.local:4001/project/details?project_id=114"
else
    echo ""
    echo "✗ Update request failed"
fi
