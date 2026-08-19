# Releasing Proxmox Sleep Manager

This document describes how to set up package signing and release new versions.

## One-Time Setup

### 1. Create a GPG Key for Package Signing

Generate a dedicated key for signing packages (do this on your local machine):

```bash
gpg --full-generate-key

# When prompted:
# - Expiration: 0 (does not expire) or set a reasonable expiration
# - Real name: Proxmox Sleep Manager
# - Email: your-email@example.com
# - Comment: Package Signing Key
```

**The key in use is ed25519 (EdDSA).** That choice decides which distributions
can install the rpms: rpm gained `PGPPUBKEYALGO_EDDSA` in 4.16.0, so EL8
(rpm 4.14) cannot import the key at all and `gpgcheck=1` cannot be satisfied
there. Fedora and RHEL/Alma/Rocky 9 and 10 are fine. Choosing RSA instead would
cover EL8, at the cost of re-signing every published package under the new key.

Confirm what a key actually is before assuming:

```bash
gpg --show-keys --with-colons key.asc | awk -F: '/^pub/{print "algo="$4, "bits="$3}'
# algo=22 is EdDSA, algo=1 is RSA
```

### 2. Export the Private Key

```bash
# List keys to find the key ID
gpg --list-secret-keys --keyid-format LONG

# Export the private key (you'll need this for GitHub)
gpg --armor --export-secret-keys YOUR_KEY_ID > proxmox-sleep-signing-key.asc

# IMPORTANT: Keep this file secure and delete it after adding to GitHub
```

### 3. Add the GPG Key to GitHub Secrets

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Name: `GPG_PRIVATE_KEY`
5. Value: Paste the entire contents of `proxmox-sleep-signing-key.asc`
6. Click **Add secret**
7. Add another secret:
   - Name: `GPG_PASSPHRASE`
   - Value: The passphrase you set when creating the key (or leave empty if no passphrase)

### 4. Create the gh-pages Branch

The repository needs an empty `gh-pages` branch for GitHub Pages:

```bash
# Create orphan branch (no history)
git checkout --orphan gh-pages

# Remove all files
git rm -rf .

# Create initial commit
echo "# Proxmox Sleep Package Repository" > README.md
git add README.md
git commit -m "Initialize gh-pages branch"

# Push to GitHub
git push -u origin gh-pages

# Switch back to main branch
git checkout main
```

### 5. Enable GitHub Pages

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Pages**
3. Under "Build and deployment":
   - Source: **Deploy from a branch**
   - Branch: **gh-pages** / **(root)**
4. Click **Save**

The repository will be available at: `https://stuckj.github.io/proxmox-sleep/`

## Releasing a New Version

### 1. Update Version Numbers

