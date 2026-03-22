#!/bin/bash
# sync_to_main.sh - Sync .zencoder changes from worktree to main project
# Usage: Run from worktree when you want to make changes available to main PyCharm project

set -e

WORKTREE_DIR="/home/shanta/.zenflow/worktrees/new-task-1dbe"
MAIN_PROJECT="/home/shanta/PycharmProjects/comserv2"

echo "═══════════════════════════════════════════"
echo "Syncing .zencoder changes to main project"
echo "═══════════════════════════════════════════"
echo ""

# Check we're in worktree
if [ ! -d "$WORKTREE_DIR/.git" ]; then
    echo "❌ ERROR: Must run from worktree directory"
    exit 1
fi

# Check for uncommitted changes
cd "$WORKTREE_DIR"
if ! git diff-index --quiet HEAD -- .zencoder/ 2>/dev/null; then
    echo "⚠️  You have uncommitted changes in .zencoder/"
    echo "   Commit them first? (y/n)"
    read -r answer
    if [ "$answer" = "y" ]; then
        git add .zencoder/
        echo "Enter commit message:"
        read -r commit_msg
        git commit -m "$commit_msg"
        echo "✅ Changes committed"
    else
        echo "❌ Aborting - commit changes first"
        exit 1
    fi
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"
echo ""

# Merge to main
cd "$MAIN_PROJECT"

echo "Checking out main branch..."
git checkout main

echo "Merging $CURRENT_BRANCH into main..."
git merge "$CURRENT_BRANCH" --no-edit || {
    echo "❌ Merge conflict detected"
    echo "   Resolve conflicts manually and run: git merge --continue"
    exit 1
}

echo ""
echo "✅ Changes synced successfully"
echo ""
echo "Verifying .zencoder files in main project:"
ls -la .zencoder/scripts/ | grep -E '(init_prompt.sh|updateprompt.pl|validation_step0.pl)'
echo ""
echo "Main project now has access to all .zencoder improvements"
