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
- The two daemons use `set -uo pipefail` — **not** `-e`. A monitor that runs for weeks must
  survive a failing `qm status` or `pct exec`, so failures are handled at the call site
  instead of aborting the process. `install.sh` and `uninstall.sh` do use `set -euo pipefail`;
  they are short and should stop at the first error.
- `log()` takes a **single** argument: `log "message"`. There is no level parameter —
  `log "INFO" "msg"` prints only `INFO` and silently drops the message.
- `log()` writes to the log file. CLI subcommands (`status`, `check`) print to stdout with
  `echo` deliberately: that output is the user-facing result, not a log entry. Do not
  "fix" those to use `log()`.
- Config values are read through `get_cfg`, which uses `printf` rather than `echo` so a
  value starting with `-n`/`-e` is not parsed as an option.
- Follow existing code patterns in the project

### What goes in which document

**`README.md`** — for a user, who is probably not an engineer. What it does, how to install
and configure it. Claims here are checked against what the code actually does.

**`proxmox-sleep.conf.example`** — the authority on every config setting and its default.
A new setting is documented here, in the same PR.

**`docs/DESIGN.md`** — directional only: components, boundaries, who owns what. It changes
when that direction changes — a component added or removed, a boundary moved — and not
otherwise. Most bug fixes leave it untouched.

**`docs/DEVELOPMENT.md`** — how to work on the project: the checks, the test suite, conventions.

**The code** — the authority on how it actually works.

Detail belongs one layer below wherever it is tempting to put it. A measured fact about
Proxmox, `qm`, or the guest agent goes in a test that fails when it stops being true, and in
the dated PR or issue — not in `DESIGN.md`, which cannot fail and will outlive it. Do not
describe the same mechanism in two places; one copy goes stale and the stale one is trusted.

### Comments

Comments describe the code, not the project's history. Explain what a reader would otherwise
re-derive: a non-obvious ordering constraint, an external behaviour depended on, an
alternative that looks right and is not.

Two things never belong in a comment: general best-practice advice, and development history.
What broke while building it, which review round caught it, what an earlier design assumed —
that goes in the commit message, the PR, or the issue, where it is permanent, searchable, and
out of the reader's way. Prefer naming the constraint over narrating the discovery: "must run
before the socket is chmodded" beats "we found during review that this raced".

**10-20% of lines is a guide, not a limit.** The shipped files sit at roughly 10-13%
(`proxmox-idle-monitor.sh` ~10%, `proxmox-sleep-manager.sh` ~13%, `tests/run-tests.sh` ~11%).
Above the band, re-read the comments against the rules above rather than cutting to a number;
below it is not a licence to pad. The mock scripts under `tests/mocks/` legitimately sit
higher, because they document an external tool's output format that nothing in the code implies.

## Review triage: must fix vs nice to have

Applies to any review of this repo — Copilot, a human, or a reviewer subagent. **A reviewer
has no authority.** Verify every finding against the code before acting on it; reviewers
assert things that are not true. Sort each into one of four buckets.

**Must fix — substantial.** Wrong behaviour, security, data loss, a broken invariant, a test
that cannot fail, or a documented claim that is false. In this project that concretely means:

- A running VM or container is stopped and then **not** resumed — the user comes back to a
  machine that lost its session. Anything that strands an instance in the state file, or
  drops an entry from it, is data loss here.
- The host sleeps while an instance is mid-hibernate, or while a user is demonstrably active
  (SSH session, gaming process, GPU busy). A guest interrupted mid-hibernate can come back corrupt.
- The host never sleeps at all, or sleeps far earlier than the configured threshold.
- Legacy `VMID=` config stops working. Existing installs must keep running untouched.
- A config setting that is documented but not read, or read but not documented.
- `status`/`check` reporting something the code does not do.

**Nice to have — skip it, and say why.** Naming, wording, formatting, hypothetical future
requirements, defensive checks for states the caller already guarantees, and a statement that
is *true* but could be hedged more precisely. These are not worth a diff. Do not let a pile of
them turn into a rewrite.

**False.** The reviewer is wrong. Record the refutation with the evidence — the line of code,
the test, the actual command output — and move on.