Update the version in these files:
- `nfpm.yaml` (default version, though it's overridden by the tag)
- `README.md` (any hardcoded version references in examples)

### 2. Commit Changes

```bash
git add -A
git commit -m "Prepare release v0.9.0"
git push origin main
```

### 3. Create and Push a Tag

```bash
# Create annotated tag
git tag -a v0.9.0 -m "Release v0.9.0"

# Push the tag (this triggers the release workflow)
git push origin v0.9.0
```

### 4. Monitor the Release

1. Go to **Actions** tab on GitHub to watch the workflow
2. Once complete:
   - Packages are attached to the GitHub Release
   - APT repository is updated at `https://stuckj.github.io/proxmox-sleep/apt`
     (current version) and in the `apt-history` release (every version)
   - YUM repository is updated at `https://stuckj.github.io/proxmox-sleep/yum`
     (every version)

## How the repositories are built

The packages live **only** in the per-version GitHub releases. Both repositories
hold indexes that point back at them, so each package is stored once and the
indexes can be rebuilt from scratch at any time.

`scripts/rebuild-package-repos.sh` does all of it, and the release workflow runs
the same script. It reads the releases API, downloads and size-checks every
asset, and produces:

| Where | What | Covers |
|---|---|---|
| `apt-history` release | flat APT index, `Filename: ../<tag>/<asset>` | every version |
| `gh-pages apt/` | suite `stable`, with the package in `pool/main` | current version only |
| `gh-pages yum/` | repodata with a per-package `xml:base` | every version |

APT resolves `Filename` against the `sources.list` root and has no absolute
form, so a Pages-hosted index can only serve packages that are on Pages — hence
the second, release-hosted repository for the archive. RPM-MD takes an absolute
`xml:base` per package, so the YUM index needs no equivalent.

Because it is derived from the releases, running it twice produces the same
repositories. It defaults to a **dry run**; publishing requires `DRY_RUN=0`.

```bash
# Inspect what would be published, touching nothing
GPG_KEY_ID=<key> GPG_PASSPHRASE=<passphrase> GH_TOKEN=$(gh auth token) \
  scripts/rebuild-package-repos.sh /tmp/repobuild
```

A dry run still signs the indexes it builds — it just publishes none of them — so
it needs the passphrase like any other invocation.

`v0.9.0` and `v0.9.1` are excluded by default (`EXCLUDE_TAGS`): both published
packages built without a version, so both releases carry assets named
`proxmox-sleep-0.0.0.rc0-*` with different bytes. One asset name has to map to
one release for the indexes to resolve, and two packages claiming one version
cannot both be offered.

## One-off maintenance: signing the published archive

Packages built before rpm signing existed carry no signature, so `gpgcheck=1`
rejects them. `scripts/resign-release-rpms.sh` re-signs the published assets in
place. It is a script rather than a workflow on purpose: it rewrites every
published package.

Replacing a release asset is a delete followed by an upload, with no atomic
form, so the script downloads every original to `<work>/backup` and checksums it
into `backup/manifest.tsv` **before** anything is uploaded, re-verifies that
manifest immediately before the first delete, and can put it all back.

`rpmsign` needs an rpm built with gpg support, which Ubuntu's `rpm` package is
not. Run it on Fedora, or in a container.

**The work directory must be a bind mount from the host.** It holds the only copy
of every original once an asset has been replaced, so a container's own
filesystem — which `--rm` discards the moment the shell exits — would take the
recovery path with it.

```bash
mkdir -p ~/proxmox-sleep-resign

podman run --rm -it -v "$PWD:/repo:ro" -v "$HOME/.gnupg:/root/.gnupg" \
           -v "$HOME/proxmox-sleep-resign:/work" fedora:latest bash
dnf install -y rpm-sign gnupg2 git-core gh python3

export GPG_KEY_ID=<key> GPG_PASSPHRASE=<passphrase> GH_TOKEN=<token>

# 1. Download, back up, sign and verify — publishes nothing
/repo/scripts/resign-release-rpms.sh /work

# 2. Replace the published assets
PUBLISH=1 /repo/scripts/resign-release-rpms.sh /work

# If step 2 goes wrong, put the originals back. Name the release that lost a
# package; without ONLY_TAGS this reverts every release to its unsigned original.
RESTORE=1 PUBLISH=1 ONLY_TAGS='v1.1.0' /repo/scripts/resign-release-rpms.sh /work
```

Re-signing changes each package's bytes, so **the repositories must be rebuilt
afterwards** or dnf will reject every rpm against the stale checksums:

```bash
DRY_RUN=0 GPG_KEY_ID=<key> GPG_PASSPHRASE=<passphrase> GH_TOKEN=<token> \
  scripts/rebuild-package-repos.sh /tmp/repobuild
```

Keep `~/proxmox-sleep-resign/backup` until a real `dnf install` has been tried
against the rebuilt repository.

### Verifying it worked

Header inspection alone is easy to get wrong, because which signature-header tag
an ed25519 signature lands in depends on who signed it: `rpmsign` writes tag 267
(`DSAHEADER`), while nfpm writes 268 (`RSAHEADER`) and 1002 (`PGP`). A checker
that looks at only one of them calls correctly signed packages unsigned.
`scripts/check-rpm-signature.py` reads all four, and the release workflow runs it
on every build:

```bash
scripts/check-rpm-signature.py --key <key> ./*.rpm
```

An actual install under `gpgcheck=1` has no such failure mode, so try one:

```bash
podman run --rm -it fedora:latest bash -c '
  cat > /etc/yum.repos.d/proxmox-sleep.repo <<EOF
[proxmox-sleep]
name=Proxmox Sleep Manager
baseurl=https://stuckj.github.io/proxmox-sleep/yum
enabled=1
gpgcheck=1
gpgkey=https://stuckj.github.io/proxmox-sleep/yum/gpg-key.asc
EOF
  dnf install -y proxmox-sleep && rpm -qi proxmox-sleep | grep -i "Key ID"'
```

`dnf install` succeeding under `gpgcheck=1` implies a good signature only while
gpgcheck is really in force; the `Key ID` check confirms it independently rather
than inferring it from an exit code.

### 5. Edit Release Notes (Optional)

Go to **Releases** on GitHub and edit the auto-created release to add release notes.

## Manual Workflow Trigger

You can also trigger a build without creating a tag:

1. Go to **Actions** → **Build and Release Packages**
2. Click **Run workflow**
3. Enter the version number (without `v` prefix)
4. Click **Run workflow**

This is useful for testing the build process. Packages are not attached to a
release — they are available as workflow artifacts — and the repositories are
not republished, because they are built from release assets and a dispatch build
produces none.

## Troubleshooting

### GPG Key Issues

```bash
# Verify the key is correctly imported in GitHub Actions
# Check the workflow logs for "Import GPG key" step

# Test locally that the key works
gpg --list-secret-keys
echo "test" | gpg --armor --sign
```

### Package Signing Failures

- Ensure `GPG_PASSPHRASE` secret is set (can be empty string if key has no passphrase)
- Check workflow logs for GPG-related errors
- Verify the key was exported correctly with `gpg --armor --export-secret-keys`

nfpm signs the rpm only when `rpm.signature.key_file` resolves to a readable
key, and **reports success either way** — a missing secret produces an unsigned
package and a green build. The `Assert the rpm is signed` step exists to catch
exactly that, so a failure there means the key or passphrase did not reach nfpm,
not that the check is wrong.

### GitHub Pages Not Updating

- Verify the `gh-pages` branch exists and has content
- Check repository Settings → Pages is configured correctly
- GitHub Pages can take a few minutes to update after a push

## Repository URLs

After setup, users can install packages using:

**APT (Debian/Ubuntu/Proxmox):**
```bash
curl -fsSL https://stuckj.github.io/proxmox-sleep/gpg-key.asc | sudo gpg --dearmor -o /usr/share/keyrings/proxmox-sleep.gpg
echo "deb [signed-by=/usr/share/keyrings/proxmox-sleep.gpg] https://stuckj.github.io/proxmox-sleep/apt stable main" | sudo tee /etc/apt/sources.list.d/proxmox-sleep.list
sudo apt update
sudo apt install proxmox-sleep
```

**APT archive (every published version):**
```bash
echo "deb [signed-by=/usr/share/keyrings/proxmox-sleep.gpg] https://github.com/stuckj/proxmox-sleep/releases/download/apt-history/ ./" | sudo tee /etc/apt/sources.list.d/proxmox-sleep-history.list
sudo apt update
apt list -a proxmox-sleep
```

**YUM/DNF (RHEL/CentOS/Fedora)** — requires rpm 4.16 or newer; indexes every
version:
```bash
sudo tee /etc/yum.repos.d/proxmox-sleep.repo << 'EOF'
[proxmox-sleep]
name=Proxmox Sleep Manager
baseurl=https://stuckj.github.io/proxmox-sleep/yum
enabled=1
gpgcheck=1
gpgkey=https://stuckj.github.io/proxmox-sleep/yum/gpg-key.asc
EOF
sudo dnf install proxmox-sleep
```
