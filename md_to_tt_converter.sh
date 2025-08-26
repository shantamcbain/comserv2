#!/bin/bash

# Function to convert markdown file to tt file
convert_md_to_tt() {
    md_file="$1"
    
    # Extract the filename without extension
    filename=$(basename "$md_file" .md)
    
    # Get the directory of the file
    dir=$(dirname "$md_file")
    
    # Define the output tt file path
    tt_file="${dir}/${filename}.tt"
    
    # Get the current date in YYYY/MM/DD format
    current_date=$(date +"%Y/%m/%d")
    
    # Extract title from the markdown file (first heading)
    title=$(grep -m 1 "^# " "$md_file" | sed 's/^# //')
    
    # If no title found, use the filename
    if [ -z "$title" ]; then
        title="$filename"
    fi
    
    # Create the TT file with proper header
    {
        echo "[% PageVersion = '${dir#/home/shanta/PycharmProjects/comserv2/}/${filename}.tt,v 0.01 $current_date shanta Exp shanta ' %]"
        echo "[% IF c.session.debug_mode == 1 %]"
        echo "    [% PageVersion %]"
        echo "[% END %]"
        echo ""
        echo "[% META title = '$title' %]"
        echo ""
        echo "<!-- Include documentation CSS -->"
        echo "<link rel=\"stylesheet\" href=\"/static/css/documentation.css\">"
        echo ""
        echo "<div class=\"markdown-content\">"
        
        # Get the content from markdown file, skip the title if it's a heading
        if grep -q "^# " "$md_file"; then
            # Skip the first heading when adding content
            tail -n +2 "$md_file" | sed -e 's/$/\n/'
        else
            # If no heading, include all content
            cat "$md_file" | sed -e 's/$/\n/'
        fi
        
        echo "</div>"
    } > "$tt_file"
    
    echo "Converted: $md_file -> $tt_file"
}

# Find all markdown files and convert them
find /home/shanta/PycharmProjects/comserv2 -name "*.md" | while read -r md_file; do
    # Skip files in hidden directories
    if [[ "$md_file" == *"/.codebuddy/"* ]]; then
        continue
    fi
    
    convert_md_to_tt "$md_file"
done

# After all conversions, list the original .md files to be removed
echo "Conversion complete. The following .md files can now be removed:"
find /home/shanta/PycharmProjects/comserv2 -name "*.md" | grep -v "/.codebuddy/" | sort