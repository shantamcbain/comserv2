#!/bin/bash
# Update AI Chat Project via Web Form
# This script shows how to update project 133 with new agent-based architecture details

echo "=== UPDATE AI CHAT PROJECT ==="
echo ""
echo "Project ID: 133"
echo "Project Name: Chat with AI (Agent-Based Architecture)"
echo ""
echo "Visit the edit page:"
echo "  http://localhost:4001/project/editproject?project_id=133"
echo ""
echo "Or update via web form POST to:"
echo "  http://localhost:4001/project/update_project"
echo ""
echo "Suggested Updates:"
echo "==================="
echo ""
echo "Name: AI Chat System with Agent Architecture"
echo ""
echo "Description:"
cat << 'DESC'
Enhanced AI Chat system with multi-agent architecture, external API integration, and conversation management.

**Key Features:**
- Agent-based routing (Ency, HelpDesk, Docker, Database agents)
- Multi-provider support (Ollama, X.AI/Grok, OpenAI, Claude)
- Conversation persistence and resume functionality
- User-specific API key management with AES-256 encryption
- Role-based access control for models and agents
- Agent handoff capabilities for complex workflows

**Implementation Status:**
- Phase 1: Foundation (Current - Database setup, API keys)
- Phase 2: Agent System (Agent routing, configuration)
- Phase 3: Advanced Features (External providers, handoff)
- Phase 4: Integration & Polish (Security, testing, docs)

**Technical Stack:**
- Backend: Perl Catalyst (AI.pm, AIAdmin.pm)
- Database: ai_conversations, ai_messages, ai_model_config, user_api_keys
- Frontend: Template Toolkit (ai/index.tt, manage_api_keys.tt)
- Models: Ollama, Grok, OpenAI (planned), Claude (planned)

**Branch:** aichatsystem-ef4e (Zenflow port 4001)
**Documentation:** .zenflow/tasks/aichatsystem-ef4e/
DESC
echo ""
echo "Status: In-Process"
echo "Project Code: AIC-133"
echo "Estimated Man Hours: 160 (updated from 100)"
echo "Start Date: 2026-02-06"
echo "End Date: 2026-02-28"
echo ""
