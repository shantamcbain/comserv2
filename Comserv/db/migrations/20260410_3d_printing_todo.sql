-- Migration: 20260410_3d_printing_todo.sql
-- Purpose: Create the 3D Printing project record and add blocking Todo for AIChatSystem
-- Author: Shanta / AI Assistant
-- Date: 2026-04-10

-- ============================================================
-- Ensure a 3D Printing project exists
-- (Insert only if not already present by project_code)
-- ============================================================
INSERT INTO projects (
    name, description, status, project_code, sitename,
    username_of_poster, group_of_poster, date_time_posted, sort_order
)
SELECT
    '3D Printing Module',
    'Add-on module for 3D printing services: model catalog, print farm, order queue, inventory integration, and AI/web search for 3D models.',
    'in_progress',
    '3D_PRINTING',
    'CSC',
    'system',
    'admin',
    NOW(),
    100
WHERE NOT EXISTS (
    SELECT 1 FROM projects WHERE project_code = '3D_PRINTING'
);

-- ============================================================
-- Add blocking Todo for AIChatSystem extension
-- Status: 1 = new/open
-- is_blocking = 1 so 3D Deeper Search waits on this
-- ============================================================
INSERT INTO todo (
    sitename, subject, description, status, priority,
    project_code, username_of_poster, group_of_poster,
    date_time_posted, last_mod_by, last_mod_date,
    share, is_blocking, blocked_by_todo_id, start_date, due_date
)
SELECT
    'CSC',
    'AIChatSystem: Add /ai/search_3d_models endpoint for 3D file web search',
    'The 3D Printing module has a "Deeper Search" feature that uses the AIChatSystem to search the internet for 3D model files when local results are insufficient.\n\nRequired: Add a new action to Controller/AI.pm:\n  sub search_3d_models :Path(''/ai/search_3d_models'') :Args(0)\n\nThis action should:\n1. Accept a query parameter "q" (search term)\n2. Use the configured AI provider (Ollama/Grok) to search the web or generate relevant 3D model file suggestions\n3. Return results as JSON with fields: name, description, source_url, file_type\n4. Results are displayed in 3d/browse.tt when feature_pending is false\n\nOnce implemented, update Controller/3d.pm search_deeper action to forward to /ai/search_3d_models.\n\nBranch: 3dprinting-use-this-as-the-branc-41f3\nBlocks: 3D Deeper Search feature in Controller/3d.pm::search_deeper',
    1,
    2,
    '3D_PRINTING',
    'system',
    'admin',
    NOW(),
    'system',
    CURDATE(),
    1,
    1,
    NULL,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 30 DAY)
WHERE NOT EXISTS (
    SELECT 1 FROM todo WHERE subject = 'AIChatSystem: Add /ai/search_3d_models endpoint for 3D file web search'
);
