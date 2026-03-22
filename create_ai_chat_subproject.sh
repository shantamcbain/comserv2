#!/bin/bash
# Create New Sub-Project under AI Chat Integration (114)
# Via web form at /project/addproject

echo "=== CREATE NEW AI CHAT SUB-PROJECT ==="
echo ""
echo "Visit the add project page with parent:"
echo "  http://localhost:4001/project/addproject?parent_id=114"
echo ""
echo "Or use curl to POST directly:"
echo ""

cat << 'EOF'
curl -X POST http://localhost:4001/project/create_project \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=AI Chat System Enhancement & Agent Architecture" \
  -d "description=Enhanced AI Chat system with multi-agent architecture, external API integration, and conversation management. Implements specialized agents (Ency, HelpDesk, Docker, Database) with intelligent routing, multi-provider support (Ollama, X.AI, OpenAI, Claude), conversation persistence, and secure API key management." \
  -d "project_code=AIC-ENHANCE" \
  -d "status=In-Process" \
  -d "start_date=2026-02-06" \
  -d "end_date=2026-02-28" \
  -d "estimated_man_hours=160" \
  -d "project_size=10" \
  -d "developer_name=Shanta" \
  -d "client_name=internal" \
  -d "parent_id=114" \
  -d "comments=Zenflow branch: aichatsystem-ef4e (port 4001). Consolidates previous ai-chat-system-8434 work with new agent-based architecture. Documentation: .zenflow/tasks/aichatsystem-ef4e/"
EOF

echo ""
echo ""
echo "This will create a new sub-project under 'AI Chat Integration' (114)"
echo "that specifically focuses on the agent architecture enhancement."
echo ""
