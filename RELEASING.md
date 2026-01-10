# Releasing Proxmox Sleep Manager

This document describes how to set up package signing and release new versions.

## One-Time Setup

### 1. Create a GPG Key for Package Signing

Generate a dedicated key for signing packages (do this on your local machine):

```bash
# Generate a new GPG key (use RSA, 4096 bits, no expiration for simplicity)
gpg --full-generate-key

# When prompted:
# - Key type: RSA and RSA (default)
# - Key size: 4096
# - Expiration: 0 (does not expire) or set a reasonable expiration
# - Real name: Proxmox Sleep Manager
# - Email: your-email@example.com
# - Comment: Package Signing Key
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
   - YUM repository is updated at `https://stuckj.github.io/proxmox-sleep/yum`

### 5. Edit Release Notes (Optional)

Go to **Releases** on GitHub and edit the auto-created release to add release notes.

## Manual Workflow Trigger

You can also trigger a build without creating a tag:

1. Go to **Actions** → **Build and Release Packages**
2. Click **Run workflow**
3. Enter the version number (without `v` prefix)
4. Click **Run workflow**

This is useful for testing the build process. Note that packages won't be attached to a release, but they'll be available as workflow artifacts.

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

**YUM/DNF (RHEL/CentOS/Fedora):**
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
