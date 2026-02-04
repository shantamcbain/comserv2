#!/bin/bash

BASE_URL="http://localhost:4001"
PLAN_ID=1

echo "==================================="
echo "DailyPlan Entry CRUD Test Script"
echo "==================================="
echo ""
echo "Prerequisites:"
echo "1. Server must be running on port 4001"
echo "2. daily_plan_entries table must be created via schema_compare"
echo "3. DailyPlan record with id=$PLAN_ID must exist"
echo ""
echo "==================================="
echo ""

echo "Test 1: Create a new daily plan entry"
echo "-----------------------------------"
RESPONSE=$(curl -s -X POST "$BASE_URL/ai/planning/daily_plan/entry" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "plan_id=$PLAN_ID" \
  -d "entry_type=task" \
  -d "title=Test Task from API" \
  -d "description=This is a test task created via the API" \
  -d "status=pending")

echo "Response: $RESPONSE"
ENTRY_ID=$(echo $RESPONSE | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "Created Entry ID: $ENTRY_ID"
echo ""

if [ -z "$ENTRY_ID" ]; then
    echo "ERROR: Failed to create entry. Exiting."
    exit 1
fi

echo "Test 2: Get all entries for the plan"
echo "-----------------------------------"
curl -s "$BASE_URL/ai/planning/daily_plan/entries?plan_id=$PLAN_ID" | python3 -m json.tool
echo ""

echo "Test 3: Get daily plan with entries included"
echo "-----------------------------------"
curl -s "$BASE_URL/ai/planning/daily_plan?plan_id=$PLAN_ID&include_entries=1" | python3 -m json.tool
echo ""

echo "Test 4: Update the entry"
echo "-----------------------------------"
curl -s -X POST "$BASE_URL/ai/planning/daily_plan/entry/$ENTRY_ID" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "title=Updated Test Task" \
  -d "status=in_progress" \
  -d "description=Updated description" | python3 -m json.tool
echo ""

echo "Test 5: Create an AI-linked entry"
echo "-----------------------------------"
curl -s -X POST "$BASE_URL/ai/planning/daily_plan/entry" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "plan_id=$PLAN_ID" \
  -d "entry_type=ai_action" \
  -d "title=AI Generated Task" \
  -d "description=This task was created by AI" \
  -d "ai_conversation_id=1" \
  -d "status=pending" | python3 -m json.tool
echo ""

echo "Test 6: Delete the entry"
echo "-----------------------------------"
curl -s -X DELETE "$BASE_URL/ai/planning/daily_plan/entry/$ENTRY_ID" | python3 -m json.tool
echo ""

echo "Test 7: Verify deletion"
echo "-----------------------------------"
curl -s "$BASE_URL/ai/planning/daily_plan/entries?plan_id=$PLAN_ID" | python3 -m json.tool
echo ""

echo "==================================="
echo "Tests Complete!"
echo "==================================="
