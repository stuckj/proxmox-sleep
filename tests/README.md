# Offline test suite

Runs both scripts end-to-end through their real CLI subcommands against mocked
Proxmox tooling. **No Proxmox host, no root, and no network required** — the
whole suite finishes in a few seconds.

```bash
tests/run-tests.sh              # everything
tests/run-tests.sh gaming       # only tests whose name contains "gaming"
VERBOSE=1 tests/run-tests.sh    # also dump each test's captured output
```

Exit status is 0 when every test passes, 1 otherwise.

## How it works

Each test runs in its own subshell with a private sandbox directory, so
`MOCK_*` variables, config, and state never leak between tests. Within a test:

| Variable | Points at |
|---|---|
| `CONFIG_FILE` | a generated `proxmox-sleep.conf` in the sandbox |
| `PROXMOX_SLEEP_STATE_DIR` | sandbox stand-in for `/run/proxmox-sleep` |
| `IDLE_MONITOR_LOG` / `SLEEP_MANAGER_LOG` | sandbox log files |
| `MOCK_CALL_LOG` | every mock invocation, one per line |
| `MOCK_RUNTIME` | mock power-state, so `shutdown` really stops an instance |

`tests/mocks/` is prepended to `PATH`, replacing `qm`, `pct`, `pvesh`,
`systemctl`, `systemd-inhibit`, `who`, `pgrep`, `hostname`, `install`, and
`sleep`. Mocks are driven entirely by environment variables — see the header
comment in each one.

Two mocks live outside the main directory on purpose:

- `mocks/optional/nvidia-smi` is only added to `PATH` by tests that call
  `with_nvidia`. Leaving it out models a host where the GPU is bound to
  `vfio-pci` and `command -v nvidia-smi` fails — which must read as "unknown",
  never "active".
- `mocks/container/ps` is injected only *inside* `pct exec`, which the `pct`
  mock actually executes locally. That means the real
  `ps -eo args=` → `awk` → `basename` pipeline in `check_ct_gaming_processes`
  is exercised rather than stubbed past.

`sleep` returns immediately, so tests covering the hibernation poll loop and
the post-wake resume delay run in milliseconds. The requested duration is still
recorded in the call log.

## Notes on the mocks

- `install` drops the `-o root -g root` flags and delegates to the real binary.
  The scripts create their state directory with ownership flags that need
  privileges the test runner does not have; only the `chown` is stubbed.
- The scripts are invoked as `bash <script>` because the repo does not mark
  them executable (the installer sets mode 0755 at install time).
- `PROXMOX_SLEEP_STATE_DIR` is the one testability hook in the production
  scripts. It is not a supported configuration knob: the systemd units run with
  a clean environment, so only a root-run test can set it.

## Coverage

Tests are grouped by prefix; `tests/run-tests.sh <substring>` runs one group.

- **legacy/** — the `VMID=`-only config still enumerates one VM in both
  scripts, and `GAMING_PROCESSES=""` means "disabled" rather than "fall back to
  the default list".
- **multi/** — `VM_IDS` / `CONTAINER_IDS` enumeration and per-instance naming.
- **cycle/** — `pre-sleep` → state file → `post-wake`, for every
  `SLEEP_ACTION`; guest-agent fallback, forced stop, hibernation timeout, and
  the `PRE_SLEEP_NONBLOCKING` exit-code split.
- **gaming/** — exact whole-line matching (`steam` must not match
  `steamwebhelper`), `.exe` stripping, case-insensitivity, and container
  process names longer than `comm`'s 15-character limit.
- **combined/** — the host + VM + container idle decision, per-instance
  threshold overrides, and `MONITOR=0`.
- **gpu/** — the `-1` sentinel never reads as active, `nvidia-smi` is polled
  once per cycle, and the max is taken across multiple GPUs.
- **host/**, **wake/**, **config/** — SSH sessions, blocking processes/units,
  sleep inhibitors, wake-time bookkeeping, and `EX_CONFIG` (78) validation
  failures.
- **pkg/** — the release pipeline: rpm signature detection, the YUM `xml:base`
  rewrite, and the destructive-path guards in the repository scripts.

The `pkg/` group builds its own inputs rather than reading fixtures off disk.
`tests/rpm-fixture.py` writes a synthetic rpm whose signature header holds
exactly what a given test needs — a signature in named tags, digests without a
signature, a non-signature packet, or a truncated file — so what each test
asserts stays visible in the test rather than in a committed binary.

The tests that drive the release scripts end to end add `mocks/pkg/` to `PATH`
via `with_pkg_mocks`, which stands in for `gh`, `curl`, `gpg` and `createrepo_c`.
`mocks/pkg/rpmsign` is deliberately a failing stub: those tests arrange for every
package to be signed already, so invoking it means the script signed something it
should have skipped.

Two of those mocks deliberately model the tool rather than the caller:

- `mocks/pkg/createrepo_c` emits all three metadata types rather than just
  `primary`, because `yum_xmlbase.py` rewrites `primary` and copies the others
  through. It also defaults to **zstd**, as createrepo_c 1.x does, and writes
  gzip only when `--general-compress-type` asks for it — so dropping that flag
  fails the tests the way it would fail a release.
- `mocks/pkg/gh` really stores what `release upload` is given, and a tag in
  `MOCK_UPLOAD_FAIL_TAGS` has its assets deleted *before* the failure, which is
  what `--clobber` does when the upload half of a replacement breaks. A mock
  that failed without deleting would model a kinder API than the real one and
  hide what the retries exist for.

## Regressions locked in

Several tests exist specifically to keep previously fixed bugs fixed:

- `cycle/hibernate-timeout-upsert` — `state_set` used to append, leaving both
  `hibernated` and the post-timeout value in the file and double-resuming the
  VM on wake.
- `gaming/vm-no-substring-match`, `gaming/ct-no-substring-match` — `grep -Fqi`
  matched `steamwebhelper` for the pattern `steam`; it is now `grep -Fxqi`.
- `gaming/ct-long-name-not-truncated` — `ps -eo comm=` truncates to
  `TASK_COMM_LEN` (15), so the code reads `args=` instead.
- `gpu/ct-max-across-gpus` — only GPU 0 was read, missing load on a second GPU.
- `gpu/ct-absent-binary-not-active` — a missing or vfio-blinded `nvidia-smi`
  must not block sleep.
- `wake/corrupt-wake-file-repaired` — a non-numeric wake file used to crash the
  daemon under `set -u`; the repair message must also go to **stderr**, because
  `get_seconds_since_wake`'s stdout is its return value.
- `pkg/sig-eddsa-tag-267`, `pkg/sig-nfpm-shape` — which signature-header tag an
  ed25519 signature lands in depends on the signer: `rpmsign` writes `DSAHEADER`
  (267), nfpm writes `RSAHEADER` (268) and `PGP` (1002). A checker that reads
  only one of them calls correctly signed packages unsigned.
- `pkg/sig-tag-alone-not-proof` — the signature tag being present is not proof;
  its contents have to parse as a signature packet.
