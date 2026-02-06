#!/bin/bash
echo "=== OPENING PROJECT PAGES IN BROWSER ==="
echo ""
echo "Opening the following pages:"
echo ""
echo "1. Current Project (Chat with AI - ID 133)"
xdg-open "http://localhost:4001/project/details?project_id=133" 2>/dev/null &
sleep 1
echo "   ✓ Details: http://localhost:4001/project/details?project_id=133"
echo ""
echo "2. Edit Project Form (to update project 133)"
xdg-open "http://localhost:4001/project/editproject?project_id=133" 2>/dev/null &
sleep 1
echo "   ✓ Edit: http://localhost:4001/project/editproject?project_id=133"
echo ""
echo "3. All Projects List"
xdg-open "http://localhost:4001/project/project" 2>/dev/null &
sleep 1
echo "   ✓ List: http://localhost:4001/project/project"
echo ""
echo "4. Create Sub-Project Form (under AI Chat Integration - ID 114)"
xdg-open "http://localhost:4001/project/addproject?parent_id=114" 2>/dev/null &
sleep 1
echo "   ✓ Add: http://localhost:4001/project/addproject?parent_id=114"
echo ""
echo "5. Planning Page with AI Chat System section"
xdg-open "http://localhost:4001/admin/documentation/planning#anchor-aichat-system" 2>/dev/null &
echo "   ✓ Planning: http://localhost:4001/admin/documentation/planning#anchor-aichat-system"
echo ""
echo "Pages should now be open in your browser!"
