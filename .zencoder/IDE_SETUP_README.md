# IDE Setup for .zencoder Directory

**Purpose**: Ensure .zencoder directory and its contents are visible in both Zencoder (VSCode) and PyCharm environments.

**Last Updated**: 2026-01-23

---

## Changes Committed to Branch: new-task-1dbe

All .zencoder improvements have been committed to the `new-task-1dbe` branch:
- **ZencoderOpeningPrompt.tt** v0.30 - Literal Execution Standard  
- **coding-standards.yaml** - AI Limitation Mitigation section added
- **scripts/updateprompt.pl** - Sanitization detection implemented
- **scripts/init_prompt.sh** - Mandatory execution wrapper created

**Commit**: `b52936d8` - "Implement v3 Literal Execution Standard and AI Limitation Mitigation"

---

## Accessing Changes from Main PyCharm Project

### Option 1: Merge Branch (Recommended)
```bash
cd /home/shanta/PycharmProjects/comserv2
git fetch origin
git merge new-task-1dbe
```

### Option 2: Cherry-Pick Specific Commit
```bash
cd /home/shanta/PycharmProjects/comserv2
git cherry-pick b52936d8
```

### Option 3: Checkout Branch in Main Project
```bash
cd /home/shanta/PycharmProjects/comserv2
git checkout new-task-1dbe
```

---

## IDE Configuration

### For PyCharm

1. **Ensure .zencoder is Indexed**
   - Settings → Project → Project Structure
   - Mark `.zencoder` as Sources Root (or at minimum, not Excluded)

2. **Enable Version Control**
   - VCS → Enable Version Control Integration → Git
   - Verify `.idea/vcs.xml` exists (created automatically)

3. **File Watchers** (Optional - for auto-sync)
   - Settings → Tools → File Watchers
   - Add watcher for `.zencoder/**/*.yaml` files
   - Action: Trigger git commit reminder

### For VSCode/Zencoder

1. **Ensure .zencoder is Visible**
   - Check `settings.json` does NOT exclude `.zencoder`
   - Add to workspace settings if needed:
     ```json
     {
       "files.exclude": {
         ".zencoder": false
       },
       "search.exclude": {
         ".zencoder": false
       }
     }
     ```

2. **Git Integration**
   - Source Control panel should show `.zencoder` changes
   - If not, check `.gitignore` doesn't exclude it

---

## Verifying Both Environments See Changes

### From Worktree (Zencoder)
```bash
cd /home/shanta/.zenflow/worktrees/new-task-1dbe
git log --oneline -1  # Should show commit b52936d8
ls -la .zencoder/scripts/  # Should show init_prompt.sh
```

### From Main Project (PyCharm)
```bash
cd /home/shanta/PycharmProjects/comserv2
git branch -a | grep new-task-1dbe  # Should show branch exists
git show new-task-1dbe:.zencoder/scripts/init_prompt.sh  # Should show file content
```

After merge/cherry-pick:
```bash
ls -la .zencoder/scripts/init_prompt.sh  # File should exist on disk
```

---

## Keeping Both Environments in Sync

### Best Practice Workflow

1. **Make changes in worktree** (Zencoder environment)
2. **Commit to branch** (new-task-1dbe or feature branch)
3. **Merge to main** when ready
4. **Pull in main project** (PyCharm environment)

### Automatic Sync (Git Worktree Behavior)

- Both environments share the same `.git` directory
- Commits in worktree are immediately visible to main project via `git show`
- Files appear on disk only after checkout/merge
- No special configuration needed beyond standard Git workflow

---

## Troubleshooting

### Issue: PyCharm doesn't see .zencoder directory
**Solution**: Check if directory is marked as Excluded in Project Structure settings

### Issue: VSCode doesn't index .zencoder files  
**Solution**: Check `files.exclude` and `search.exclude` in settings.json

### Issue: Changes not visible between environments
**Solution**: Ensure both are tracking the same Git repository. Run `git remote -v` in both to verify.

### Issue: .zencoder scripts not executable
**Solution**: 
```bash
chmod +x .zencoder/scripts/*.sh
chmod +x .zencoder/scripts/*.pl
```

---

## References

- **Main Branch**: `main` (stable)
- **Development Branch**: `new-task-1dbe` (current improvements)
- **Worktree Location**: `/home/shanta/.zenflow/worktrees/new-task-1dbe/`
- **Main Project**: `/home/shanta/PycharmProjects/comserv2/`
