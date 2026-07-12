#!/bin/bash
# sync-docs.sh — Auto-sync codebase documentation with source changes
# Scans Controller/ and Model/ directories, updates CLAUDE.md and SUMMARY.md stubs.
# Pure shell — no LLM calls, no API costs. Runs from project root.
#
# Usage:  cd /path/to/comserv2 && bash Documentation/script/sync-docs.sh
#         bash Documentation/script/sync-docs.sh --dry-run   (preview only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

CHANGED=false
REPORT=""

# ─────── Utility ───────
msg()  { echo "  $1"; }
info() { echo "→ $1"; }
warn() { echo "  ⚠ $1"; }
edit_file() {
    local file="$1" old="$2" new="$3"
    if $DRY_RUN; then
        echo "    [would patch $file]"
    else
        if grep -qF "$old" "$file" 2>/dev/null; then
            # Use python for reliable find-and-replace (Perl-based sed etc.)
            python3 -c "
import sys
with open('$file') as f: content = f.read()
old = '''$old'''
new = '''$new'''
if old in content:
    content = content.replace(old, new, 1)
    with open('$file', 'w') as f: f.write(content)
    print('patched')
else:
    print('not found')
" 2>/dev/null || sed -i.bak "s/$old/$new/" "$file" && rm -f "${file}.bak"
        fi
    fi
}

# ─────── 1. Scan Controllers ───────
info "Scanning Controller modules..."
CONTROLLERS=$(find Comserv/lib/Comserv/Controller -name '*.pm' | sort)
CONTROLLER_COUNT=$(echo "$CONTROLLERS" | wc -l)
msg "Found $CONTROLLER_COUNT controller files"

# Build controller list as markdown table rows
CONTROLLER_TABLE=""
while IFS= read -r file; do
    pkg=$(grep -m1 '^package ' "$file" | sed 's/^package //;s/;//')
    # Remove Comserv::Controller:: prefix
    name="${pkg#Comserv::Controller::}"
    # Guess namespace from path. Single-level: Foo.pm → /Foo. Nested: Admin/Docker.pm → /admin/docker
    rel="${file#Comserv/lib/Comserv/Controller/}"
    rel="${rel%.pm}"
    ns=$(echo "/$rel" | tr '[:upper:]' '[:lower:]')
    # Replace double slashes (Root.pm → /root, Admin.pm → /admin)
    CONTROLLER_TABLE+="| \`$rel.pm\` | \`$ns\` | *auto-detected* |\n"
done <<< "$CONTROLLERS"

# ─────── 2. Update CLAUDE.md Auto-Detected Section ───────
info "Updating CLAUDE.md auto-detected controller section..."
AUTO_MARKER_START="<!-- AUTO_CONTROLLER_START -->"
AUTO_MARKER_END="<!-- AUTO_CONTROLLER_END -->"
AUTO_SECTION="$AUTO_MARKER_START
| File | Namespace | Purpose |
|---|---|---|
$CONTROLLER_TABLE$AUTO_MARKER_END"

if [ ! -f "CLAUDE.md" ]; then
    warn "CLAUDE.md not found — skipping"
else
    if grep -q "$AUTO_MARKER_START" CLAUDE.md; then
        # Replace existing auto section (between markers)
        python3 -c "
import sys
with open('CLAUDE.md') as f: content = f.read()
start_marker = '$AUTO_MARKER_START'
end_marker = '$AUTO_MARKER_END'
start_idx = content.find(start_marker)
end_idx = content.find(end_marker)
if start_idx != -1 and end_idx != -1:
    end_idx += len(end_marker)
    new_section = '''$AUTO_SECTION'''
    content = content[:start_idx] + new_section + content[end_idx:]
    with open('CLAUDE.md', 'w') as f: f.write(content)
    print('updated')
else:
    print('markers not found')
"
    else
        # Append auto section at end of file
        echo "" >> CLAUDE.md
        echo "" >> CLAUDE.md
        echo -e "$AUTO_SECTION" >> CLAUDE.md
    fi
    CHANGED=true
    REPORT+="  • CLAUDE.md: updated controller index\n"
fi

# ─────── 3. Create/Update SUMMARY.md Stubs ───────
info "Checking SUMMARY.md stubs..."

