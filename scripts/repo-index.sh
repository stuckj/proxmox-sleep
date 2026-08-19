#!/usr/bin/env bash
# Emit the landing page for the package repositories on stdout.
set -euo pipefail
REPO="${GITHUB_REPOSITORY:-stuckj/proxmox-sleep}"
# Honour the same seam as rebuild-package-repos.sh, so a test run does not write
# production URLs into the page it generates.
BASE="${RELEASE_BASE:-https://github.com/${REPO}/releases/download}"
PAGES="${PAGES_URL:-https://stuckj.github.io/proxmox-sleep}"

cat <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>Proxmox Sleep Manager - Package Repository</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
    pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
    code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; }
    h1 { border-bottom: 2px solid #333; padding-bottom: 10px; }
    h2 { margin-top: 30px; }
    .note { background: #f0f6ff; border-left: 4px solid #4a7dbd; padding: 10px 15px; margin: 15px 0; }
  </style>
</head>
<body>
  <h1>Proxmox Sleep Manager</h1>
  <p>Automated power management for Proxmox hosts with Windows VMs and GPU passthrough.</p>

  <h2>Debian/Ubuntu/Proxmox (APT)</h2>
  <pre>
# Add the GPG key
curl -fsSL ${PAGES}/gpg-key.asc | sudo gpg --dearmor -o /usr/share/keyrings/proxmox-sleep.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/proxmox-sleep.gpg] ${PAGES}/apt stable main" | sudo tee /etc/apt/sources.list.d/proxmox-sleep.list

# Install
sudo apt update
sudo apt install proxmox-sleep</pre>

  <div class="note">
    <p>This repository carries the <strong>current release only</strong>. To install or pin an
    older version, add the archive repository below — it indexes every version ever
    published.</p>
    <p>Enabling both is safe. They are two <em>sources for the same package</em>, not two
    packages, so apt merges them and still installs exactly one <code>proxmox-sleep</code>. The
    current release appears in both, with the same checksum, and apt simply lists two sources
    for it.</p>
  </div>

  <h3>Debian/Ubuntu/Proxmox (APT) — full version history</h3>
  <pre>
echo "deb [signed-by=/usr/share/keyrings/proxmox-sleep.gpg] ${BASE}/apt-history/ ./" | sudo tee /etc/apt/sources.list.d/proxmox-sleep-history.list

sudo apt update
apt list -a proxmox-sleep            # every published version
sudo apt install proxmox-sleep=1.0.0 # pin one</pre>

  <h2>RHEL/CentOS/Fedora (YUM/DNF)</h2>
  <p>Indexes every version published; no separate archive repository is needed.</p>
  <p><strong>Requires rpm 4.16 or newer</strong> &mdash; Fedora, RHEL/Alma/Rocky 9
  and 10. Packages are signed with an ed25519 key, and rpm only learned to read
  EdDSA signatures in 4.16.0. EL8 ships rpm 4.14, which cannot import the key
  (<code>key 1 import failed</code>), so <code>gpgcheck=1</code> cannot be
  satisfied there.</p>
  <pre>
# Add the repository
sudo tee /etc/yum.repos.d/proxmox-sleep.repo &lt;&lt; 'REPO'
[proxmox-sleep]
name=Proxmox Sleep Manager
baseurl=${PAGES}/yum
enabled=1
gpgcheck=1
gpgkey=${PAGES}/yum/gpg-key.asc
REPO

# Install
sudo dnf install proxmox-sleep
sudo dnf install proxmox-sleep-1.0.0   # or pin an older version</pre>

  <h2>Where the packages live</h2>
  <p>Package files are served from the per-version
  <a href="https://github.com/${REPO}/releases">GitHub releases</a>; these repositories carry
  only the indexes. The APT archive reaches them with a relative
  <code>Filename</code>, and the YUM metadata with a per-package <code>xml:base</code>.</p>

  <h2>Links</h2>
  <ul>
    <li><a href="https://github.com/${REPO}">GitHub Repository</a></li>
    <li><a href="https://github.com/${REPO}/releases">Release Downloads</a></li>
  </ul>
</body>
</html>
EOF
