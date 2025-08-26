#!/bin/bash

# This script fixes Template Toolkit files with unbalanced IF/END or FOREACH/END tags
echo "Fixing Template Toolkit files with unbalanced tags..."

# Find files with unbalanced IF/END tags
find /home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation -name "*.tt" -exec perl -ne 'BEGIN{$if=0;$end=0} $if++ if /\[% IF/; $end++ if /\[% END/; END{print "$ARGV\n" if $if != $end}' {} \; > /tmp/unbalanced_files.txt

# Process each file to add missing END tags
while read -r file; do
    echo "Processing $file..."
    
    # Count number of IF and END tags
    num_if=$(grep -c "\[% IF" "$file")
    num_end=$(grep -c "\[% END" "$file")
    
    # Calculate how many END tags we need to add
    to_add=$((num_if - num_end))
    
    if [ $to_add -gt 0 ]; then
        echo "  Adding $to_add END tags"
        
        # Create backup
        cp "$file" "${file}.bak"
        
        # Add the required number of END tags before the closing div
        if grep -q "</div>" "$file"; then
            # If file has a closing div, add END tags before it
            sed -i "s|</div>|$(printf '[%% END %%]\n' | head -n $to_add)</div>|" "$file"
        else
            # If no closing div, add END tags at the end of the file
            for ((i=1; i<=$to_add; i++)); do
                echo "[% END %]" >> "$file"
            done
        fi
    elif [ $to_add -lt 0 ]; then
        echo "  WARNING: More END tags than IF tags. Manual fix required."
    else
        echo "  Tags already balanced."
    fi
done < /tmp/unbalanced_files.txt

# Check for files with unbalanced FOREACH/END tags
find /home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation -name "*.tt" -exec perl -ne 'BEGIN{$foreach=0;$end=0} $foreach++ if /\[% FOREACH/; $end++ if /\[% END/; END{print "$ARGV\n" if $foreach != $end}' {} \; > /tmp/unbalanced_foreach_files.txt

# Process each file to add missing END tags for FOREACH
while read -r file; do
    echo "Processing FOREACH in $file..."
    
    # Count number of FOREACH and END tags
    num_foreach=$(grep -c "\[% FOREACH" "$file")
    num_end=$(grep -c "\[% END" "$file")
    
    # Calculate how many END tags we need to add
    to_add=$((num_foreach - num_end))
    
    if [ $to_add -gt 0 ]; then
        echo "  Adding $to_add END tags for FOREACH"
        
        # Create backup
        cp "$file" "${file}.bak"
        
        # Add the required number of END tags before the closing div
        if grep -q "</div>" "$file"; then
            # If file has a closing div, add END tags before it
            sed -i "s|</div>|$(printf '[%% END %%]\n' | head -n $to_add)</div>|" "$file"
        else
            # If no closing div, add END tags at the end of the file
            for ((i=1; i<=$to_add; i++)); do
                echo "[% END %]" >> "$file"
            done
        fi
    elif [ $to_add -lt 0 ]; then
        echo "  WARNING: More END tags than FOREACH tags. Manual fix required."
    else
        echo "  FOREACH tags already balanced with END tags."
    fi
done < /tmp/unbalanced_foreach_files.txt

echo "Done fixing Template Toolkit files."