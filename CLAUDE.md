# Claude Code Instructions for Proxmox Sleep Manager

This file contains instructions for Claude Code when working on this project. Claude should read and follow these guidelines for all development tasks.

## Project Overview

Proxmox Sleep Manager is a power management solution for Proxmox hosts running Windows VMs with GPU passthrough. It uses Windows hibernation to safely preserve VM state during host sleep cycles.

**Key Documentation**:
- [docs/DESIGN.md](docs/DESIGN.md) - Architecture, components, data flow
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) - Development workflows and conventions
- [RELEASING.md](RELEASING.md) - Release and packaging process

## Critical Rules

### Git Commit Rules

**NEVER amend commits** unless ALL of the following are true:
1. You are ONLY changing the commit message (no file changes)
2. The commit has NOT been pushed to remote
3. You created the commit in this conversation session

**Why**: Amending commits with file changes causes merge conflicts when branches are shared or rebased. This is a strict project policy.

**What to do instead**:
- Forgot a file? Create a new commit
- Need to fix the previous commit? Create a fixup commit
- Pre-commit hook modified files? Create a new commit with those changes

### Code Style

- All shell scripts must pass `shellcheck`
- Quote all variables: `"$variable"`
- Use `set -euo pipefail` for strict error handling
- Use the `log()` function for all output, not echo
- Follow existing code patterns in the project

## Pull Request Review Workflow

When reviewing PRs or after making changes to a PR, follow this workflow:

### 1. Trigger Copilot Review

After any changes are pushed to a PR, GitHub Copilot should run automatically. If needed, request a review:
```bash
gh pr edit --add-reviewer @copilot
```

### 2. Gather All Copilot Comments

```bash
# Get PR number
PR_NUM=$(gh pr view --json number -q '.number')

# Get owner and repo
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Fetch all review comments
gh api "repos/${REPO}/pulls/${PR_NUM}/comments" --paginate
```

### 3. Evaluate and Prioritize Comments

For each Copilot comment, assign a priority:

| Priority | Criteria | Action |
|----------|----------|--------|
| **P0 - Critical** | Security issues, data loss, crashes | Must fix |
| **P1 - High** | Bugs, incorrect behavior | Should fix |
| **P2 - Medium** | Code quality, maintainability | Consider |
| **P3 - Low** | Style, minor improvements | Optional |
| **No Action** | False positive, N/A | Justify |

### 4. Create Summary and Track Comments

Create a summary table and use a TODO list to track each comment:

```markdown
## Copilot Review Summary

| Comment ID | Issue | Priority | Decision | Status |
|------------|-------|----------|----------|--------|
| 12345678 | "Null reference risk" | P1 | Fix | Pending |
| 12345679 | "Consider using const" | P3 | No fix: already immutable | Done |
```

**IMPORTANT**: Store comment IDs in TODO items. This ensures you don't lose track of which fix corresponds to which comment.

### 5. Process Each Comment

For each comment (tracked by ID):

1. **Analyze** the suggestion
2. **Decide**: fix or justify not fixing
3. **If fixing**: implement the change and commit
4. **Reply** to the comment thread with your decision
5. **Mark complete** in TODO list

#### Reply to Comments

**When implementing a fix**:
```bash
COMMENT_ID=12345678
gh api "repos/${REPO}/pulls/comments/${COMMENT_ID}/replies" \
  -f body="Fixed in commit \`abc1234\`. Added null check as suggested."
```

**When not fixing (with justification)**:
```bash
COMMENT_ID=12345679
gh api "repos/${REPO}/pulls/comments/${COMMENT_ID}/replies" \
  -f body="No fix needed: This variable is guaranteed non-null because the \`validate_config()\` function on line 42 validates all inputs before this code path is reached."
```

### 6. Push Fixes and Verify

After processing all comments:
```bash
# Push any fixes
git push

# Verify all comments have replies
gh api "repos/${REPO}/pulls/${PR_NUM}/comments" --paginate | jq '.[].id'
```

### Complete PR Review Example

```
# Claude's workflow for PR #42:

1. Fetch comments:
   gh api repos/user/proxmox-sleep/pulls/42/comments

2. Found 3 comments, creating TODO list:
   - [ ] #11111: "Unhandled error" - P1
   - [ ] #22222: "Missing validation" - P2
   - [ ] #33333: "Variable naming" - P3

3. Processing #11111 (P1 - must fix):
   - Analyzing: Valid concern, error not caught
   - Implementing fix in proxmox-sleep-manager.sh:147
   - Committing: "fix: add error handling for guest agent timeout"
   - Replying to comment
   - [x] #11111: Fixed

4. Processing #22222 (P2 - should fix):
   - Analyzing: Validation already exists upstream
   - Decision: No fix needed
   - Replying with justification
   - [x] #22222: Justified

5. Processing #33333 (P3 - optional):
   - Analyzing: Suggestion is stylistic
   - Decision: No fix, follows project convention
   - Replying with justification
   - [x] #33333: Justified

6. Pushing fixes:
   git push

7. Summary report to user:
   - 1 fix implemented
   - 2 comments justified (no fix needed)
   - All comments have replies
```

## Common Development Tasks

### Adding a New Idle Check

1. Add check function in `proxmox-idle-monitor.sh`:
   ```bash
   check_new_activity() {
       # Return 0 if idle, 1 if active
   }
   ```

2. Call from `is_system_idle()` function

3. Add configuration variable if needed

4. Update documentation

### Modifying Sleep/Wake Behavior

1. Changes go in `proxmox-sleep-manager.sh`
2. Test with `DEBUG=1` to see detailed logs
3. Test the full cycle: hibernate → sleep → wake → resume

### Testing Changes

```bash
# Syntax check
bash -n proxmox-sleep-manager.sh

# Shellcheck
shellcheck -x *.sh

# Test single idle check
./proxmox-idle-monitor.sh check

# Test status display
./proxmox-idle-monitor.sh status
```

## File Locations

| File | Purpose |
|------|---------|
| `proxmox-sleep-manager.sh` | Sleep/wake orchestration |
| `proxmox-idle-monitor.sh` | Idle detection daemon |
| `proxmox-sleep.conf.example` | Configuration template |
| `install.sh` | Interactive installer |
| `uninstall.sh` | Cleanup script |
| `nfpm.yaml` | Package definition |
| `.github/workflows/release.yml` | CI/CD pipeline |

## Project Conventions

- **Logging**: Use `log "LEVEL" "message"` not `echo`
- **Exit codes**: Follow sysexits.h (0=OK, 64=usage, 78=config, etc.)
- **State files**: Use `/tmp/proxmox-*.state` for runtime state
- **Config**: All config in `/etc/proxmox-sleep.conf`
- **Packages**: Support both deb and rpm via nfpm

## Debugging Tips

```bash
# Enable debug logging
export DEBUG=1

# View service logs
journalctl -u proxmox-idle-monitor -f

# Test guest agent
qm guest cmd $VMID ping

# Check VM status
qm status $VMID

# View Proxmox API data
pvesh get /nodes/$(hostname)/qemu/$VMID/status/current
```
