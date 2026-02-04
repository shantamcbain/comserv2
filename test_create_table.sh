#!/bin/bash

BASE_URL="http://localhost:4001"

echo "==========================================="
echo "Test: Create user_api_keys Table from Result"
echo "==========================================="
echo ""

echo "Calling /admin/create_table_from_result..."
curl -s "$BASE_URL/admin/create_table_from_result" \
  -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "result_class=user_api_keys&database=ency" | python3 -m json.tool

echo ""
echo "==========================================="
echo "Test Complete"
echo "==========================================="
