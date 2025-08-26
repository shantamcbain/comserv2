#!/bin/bash

# This script fixes ALL documentation files to ensure they are in proper .tt format
# It will find any markdown files and convert them to .tt properly
# It will also find any malformed .tt files and fix them

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========== COMPREHENSIVE DOCUMENTATION FORMAT FIX ==========${NC}"
echo "This script will:"
echo "1. Find and convert all .md files to proper .tt format"
echo "2. Find and fix any malformed .tt files"
echo "3. Update any references to .md files in configuration"

# Set base directory
BASE_DIR="/home/shanta/PycharmProjects/comserv2"
DOC_DIR="$BASE_DIR/Comserv/root/Documentation"

# Function to properly convert a file to .tt format
convert_to_tt() {
    local source_file="$1"
    local tt_file="${source_file%.*}.tt"
    local filename=$(basename "$source_file")
    local base_filename="${filename%.*}"
    local relative_path=${source_file#$BASE_DIR/}
    
    echo -e "${GREEN}Converting: $source_file -> $tt_file${NC}"
    
    # Extract title from the first heading or use filename
    local title=$(grep -m 1 "^#+ " "$source_file" | sed 's/^#\+ //')
    if [ -z "$title" ]; then
        title=$(echo "$base_filename" | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
    fi
    
    # Get current date in YYYY/MM/DD format
    local current_date=$(date +"%Y/%m/%d")
    
    # Create proper .tt file
    {
        echo "[% PageVersion = '$relative_path.tt,v 0.01 $current_date shanta Exp shanta ' %]"
        echo "[% IF c.session.debug_mode == 1 %]"
        echo "    [% PageVersion %]"
        echo "[% END %]"
        echo ""
        echo "[% META title = '$title' %]"
        echo ""
        echo "<!-- Documentation page for $title -->"
        echo "<div class=\"documentation-content\">"
        echo ""
        
        # If the first line is a heading, don't include it (we use the META title)
        if grep -q "^#+ " "$source_file"; then
            tail -n +2 "$source_file"
        else
            cat "$source_file"
        fi
        
        echo ""
        echo "</div>"
    } > "$tt_file"
    
    echo -e "${GREEN}✓ Successfully converted to proper .tt format${NC}"
}

# Function to fix malformed .tt files
fix_tt_file() {
    local tt_file="$1"
    local tmp_file="${tt_file}.tmp"
    local relative_path=${tt_file#$BASE_DIR/}
    local filename=$(basename "$tt_file")
    local base_filename="${filename%.*}"
    
    echo -e "${BLUE}Checking .tt file: $tt_file${NC}"
    
    # Check if file has proper TT headers
    if ! grep -q "\[% PageVersion" "$tt_file"; then
        echo -e "${RED}Missing PageVersion directive, fixing...${NC}"
        
        # Extract title from META tag or from first h1/h2 or use filename
        local title=""
        if grep -q "\[% META title" "$tt_file"; then
            title=$(grep "\[% META title" "$tt_file" | sed -E 's/\[% META title = .([^"]+). %\]/\1/' | sed -E "s/\[% META title = '([^']+)' %\]/\1/")
        elif grep -q "<h1>" "$tt_file"; then
            title=$(grep -m 1 "<h1>" "$tt_file" | sed -E 's/<h1>([^<]+)<\/h1>/\1/')
        elif grep -q "<h2>" "$tt_file"; then
            title=$(grep -m 1 "<h2>" "$tt_file" | sed -E 's/<h2>([^<]+)<\/h2>/\1/')
        elif grep -q "^##* " "$tt_file"; then
            title=$(grep -m 1 "^##* " "$tt_file" | sed 's/^##* //')
        else
            title=$(echo "$base_filename" | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
        fi
        
        # Get current date in YYYY/MM/DD format
        local current_date=$(date +"%Y/%m/%d")
        
        # Create proper .tt content
        {
            echo "[% PageVersion = '$relative_path,v 0.01 $current_date shanta Exp shanta ' %]"
            echo "[% IF c.session.debug_mode == 1 %]"
            echo "    [% PageVersion %]"
            echo "[% END %]"
            echo ""
            echo "[% META title = '$title' %]"
            echo ""
            echo "<!-- Documentation page for $title -->"
            echo "<div class=\"documentation-content\">"
            echo ""
            
            # Add existing content, skip any existing META tags
            grep -v "\[% META title" "$tt_file" | grep -v "\[% PageVersion" | grep -v "\[% IF c\.session\.debug_mode" | grep -v "    \[% PageVersion %\]" | grep -v "\[% END %\]"
            
            # Add closing div if not present
            if ! grep -q "</div>" "$tt_file"; then
                echo ""
                echo "</div>"
            fi
        } > "$tmp_file"
        
        # Replace the original file
        mv "$tmp_file" "$tt_file"
        echo -e "${GREEN}✓ Fixed .tt file format${NC}"
    else
        echo -e "${GREEN}✓ File has proper TT format${NC}"
    fi
}

# Step 1: Find and convert all .md files
echo -e "${BLUE}\nFinding all .md files...${NC}"
find "$BASE_DIR" -name "*.md" -not -path "*/\.git/*" -not -path "*/\.codebuddy/*" | while read -r md_file; do
    convert_to_tt "$md_file"
done

# Step 2: Find and fix all .tt files in the Documentation directory
echo -e "${BLUE}\nChecking and fixing all .tt files...${NC}"
find "$DOC_DIR" -name "*.tt" | while read -r tt_file; do
    fix_tt_file "$tt_file"
done

# Step 3: Update all configuration files that may reference .md files
echo -e "${BLUE}\nUpdating configuration files...${NC}"

# Update documentation_config.json
CONFIG_FILE="$DOC_DIR/config/documentation_config.json"
if [ -f "$CONFIG_FILE" ]; then
    echo "Updating $CONFIG_FILE..."
    sed -i 's/\.md"/\.tt"/g' "$CONFIG_FILE"
    sed -i 's/"format": "markdown"/"format": "template"/g' "$CONFIG_FILE"
    echo -e "${GREEN}✓ Updated configuration file${NC}"
fi

echo -e "${BLUE}\nReminding user about files to remove...${NC}"
echo "The following .md files have been converted and can be removed:"
find "$BASE_DIR" -name "*.md" -not -path "*/\.git/*" -not -path "*/\.codebuddy/*" | sort

echo -e "${GREEN}\n========== DOCUMENTATION FORMAT FIX COMPLETE ==========${NC}"
echo "All documentation files have been converted to proper .tt format."
echo "Please check the converted files and remove the original .md files."