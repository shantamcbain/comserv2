#!/bin/bash

# This script properly converts markdown content in .tt files to HTML
# and fixes any PageVersion paths that contain ".md.tt"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Fixing TT Content Format ===${NC}"

# Set base directory
BASE_DIR="/home/shanta/PycharmProjects/comserv2"
DOC_DIR="$BASE_DIR/Comserv/root/Documentation"

# Function to fix a .tt file
fix_tt_file() {
    local tt_file="$1"
    local tmp_file="${tt_file}.tmp"
    local relative_path=${tt_file#$BASE_DIR/}
    
    echo -e "${BLUE}Processing: $tt_file${NC}"
    
    # Check if file has proper HTML content or still has markdown
    if grep -q "^#" "$tt_file" || grep -q "^\-\ " "$tt_file"; then
        echo -e "${RED}File contains markdown content, converting to HTML...${NC}"
        
        # Extract the PageVersion line
        local page_version=""
        if grep -q "PageVersion" "$tt_file"; then
            page_version=$(grep "PageVersion" "$tt_file" | head -1)
            # Fix .md.tt in PageVersion if present
            if [[ "$page_version" == *".md.tt"* ]]; then
                echo -e "${RED}Fixing PageVersion path (removing .md)...${NC}"
                page_version=$(echo "$page_version" | sed 's/\.md\.tt/.tt/')
            fi
        else
            # Create PageVersion if missing
            local current_date=$(date +"%Y/%m/%d")
            page_version="[% PageVersion = '${relative_path},v 0.01 $current_date shanta Exp shanta ' %]"
        fi
        
        # Extract META title
        local meta_title=""
        if grep -q "META title" "$tt_file"; then
            meta_title=$(grep "META title" "$tt_file" | head -1)
        else
            # Extract title from first heading
            local title=$(grep -m 1 "^# " "$tt_file" | sed 's/^# //')
            if [ -z "$title" ]; then
                title=$(basename "$tt_file" .tt | sed 's/_/ /g' | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
            fi
            meta_title="[% META title = '$title' %]"
        fi
        
        # Create temporary file with proper structure
        {
            # Add PageVersion
            echo "$page_version"
            echo "[% IF c.session.debug_mode == 1 %]"
            echo "    [% PageVersion %]"
            echo "[% END %]"
            echo ""
            
            # Add META title
            echo "$meta_title"
            echo ""
            
            # Add content container
            echo "<!-- Documentation page for $(basename "$tt_file" .tt) -->"
            echo "<div class=\"documentation-content\">"
            echo ""
            
            # Convert markdown to HTML using sed for basic formatting
            # This is a simplified conversion - for complex docs, use a proper markdown converter
            cat "$tt_file" | 
            # Skip TT directives and existing HTML
            grep -v "\[% PageVersion" | 
            grep -v "\[% IF c\.session\.debug_mode" | 
            grep -v "\[% META title" | 
            grep -v "\[% END %\]" |
            grep -v "<div class=\"documentation-content\">" |
            grep -v "</div>" |
            # Convert markdown headers
            sed 's/^# \(.*\)$/<h1>\1<\/h1>/' |
            sed 's/^## \(.*\)$/<h2>\1<\/h2>/' |
            sed 's/^### \(.*\)$/<h3>\1<\/h3>/' |
            sed 's/^#### \(.*\)$/<h4>\1<\/h4>/' |
            # Convert markdown bullets
            sed 's/^- \(.*\)$/<ul><li>\1<\/li><\/ul>/' |
            sed 's/^  - \(.*\)$/<ul><li style="margin-left: 20px">\1<\/li><\/ul>/' |
            # Convert numbered lists (simple cases)
            sed 's/^[0-9]\. \(.*\)$/<ol><li>\1<\/li><\/ol>/' |
            # Convert code blocks
            sed 's/`\([^`]*\)`/<code>\1<\/code>/g' |
            # Convert links
            sed 's/\[\([^]]*\)\](\([^)]*\))/<a href="\2">\1<\/a>/g'
            
            echo ""
            echo "</div>"
        } > "$tmp_file"
        
        # Replace the original file
        mv "$tmp_file" "$tt_file"
        echo -e "${GREEN}✓ Converted markdown to HTML${NC}"
    else
        # Fix PageVersion if it has .md.tt in it
        if grep -q "\.md\.tt" "$tt_file"; then
            echo -e "${RED}Fixing PageVersion path (removing .md)...${NC}"
            sed -i 's/\.md\.tt/.tt/g' "$tt_file"
            echo -e "${GREEN}✓ Fixed PageVersion path${NC}"
        else
            echo -e "${GREEN}✓ File already has proper HTML content${NC}"
        fi
    fi
}

# Find and fix all .tt files in the Documentation directory
echo -e "${BLUE}\nFixing .tt files...${NC}"
find "$DOC_DIR" -name "*.tt" | while read -r tt_file; do
    fix_tt_file "$tt_file"
done

echo -e "${GREEN}\n=== TT Content Fix Complete ===${NC}"
echo "All .tt files now have proper HTML content and correct PageVersion paths."
echo "Please check the files to ensure the conversion was successful."