# Development Workflows

This document describes the development workflows, conventions, and processes used for the Proxmox Sleep Manager project.

## Table of Contents

- [Git Workflow](#git-workflow)
- [Pull Request Process](#pull-request-process)
- [PR Review with Copilot and Claude](#pr-review-with-copilot-and-claude)
- [Code Style and Conventions](#code-style-and-conventions)
- [Testing](#testing)
- [Release Process](#release-process)

---

## Git Workflow

### Branch Strategy

- **`main`**: Stable, production-ready code. All releases are tagged from this branch.
- **Feature branches**: Created from `main` for new features or fixes. Named descriptively (e.g., `feature/multi-vm-support`, `fix/hibernation-timeout`).

### Commit Guidelines

#### Commit Message Format

```
<type>: <short summary>

<optional body with more details>

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring without behavior change
- `test`: Adding or updating tests
- `chore`: Build, CI, or maintenance tasks

#### Commit Amending Rules

**CRITICAL**: The following rules about commit amending must be strictly followed to avoid merge conflicts:

| Scenario | Allowed? | Rationale |
|----------|----------|-----------|
| Amend only the commit message | **YES** | Message-only changes don't affect file content |
| Amend to add/modify file content | **NO** | Always creates merge conflicts if branch is shared |
| Amend after pushing to remote | **NO** | Requires force push, disrupts collaborators |
| Amend to fix pre-commit hook changes | **NO** | Create a new commit instead |

**What to do instead of amending**:

1. **Forgot a file?** Create a new commit: `git commit -m "fix: include missing file"`
2. **Need to fix something in last commit?** Create a fixup commit: `git commit -m "fix: correct typo in previous commit"`
3. **Pre-commit hook modified files?** Stage and create new commit: `git add . && git commit -m "style: apply formatting from pre-commit"`

**The only exception**: If you haven't pushed yet AND you only need to change the commit message:
```bash
git commit --amend -m "new message"
```

### Common Git Operations

```bash
# Create feature branch
git checkout -b feature/my-feature main

# Make changes and commit
git add .
git commit -m "feat: add new feature

Detailed description of what this feature does.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

# Push to remote (first time)
git push -u origin feature/my-feature

# Push subsequent changes
git push

# Keep branch updated with main
git fetch origin
git rebase origin/main
```

---

## Pull Request Process

### Creating a Pull Request

1. **Ensure all changes are committed and pushed**
   ```bash
   git status  # Should be clean
   git push
   ```

2. **Create PR using GitHub CLI**
   ```bash
   gh pr create --title "feat: add new feature" --body "$(cat <<'EOF'
   ## Summary
   - Added new feature X
   - Fixed issue Y
   - Updated documentation

   ## Test plan
   - [ ] Tested on Proxmox 8.x
   - [ ] Verified hibernation works
   - [ ] Checked idle detection

   Generated with Claude Code
   EOF
   )"
   ```

3. **Automated checks will run**:
   - GitHub Actions CI (if configured)
   - Copilot code review

### PR Review Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PR Review Workflow                                 │
│                                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │  Create  │───>│  Copilot │───>│  Claude  │───>│  Apply   │              │
│  │    PR    │    │  Review  │    │ Evaluate │    │  Fixes   │              │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘              │
│                       │               │               │                     │
│                       ▼               ▼               ▼                     │
│                 Comments on     Summarize &      Fix or reply              │
│                 PR diff         prioritize       to each comment           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## PR Review with Copilot and Claude

### Overview

After any changes are made to a PR, the following review process should be followed:

1. **Copilot runs** automatically on the PR and leaves comments
2. **Claude evaluates** each Copilot comment
3. **Claude summarizes** feedback with priority levels
4. **Claude either fixes** the issue or provides justification for not fixing
5. **Claude replies** to each comment thread with the decision

### Detailed Process

#### Step 1: Gather Copilot Comments

After pushing changes to a PR, wait for Copilot to complete its review, then gather all comments:

```bash
# Get PR number
PR_NUMBER=$(gh pr view --json number -q '.number')

# Get all review comments
gh api repos/{owner}/{repo}/pulls/${PR_NUMBER}/comments
```

#### Step 2: Evaluate and Categorize Comments

Claude should evaluate each comment and assign a priority:

| Priority | Criteria | Action Required |
|----------|----------|-----------------|
| **P0 - Critical** | Security vulnerabilities, data loss risks, crashes | Must fix before merge |
| **P1 - High** | Bugs, incorrect behavior, significant issues | Should fix before merge |
| **P2 - Medium** | Code quality, maintainability, minor issues | Consider fixing |
| **P3 - Low** | Style suggestions, minor improvements | Optional |
| **No Action** | False positive, not applicable, already addressed | Explain why no fix needed |

#### Step 3: Create Summary and Todo List

Claude should create a summary table and track each comment:

```markdown
## Copilot Review Summary

| ID | Comment | Priority | Decision | Status |
|----|---------|----------|----------|--------|
| 123456 | "Potential null reference" | P1 | Fix: Add null check | Pending |
| 123457 | "Consider using const" | P3 | No fix: Already immutable | Done |
| 123458 | "Missing error handling" | P2 | Fix: Add try-catch | Pending |
```

#### Step 4: Process Each Comment

For each comment, Claude must:

1. **Track the comment ID** in a todo list
2. **Either implement a fix** or **provide justification**
3. **Reply to the comment thread** with the decision

##### If Fixing:

```bash
# After making the fix, reply to the comment
gh api repos/{owner}/{repo}/pulls/comments/{comment_id}/replies \
  -f body="Fixed in commit abc1234. Added null check as suggested."
```

##### If Not Fixing (with justification):

```bash
gh api repos/{owner}/{repo}/pulls/comments/{comment_id}/replies \
  -f body="No fix needed: This variable is guaranteed non-null by the validation on line 42. The function only accepts validated input from \`parse_config()\` which throws on null values."
```

#### Step 5: Track Progress

Use a todo list to ensure no comment is missed:

```markdown
## Comment Processing Checklist

- [x] Comment #123456: Null reference - Fixed in abc1234
- [x] Comment #123457: Use const - Justified, no fix needed
- [ ] Comment #123458: Error handling - In progress
- [ ] Comment #123459: Documentation - Pending
```

### Example Claude Workflow

When reviewing a PR with Copilot comments, Claude should:

```
1. Read all comments:
   gh api repos/owner/repo/pulls/123/comments

2. Create summary table with priorities

3. For each comment (tracked by ID):
   a. Analyze the suggestion
   b. Decide: fix or justify
   c. If fix: make the change, commit
   d. Reply to comment thread with decision
   e. Mark as complete in todo list

4. After all comments processed:
   - Push any fix commits
   - Verify all comments have replies
   - Report summary to user
```

### Reply Templates

**For implemented fixes**:
```
Implemented fix in [commit SHA].

[Brief description of what was changed and why it addresses the concern]
```

**For declined suggestions (with justification)**:
```
After analysis, this suggestion does not require a fix because:

[Detailed technical justification]

[Reference to documentation, code, or standards if applicable]
```

**For false positives**:
```
This appears to be a false positive because:

[Explanation of why the detected issue doesn't apply]

The code is correct as-is because [reason].
```

---

## Code Style and Conventions

### Shell Script Style

- **Shebang**: `#!/usr/bin/env bash`
- **Shellcheck**: All scripts should pass shellcheck
- **Quoting**: Always quote variables: `"$variable"`
- **Functions**: Use lowercase with underscores: `my_function()`
- **Constants**: Use uppercase: `MAX_RETRIES=5`
- **Local variables**: Declare with `local`: `local my_var="value"`

### Error Handling

```bash
# Use set -e for early exit on errors
set -euo pipefail

# Use explicit error handling for expected failures
if ! some_command; then
    log "ERROR" "some_command failed"
    return 1
fi

# Use trap for cleanup
trap cleanup EXIT
```

### Logging

```bash
# Always use the log function
log "INFO" "Starting operation"
log "DEBUG" "Variable value: $var"  # Only shown if DEBUG=1
log "ERROR" "Operation failed"
```

---

## Testing

### Manual Testing Checklist

Before submitting a PR, verify:

- [ ] Scripts pass shellcheck: `shellcheck *.sh`
- [ ] Install script works on fresh system
- [ ] Sleep manager handles missing VM gracefully
- [ ] Idle monitor respects configuration
- [ ] Hibernation completes successfully
- [ ] Wake/resume works correctly
- [ ] Logs are written correctly

### Testing Commands

```bash
# Check script syntax
bash -n proxmox-sleep-manager.sh
bash -n proxmox-idle-monitor.sh

# Run shellcheck
shellcheck -x *.sh

# Test idle check (single iteration)
./proxmox-idle-monitor.sh check

# Test status display
./proxmox-idle-monitor.sh status

# Simulate sleep (without actually sleeping)
DEBUG=1 ./proxmox-sleep-manager.sh pre-sleep
```

---

## Release Process

See [RELEASING.md](../RELEASING.md) for detailed release instructions.

### Quick Reference

```bash
# 1. Ensure main is up to date
git checkout main
git pull

# 2. Create and push tag
git tag -a v1.1.0 -m "Release v1.1.0"
git push origin v1.1.0

# 3. GitHub Actions automatically:
#    - Builds deb/rpm packages
#    - Creates GitHub Release
#    - Updates package repositories
```

---

## Appendix: Useful Commands

### GitHub CLI Commands

```bash
# View PR status
gh pr view

# List PR comments
gh pr view --comments

# Get review comments via API
gh api repos/{owner}/{repo}/pulls/{pr}/comments

# Reply to a comment
gh api repos/{owner}/{repo}/pulls/comments/{id}/replies -f body="message"

# View CI status
gh pr checks

# Merge PR
gh pr merge --squash
```

### Debugging Commands

```bash
# View service status
systemctl status proxmox-sleep-manager
systemctl status proxmox-idle-monitor

# View logs
journalctl -u proxmox-idle-monitor -f
tail -f /var/log/proxmox-idle-monitor.log

# Test guest agent
qm guest cmd $VMID ping

# Check VM status
qm status $VMID
pvesh get /nodes/$(hostname)/qemu/$VMID/status/current
```