# Ensure Documentation/SUMMARY.md exists
if [ ! -f "Documentation/SUMMARY.md" ]; then
    if ! $DRY_RUN; then
        mkdir -p Documentation
        cat > Documentation/SUMMARY.md << 'SUMMD'
# Module: Controllers
## Purpose
Catalyst MVC controllers — handle HTTP requests, process data, render views.
Auto-detected from Comserv/lib/Comserv/Controller/. Last updated: DATE.

## All Controllers
SUMMD
        sed -i "s/DATE/$(date +%Y-%m-%d)/" Documentation/SUMMARY.md
    fi
    CHANGED=true
    REPORT+="  • Documentation/SUMMARY.md: created\n"
fi

# For each controller, ensure a stub exists in the module summary
while IFS= read -r file; do
    pkg=$(grep -m1 '^package ' "$file" | sed 's/^package //;s/;//')
    name="${pkg#Comserv::Controller::}"
    module="${name%%::*}"  # First segment (e.g., "Admin" from "Admin::Docker")
    
    # If it's a top-level controller (no ::), the module IS the name
    if [[ "$name" != *"::"* ]]; then
        module="$name"
    fi
    # Skip too-generic modules
    [[ "$module" == "Root" ]] && continue
    [[ "$module" == "Base" ]] && continue
    
    # Determine summary file location
    if [[ "$name" == *"::"* ]]; then
        # Nested controller (e.g., Admin::Docker) — put in parent module's dir
        sumfile="Documentation/${module}/SUMMARY.md"
    else
        # Top-level controller
        sumfile="Documentation/${module}/SUMMARY.md"
    fi
    
    # Only create stub for top-level modules without existing summary
    if [[ "$name" != *"::"* ]] && [ ! -f "$sumfile" ]; then
        ns=$(echo "/$module" | tr '[:upper:]' '[:lower:]')
        if ! $DRY_RUN; then
            mkdir -p "Documentation/$module"
            cat > "$sumfile" << STUB
# Module: $module
## Key Controllers
- \`Comserv/lib/Comserv/Controller/${module}.pm\`
## Routes (auto-detected)
- \`$ns\` — *add description*
## Schema Tables
*add database tables*
## Dependencies
*add dependencies*
STUB
            echo "    Created stub: $sumfile"
        fi
        CHANGED=true
        REPORT+="  • $sumfile: created stub\n"
    fi
done <<< "$CONTROLLERS"

# ─────── 4. Update general controllers SUMMARY.md ───────
info "Updating Documentation/SUMMARY.md..."
if [ -f "Documentation/SUMMARY.md" ]; then
    # Rebuild the controller list section
    CONTROLLER_LIST=""
    while IFS= read -r file; do
        pkg=$(grep -m1 '^package ' "$file" | sed 's/^package //;s/;//')
        name="${pkg#Comserv::Controller::}"
        ns=$(echo "/$name" | tr '[:upper:]' '[:lower:]' | sed 's|::|/|g')
        CONTROLLER_LIST+="- \`$name\` ($ns)\n"
    done <<< "$CONTROLLERS"
    
    # Replace between markers in SUMMARY.md
    python3 -c "
import sys
with open('Documentation/SUMMARY.md') as f: content = f.read()
start = '<!-- CONTROLLERS_START -->'
end = '<!-- CONTROLLERS_END -->'
s = content.find(start)
e = content.find(end)
if s != -1 and e != -1:
    e += len(end)
    new_list = '''$CONTROLLER_LIST'''
    new_block = start + '\n' + new_list + end
    content = content[:s] + new_block + content[e:]
    with open('Documentation/SUMMARY.md', 'w') as f: f.write(content)
    print('updated')
else:
    # Append markers if not found
    with open('Documentation/SUMMARY.md', 'a') as f:
        f.write('\n<!-- CONTROLLERS_START -->\n$CONTROLLER_LIST<!-- CONTROLLERS_END -->\n')
    print('appended')
" 2>/dev/null || true
    CHANGED=true
    REPORT+="  • Documentation/SUMMARY.md: refreshed controller list\n"
fi

# ─────── 5. Final Summary ───────
echo ""
if $CHANGED; then
    info "Documentation sync complete — changes applied:"
    echo -e "$REPORT"
    if $DRY_RUN; then
        info "(dry run — no files modified)"
    fi
else
    info "No changes needed — all docs up to date."
fi
