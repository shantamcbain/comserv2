-- AI Chat Documentation Feature - Phase 1: Initial Data Fixtures
-- Created: 2025-12-16
-- Purpose: Insert default model configurations and access rules for AI chat feature

-- Insert default Ollama configuration for all users (Documentation Agent)
INSERT INTO ai_model_config (role, agent_type, model_name, enabled, api_endpoint, temperature, max_tokens, search_docs_automatically, allow_web_search, allow_code_search, priority)
VALUES 
    ('guest', 'documentation', 'ollama', 1, 'http://localhost:11434', 0.7, 2000, 1, 0, 0, 1),
    ('user', 'documentation', 'ollama', 1, 'http://localhost:11434', 0.7, 2000, 1, 0, 0, 1),
    ('developer', 'documentation', 'ollama', 1, 'http://localhost:11434', 0.7, 2000, 1, 1, 1, 1),
    ('admin', 'documentation', 'ollama', 1, 'http://localhost:11434', 0.7, 2000, 1, 1, 1, 1);

-- Insert XAI configuration for developers and admins (optional, requires API key)
INSERT INTO ai_model_config (role, agent_type, model_name, enabled, api_endpoint, temperature, max_tokens, search_docs_automatically, allow_web_search, allow_code_search, priority)
VALUES 
    ('developer', 'documentation', 'xai', 0, 'https://api.x.ai', 0.7, 4000, 1, 1, 1, 2),
    ('admin', 'documentation', 'xai', 0, 'https://api.x.ai', 0.7, 4000, 1, 1, 1, 2)
ON DUPLICATE KEY UPDATE priority = VALUES(priority);

-- Insert default documentation role access rules
-- Public sections accessible to all users
INSERT INTO documentation_role_access (role, doc_section_pattern, can_access)
VALUES 
    ('guest', 'public/*', 1),
    ('guest', 'tutorial/*', 1),
    ('user', 'public/*', 1),
    ('user', 'tutorial/*', 1),
    ('user', 'user_guide/*', 1),
    ('developer', 'public/*', 1),
    ('developer', 'tutorial/*', 1),
    ('developer', 'user_guide/*', 1),
    ('developer', 'api/*', 1),
    ('developer', 'developer/*', 1),
    ('admin', '*', 1)
ON DUPLICATE KEY UPDATE can_access = VALUES(can_access);

-- Deny patterns (explicit denials if needed)
INSERT INTO documentation_role_access (role, doc_section_pattern, can_access)
VALUES 
    ('guest', 'admin/*', 0),
    ('guest', 'developer/*', 0),
    ('guest', 'internal/*', 0),
    ('user', 'admin/*', 0),
    ('user', 'developer/*', 0),
    ('user', 'internal/*', 0),
    ('developer', 'admin/*', 0),
    ('developer', 'internal/*', 0)
ON DUPLICATE KEY UPDATE can_access = VALUES(can_access);
