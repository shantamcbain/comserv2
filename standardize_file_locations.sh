#!/bin/bash

# Script to standardize file location information in .tt and .md files
# This script adds file path information to all .tt and .md files in the repository

REPO_ROOT="/home/shanta/PycharmProjects/comserv"
LOG_FILE="$REPO_ROOT/standardize_file_locations.log"

echo "Starting file location standardization at $(date)" > "$LOG_FILE"

# Function to standardize .tt files
standardize_tt_file() {
    local file="$1"
    local rel_path="${file#$REPO_ROOT/}"
    
    # Check if the file already has the file path comment
    if grep -q "<!-- File: $file" "$file"; then
        echo "File already standardized: $rel_path" >> "$LOG_FILE"
        return
    fi
    
    # Get the first line of the file
    local first_line=$(head -n 1 "$file")
    
    # If the first line is a META directive, insert after it
    if [[ "$first_line" == *"[% META"* ]]; then
        sed -i "1a <!-- File: $file -->" "$file"
        echo "Added file path after META directive: $rel_path" >> "$LOG_FILE"
    # If the first line starts with PageVersion, insert before it
    elif [[ "$first_line" == *"[% PageVersion"* ]]; then
        sed -i "1i <!-- File: $file -->" "$file"
        echo "Added file path before PageVersion: $rel_path" >> "$LOG_FILE"
    # Otherwise, insert at the beginning of the file
    else
        sed -i "1i <!-- File: $file -->" "$file"
        echo "Added file path at beginning: $rel_path" >> "$LOG_FILE"
    fi
}

# Function to standardize .md files
standardize_md_file() {
    local file="$1"
    local rel_path="${file#$REPO_ROOT/}"
    
    # Check if the file already has the file path metadata
    if grep -q "**File:** $file" "$file"; then
        echo "File already standardized: $rel_path" >> "$LOG_FILE"
        return
    fi
    
    # Get the first few lines to check for title and metadata
    local header=$(head -n 5 "$file")
    
    # If the file starts with a title and has metadata
    if [[ "$header" == "# "* ]] && [[ "$header" == *"**"* ]]; then
        # Find the line number of the first metadata line
        local first_metadata_line=$(grep -n "^\*\*.*\*\*" "$file" | head -n 1 | cut -d: -f1)
        
        if [[ -n "$first_metadata_line" ]]; then
            # Insert the file path metadata before the first existing metadata
            sed -i "${first_metadata_line}i **File:** $file  " "$file"
            echo "Added file path metadata before existing metadata: $rel_path" >> "$LOG_FILE"
        else
            # If no metadata found but has title, add after title
            sed -i "1a \n**File:** $file  " "$file"
            echo "Added file path metadata after title: $rel_path" >> "$LOG_FILE"
        fi
    # If the file starts with a title but has no metadata
    elif [[ "$header" == "# "* ]]; then
        sed -i "1a \n**File:** $file  " "$file"
        echo "Added file path metadata after title: $rel_path" >> "$LOG_FILE"
    # Otherwise, add title and metadata at the beginning
    else
        local filename=$(basename "$file")
        local title="${filename%.md}"
        title=$(echo "$title" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g') # Convert to title case
        
        sed -i "1i # $title\n\n**File:** $file  " "$file"
        echo "Added title and file path metadata at beginning: $rel_path" >> "$LOG_FILE"
    fi
}

# Find and standardize all .tt files
echo "Standardizing .tt files..." >> "$LOG_FILE"
find "$REPO_ROOT" -name "*.tt" -type f | while read -r file; do
    standardize_tt_file "$file"
done

# Find and standardize all .md files
echo "Standardizing .md files..." >> "$LOG_FILE"
find "$REPO_ROOT" -name "*.md" -type f | while read -r file; do
    standardize_md_file "$file"
done

echo "File location standardization completed at $(date)" >> "$LOG_FILE"
echo "See $LOG_FILE for details of the operation."

# Make the script executable
chmod +x "$0"

echo "Script completed. You can run this script again in the future to standardize new files."