**Out of bounds.** The fix would break a rule above. By far the commonest shape is a reviewer
asking for a comment that explains, justifies, or caveats something; complying grows the diff
with exactly the prose the Comments section bars. If the reasoning is worth keeping it goes in
the PR body, not the source. Reject it, cite the rule.

Judge the cumulative effect, not each finding alone: every request for explanation is small and
defensible on its own, and the sum is a diff a third comment by line count.

The line between the first two buckets is what lets a review loop terminate, so hold it
honestly. False is substantial; imprecise is not. Upgrading a wording nit to "must fix" because
the reviewer argued it well is how a review runs forever.

**Fix the class, not the instance.** When a finding is one case of a general mistake, search for
its siblings before calling it fixed — the same bug usually sits a few lines below, and the same
false claim usually appears in more than one document.

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

Sort each comment using the buckets in "Review triage: must fix vs nice to have" above —
that section owns the criteria. The priority labels below are just the tracking shorthand
for the table in the next step:

| Priority | Bucket | Action |
|----------|--------|--------|
| **P0 - Critical** | Substantial: security, data loss, a stranded instance | Must fix |
| **P1 - High** | Substantial: wrong behaviour, false documented claim | Must fix |
| **P2/P3 - Low** | Nice to have: naming, wording, style | Skip, with a reason |
| **No Action** | False, or out of bounds under the house rules | Justify |

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
# Offline test suite - no Proxmox host, no root, no network required.
# Run this before pushing; see tests/README.md for what it covers.
tests/run-tests.sh
tests/run-tests.sh gaming     # filter by test name substring

# Syntax check
bash -n proxmox-sleep-manager.sh

# Shellcheck
shellcheck -x *.sh

# Test single idle check
./proxmox-idle-monitor.sh check

# Test status display
./proxmox-idle-monitor.sh status
```

**When adding a check or a config setting, add a test for it.** The suite
mocks `qm`/`pct`/`pvesh`/`nvidia-smi`, so almost every code path is reachable
without hardware — including the ones that are awkward to reproduce on a real
host, such as hibernation timeouts and a GPU bound to `vfio-pci`.

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

- **Logging**: `log "message"` (single argument) for the log file; `debug "message"` for
  DEBUG=1-only output. CLI subcommand output goes to stdout with `echo`.
- **Exit codes**: Follow sysexits.h (0=OK, 64=usage, 78=config, etc.)
- **State files**: Use `/run/proxmox-sleep/*.{state,wake}` for runtime state (root-owned, avoids /tmp symlink risks)
- **Config**: All config in `/etc/proxmox-sleep.conf`
- **Packages**: Support both deb and rpm via nfpm

## Verifying claims about this codebase

Three rules for checking a claim before repeating it:

1. **When independent surfaces appear to fail identically, suspect the checker.** Several
   docs "missing" the same thing is usually one bad pattern, not several bad docs.
2. **Sanity-check a pattern against a known-present control before trusting a negative.**
   A suspiciously clean "nothing found" is usually a bad grep.
3. **Parse the source of truth, not prose about it.** Read the function, the `case` dispatch,
   or the real command output. Grepping documentation produces false gaps and hides true ones.

This has already cost something here: `CLAUDE.md` and `docs/DEVELOPMENT.md` both documented
`set -euo pipefail` and a two-argument `log "LEVEL" "message"`. Neither was true — the daemons
run `set -uo pipefail` on purpose and `log()` takes one argument, so `log "INFO" "msg"` would
have printed `INFO` and dropped the message. Two documents agreeing is not evidence.

A claim about someone else's software — `qm`, `pct`, `pvesh`, the QEMU guest agent, systemd —
is checked against that software, not recalled. Record it where it cannot rot: a test that
fails when it stops being true, plus the dated PR or issue.

## Tooling gotchas

- **Only the repo owner can request a Copilot review.** A bot account's request returns
  success but creates no timeline event and no review.
- **The bot account cannot resolve review threads or write PR metadata.** It has push but not
  admin; those calls fail as 404 rather than 403. Replying to a review comment works; marking
  the thread resolved does not.
- **Run the offline suite before pushing** — `tests/run-tests.sh`. It needs no Proxmox host,
  no root, and no network, so there is no excuse for pushing an unrun change. CI runs the
  same script on push and pull request.

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
