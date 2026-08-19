#!/usr/bin/env bash
# Add an OpenPGP signature to published rpms that do not have one.
#
# Packages built before rpm signing existed carry no signature, so `gpgcheck=1`
# — which every documented dnf install uses — rejects them. Signing only new
# releases would leave the archive repository unusable for exactly the old
# versions it exists to serve, so the published assets are re-signed in place.
#
# This is a one-off backfill, run by hand. It is not a workflow: it rewrites
# every published package, and that is not something a dispatch button should
# make easy.
#
# Replacing an asset is a delete followed by an upload; the GitHub API has no
# atomic replace. Between the two the package does not exist, and the release
# asset is the only copy. So every original is downloaded to a backup directory
# and checksummed *before* anything is uploaded, the backup is re-verified
# immediately before the first delete, and RESTORE=1 puts it all back.
#
# Signing rewrites only the signature header: the main header and the payload
# come through byte-identical, and this script proves that for every package
# rather than assuming it. A package already signed by this key is left alone,
# so re-running is cheap and a run that stops early resumes where it left off.
#
# Nothing is uploaded unless PUBLISH=1. The default run downloads, backs up,
# signs and verifies, then reports — the published releases are untouched.
#
# Replacing an asset also invalidates the checksums in the YUM repodata, so the
# repositories must be rebuilt afterwards with rebuild-package-repos.sh.
#
# Requires: gh (authenticated), curl, python3, gpg with the signing key imported
# and GPG_KEY_ID set, and rpmsign built with gpg support. Ubuntu's rpm package
# does not include signing; run this on Fedora, or in a container:
#
#   podman run --rm -it -v "$PWD:/repo" -v "$HOME/.gnupg:/root/.gnupg" fedora:latest \
#     bash -c 'dnf install -y rpm-sign gnupg2 git-core gh python3 && /repo/scripts/resign-release-rpms.sh /tmp/resign'
#
# Usage: resign-release-rpms.sh <work-dir>
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-stuckj/proxmox-sleep}"
KEY="${GPG_KEY_ID:?GPG_KEY_ID must be set}"
# Every key id that counts as "ours" when deciding whether a package is already
# correctly signed. gpg signs with a signing subkey when the key has one, so the
# id on the signature is not necessarily the primary's. Falls back to the
# primary alone.
KEY_IDS="${GPG_KEY_IDS:-$KEY}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
# Uploading requires PUBLISH=1 explicitly: the upload overwrites the only copy
# of each package that exists.
PUBLISH="${PUBLISH:-0}"
[ "$PUBLISH" = 1 ] || PUBLISH=0
# Put the backed-up originals back and exit. The recovery path for a run that
# died between a delete and its upload.
RESTORE="${RESTORE:-0}"
# Space-separated release tags to limit the run to, matched exactly. Empty means
# every release.
ONLY_TAGS="${ONLY_TAGS:-}"
# Re-sign even packages already signed by this key. Rarely wanted: the skip is
# what makes a run resumable.
FORCE="${FORCE:-0}"
# Waits before each upload attempt. A 403 that lands on the upload half of a
# replacement has already deleted the asset, so waiting recovers the package
# where giving up loses it.
UPLOAD_BACKOFF="${UPLOAD_BACKOFF:-0 30 120 300}"
# Seconds between releases, to stay under the secondary limit on
# content-generating requests.
UPLOAD_PACE="${UPLOAD_PACE:-5}"

say() { printf '\n== %s\n' "$1"; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $(basename "$0") <work-dir>"
WORK="$(realpath -m -- "$1")" || die "cannot resolve '$1'"
[ -d "$(dirname "$WORK")" ] || die "cannot resolve '$1' — its parent directory does not exist"
MARKER=.resign-marker
case "$WORK" in
  / | "${HOME:-/nonexistent}") die "refusing to use '$WORK' as a work directory" ;;
esac
# The signing macro interpolates this path into a command line rpm re-splits on
# whitespace, so a space here would break signing in a confusing way.
case "$WORK" in
  *[[:space:]]*) die "refusing to use '$WORK': the path contains whitespace" ;;
esac
# Ask about the parent, which is guaranteed to exist — $WORK may not yet, and
# `git -C` on a missing directory just fails, which would skip the check.
if git -C "$(dirname "$WORK")" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "refusing to use '$WORK': it is inside a git working tree"
fi
if [ -n "$(ls -A "$WORK" 2>/dev/null)" ] && [ ! -e "$WORK/$MARKER" ]; then
  die "refusing to wipe non-empty '$WORK': this script did not create it"
fi
mkdir -p "$WORK"
# backup/ and signed/ survive a re-run. backup/ is the only copy of the original
# bytes once an upload has replaced them, and signed/ is the only copy of a
# package whose delete succeeded and whose upload did not. Wiping either would
# turn a retry into data loss.
# .rpmmacros.saved survives too: a run killed with SIGKILL leaves the operator's
# original only there, and wiping it before re-saving would replace it with this
# script's own generated file.
find "$WORK" -mindepth 1 -maxdepth 1 \
     ! -name backup ! -name signed ! -name "$MARKER" ! -name .rpmmacros.saved \
     -exec rm -rf {} + 2>/dev/null || true
touch "$WORK/$MARKER"
mkdir -p "$WORK"/{backup,signed}
cd "$WORK"

for tool in curl python3 gh; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done

# browser_download_url is fetched with curl and costs no API request, unlike
# `gh release download` which spends one per asset.
enumerate() {  # enumerate <output-file>
  gh api "repos/$REPO/releases" --paginate \
    -q '.[] | select(.draft == false) | select(.tag_name | startswith("v"))
        | .tag_name as $t | .assets[] | select(.state == "uploaded")
        | "\($t)\t\(.name)\t\(.size)\t\(.browser_download_url)"' \
    | awk -F'\t' '$2 ~ /\.rpm$/' | sort -u > "$1"
}

# Upload one release's worth of assets, retrying: the delete has already
# happened by the time an upload fails, so giving up early loses the package.
upload_tag() {  # upload_tag <tag> <file>...
  local tag="$1"; shift
  local delay ok=0
  # shellcheck disable=SC2086
  for delay in $UPLOAD_BACKOFF; do
    if [ "$delay" != 0 ]; then
      echo "      waiting ${delay}s before retrying $tag"
      sleep "$delay"
    fi
    # --clobber deletes the existing asset first, and tolerates its absence on a
    # retry where the delete already happened.
    if gh release upload "$tag" "$@" --clobber --repo "$REPO" >upload.log 2>&1 </dev/null; then
      ok=1; break
    fi
    sed 's/^/      /' upload.log
  done
  [ "$ok" = 1 ]
}

# ---------------------------------------------------------------- restore mode

if [ "$RESTORE" = 1 ]; then
  say "restore the backed-up originals"
  [ -s backup/manifest.tsv ] || die "no backup manifest under $WORK/backup — nothing to restore"
  # ONLY_TAGS narrows a restore to the releases that actually lost a package, so
  # recovering from a part-finished run does not also revert every release it
  # had already replaced.
  cp backup/manifest.tsv restore-manifest.tsv
  if [ -n "$ONLY_TAGS" ]; then
    set -f
    # shellcheck disable=SC2086
    printf '%s\n' $ONLY_TAGS | LC_ALL=C sort -u > wanted.txt
    set +f
    awk -F'\t' 'NR==FNR{w[$1];next} $1 in w' wanted.txt restore-manifest.tsv > filtered.tsv
    mv filtered.tsv restore-manifest.tsv
    [ -s restore-manifest.tsv ] \
      || die "the manifest holds nothing for tag(s): $ONLY_TAGS"
    echo "  limited to: $ONLY_TAGS"
  fi
  bad=0
  while IFS=$'\t' read -r tag name size sha; do
    f="backup/$tag/$name"
    [ -f "$f" ] || { echo "  MISSING $tag/$name" >&2; bad=$((bad+1)); continue; }
    [ "$(stat -c%s "$f")" = "$size" ] || { echo "  WRONG SIZE $tag/$name" >&2; bad=$((bad+1)); continue; }
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$sha" ] \
      || { echo "  WRONG CHECKSUM $tag/$name" >&2; bad=$((bad+1)); }
  done < restore-manifest.tsv
  [ "$bad" = 0 ] || die "$bad backup file(s) do not match the manifest — refusing to restore from them"
  echo "  $(wc -l < restore-manifest.tsv) file(s) verified against the manifest"
  if [ "$PUBLISH" != 1 ]; then
    say "dry run — nothing uploaded"
    echo "  re-run with RESTORE=1 PUBLISH=1 to put them back"
    exit 0
  fi
  cut -f1 restore-manifest.tsv | LC_ALL=C sort -u > restore-tags.txt
  while read -r tag; do
    mapfile -t paths < <(awk -F'\t' -v t="$tag" '$1 == t {print "backup/" $1 "/" $2}' restore-manifest.tsv)
    echo "  $tag"
    upload_tag "$tag" "${paths[@]}" || die "could not restore the assets of $tag"
    [ "$UPLOAD_PACE" = 0 ] || sleep "$UPLOAD_PACE"
  done < restore-tags.txt
  say "restored"
  echo "  rebuild the package repositories now"
  exit 0
fi

# ---------------------------------------------------------------- signing setup

command -v rpmsign >/dev/null || die "rpmsign is not installed (Ubuntu's rpm package omits signing support — see the header of this script for a container command)"

say "configure rpm signing"
# rpm shells out to gpg, which cannot prompt here, so the passphrase goes in a
# file. The macros go in ~/.rpmmacros, so an existing one is moved aside; the
# trap restores it and removes the passphrase however this exits.
PASSFILE="$WORK/.passphrase"
RPMMACROS="$HOME/.rpmmacros"
SAVED_MACROS="$WORK/.rpmmacros.saved"
# rpm >= 4.18 reads $XDG_CONFIG_HOME/rpm/macros in preference to ~/.rpmmacros
# and falls back only when that directory does not exist. If it ever does, the
# macros below are ignored, gpg is left with no passphrase and no pinentry, and
# every package fails to sign for a reason nothing here would report. Refuse
# rather than sign nothing quietly.
XDG_RPM="${XDG_CONFIG_HOME:-$HOME/.config}/rpm"
if [ -d "$XDG_RPM" ]; then
  die "'$XDG_RPM' exists, so rpm would read its macros in preference to $RPMMACROS"
fi
cleanup() {
  rm -f "$PASSFILE"
  if [ -e "$SAVED_MACROS" ]; then
    mv -f "$SAVED_MACROS" "$RPMMACROS"
  else
    rm -f "$RPMMACROS"
  fi
}
# Save before arming the trap: armed first, an early exit here would delete an
# existing ~/.rpmmacros that had not been copied anywhere yet. Not when a saved
# copy already exists, and not when the file in place is one of ours: after a
# run that died without its trap either would mean adopting this script's own
# generated macros as the operator's, and the trap would then install them
# permanently — pointing at a passphrase file that no longer exists.
MACRO_SENTINEL="# generated by resign-release-rpms.sh — safe to delete"
if [ -e "$RPMMACROS" ] && [ ! -e "$SAVED_MACROS" ] \
   && ! grep -qF "$MACRO_SENTINEL" "$RPMMACROS"; then
  cp -p "$RPMMACROS" "$SAVED_MACROS"
fi
trap cleanup EXIT
install -m 600 /dev/null "$PASSFILE"
printf '%s' "${GPG_PASSPHRASE:-}" > "$PASSFILE"
# Only the passphrase is added; rpm's own signing command is left alone. It has
# to be, because its shape is version-specific: rpm 6 made %__gpg_sign_cmd
# parametric, stopped repeating gpg as argv[0], dropped __plaintext_filename, and
# reads the identity from %_openpgp_sign_id rather than %_gpg_name. Replacing it
# works on one generation and fails on the other. Both generations interpolate
# %_gpg_sign_cmd_extra_args.
#
# Both identity macros are set because which one is read depends on the version;
# the unused one is inert. SHA-256 matches what nfpm produces for new packages.
cat > "$RPMMACROS" <<EOF
$MACRO_SENTINEL
%_gpg_name $KEY
%_openpgp_sign_id $KEY
%_gpg_digest_algo sha256
%_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file $PASSFILE
EOF
echo "  key $KEY, sha256 digests"

# ---------------------------------------------------------------- enumerate

say "enumerate published rpms"
enumerate assets.tsv

if [ -n "$ONLY_TAGS" ]; then
  # Tags are matched exactly, not as patterns. -f keeps the shell from expanding
  # anything glob-like in the input against the work directory.
  set -f
  # shellcheck disable=SC2086
  printf '%s\n' $ONLY_TAGS | LC_ALL=C sort -u > wanted.txt
  set +f
  awk -F'\t' 'NR==FNR{w[$1];next} $1 in w' wanted.txt assets.tsv > filtered.tsv
  mv filtered.tsv assets.tsv
  cut -f1 assets.tsv | LC_ALL=C sort -u > matched.txt
  # A typo in a tag would otherwise silently narrow the run to nothing.
  unmatched=$(LC_ALL=C comm -23 wanted.txt matched.txt | tr '\n' ' ')
  [ -z "${unmatched// /}" ] || die "no rpm assets found for tag(s): $unmatched"
  echo "  limited to: $ONLY_TAGS"
fi

total=$(wc -l < assets.tsv)
[ "$total" -gt 0 ] || die "no rpm assets found — refusing to report success over an empty set"
echo "  $total rpm asset(s) across $(cut -f1 assets.tsv | sort -u | wc -l) release(s)"

# ---------------------------------------------------------------- back up

say "fetch what each release currently serves"
# Kept apart from backup/: this is refetched every run and is what gets signed,
# so the skip test below asks whether the *published* package is signed rather
# than whether the backed-up original was.
while IFS=$'\t' read -r tag name size url; do
  mkdir -p "current/$tag"
  dst="current/$tag/$name"
  curl -fsSL --retry 3 --retry-delay 2 \
       --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
       -o "$dst" "$url" || die "could not download $tag/$name"
  # A short read would otherwise be signed and uploaded over the intact original.
  got=$(stat -c%s "$dst")
  [ "$got" = "$size" ] || die "$tag/$name downloaded as $got bytes, expected $size"
done < assets.tsv
echo "  $(wc -l < assets.tsv) file(s) fetched"

say "back up every published rpm"
# Recorded before anything is signed and long before anything is uploaded. Once
# an asset has been replaced this is the only copy of the original bytes.
#
# Merged, never rebuilt from the current listing. Two things would otherwise be
# lost on a second run: a package a failed replacement deleted is no longer
# enumerated at all, and it is exactly the one that exists nowhere else; and a
# package already replaced now serves *signed* bytes, which fetching over the
# backup would record as though they were the original.
touch backup/manifest.tsv
cp backup/manifest.tsv manifest.prev
: > manifest.new
while IFS=$'\t' read -r tag name size url; do
  mkdir -p "backup/$tag"
  dst="backup/$tag/$name"
  recorded=$(awk -F'\t' -v t="$tag" -v n="$name" '$1 == t && $2 == n {print $4; exit}' manifest.prev)
  if [ -n "$recorded" ] && [ -f "$dst" ] \
     && [ "$(sha256sum "$dst" | awk '{print $1}')" = "$recorded" ]; then
    # Already held, and the bytes still match what was recorded. Left untouched.
    awk -F'\t' -v t="$tag" -v n="$name" '$1 == t && $2 == n {print; exit}' manifest.prev >> manifest.new
    continue
  fi
  cp -- "current/$tag/$name" "$dst"
  printf '%s\t%s\t%s\t%s\n' "$tag" "$name" "$(stat -c%s "$dst")" \
         "$(sha256sum "$dst" | awk '{print $1}')" >> manifest.new
done < assets.tsv

# Carry forward rows whose asset is no longer on its release. A previous run
# deleted it and did not put it back, so this copy is the only one left and
# restoring it is the whole point of the manifest.
: > manifest.readd
while IFS=$'\t' read -r tag name size sha; do
  if awk -F'\t' -v t="$tag" -v n="$name" '$1 == t && $2 == n {f=1} END {exit !f}' manifest.new; then
    continue
  fi
  if [ -f "backup/$tag/$name" ]; then
    printf '%s\t%s\t%s\t%s\n' "$tag" "$name" "$size" "$sha" >> manifest.readd
  else
    die "backup/manifest.tsv records $tag/$name, but neither the release nor
       $WORK/backup/$tag holds it — refusing to continue with a manifest that
       cannot be restored from."
  fi
done < manifest.prev
if [ -s manifest.readd ]; then
  cat manifest.readd >> manifest.new
fi
mv manifest.new backup/manifest.tsv
rm -f manifest.prev
echo "  $(wc -l < backup/manifest.tsv) file(s) in $WORK/backup, checksummed in backup/manifest.tsv"
echo "  restore them at any time with: RESTORE=1 PUBLISH=1 $0 $WORK"

# A package that is backed up but no longer on its release was deleted by the
# upload half of an earlier replacement. It exists nowhere else, so putting it
# back comes before anything else this script could do -- and carrying on to
# sign the rest would end in a tidy "nothing to do" over a release with no
# package on it.
if [ -s manifest.readd ]; then
  gone_tags=$(cut -f1 manifest.readd | LC_ALL=C sort -u | tr '\n' ' ')
  echo "  MISSING FROM THEIR RELEASE:" >&2
  cut -f1,2 manifest.readd | sed 's|^|    |;s|\t|/|' >&2
  rm -f manifest.readd
  die "the package(s) listed above are in $WORK/backup but not on their release.
       Put them back first:

         RESTORE=1 PUBLISH=1 ONLY_TAGS='${gone_tags% }' $0 $WORK

       then run this again, and rebuild the package repositories afterwards."
fi
rm -f manifest.readd

# ---------------------------------------------------------------- sign

say "sign and verify"
signed=0; skipped=0; failed=0
: > failures.txt
: > to-upload.txt

while IFS=$'\t' read -r tag name size url; do
  mkdir -p "signed/$tag"
  # The published bytes, not the backed-up original: after a partial run the two
  # differ for every release already replaced, and asking the original whether
  # it is signed would re-sign and re-upload all of them.
  src="current/$tag/$name"
  dst="signed/$tag/$name"

  # Already signed by *this* key: nothing to do. Asking whose signature it is,
  # rather than whether there is one, is what makes a key rotation resumable:
  # after a rotation every package still carries the retired key's signature,
  # and a presence-only test would report nothing left to do while none verify.
  if [ "$FORCE" != 1 ] \
     && python3 "$SCRIPTS/check-rpm-signature.py" --key "$KEY_IDS" "$src" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi

  cp -- "$src" "$dst"
  # --resign, not --addsign: rpm 6 refuses to add a second header signature and
  # only deletes the existing one under --resign, which is what re-signing after
  # a key rotation needs. rpm 4 treats the two as identical.
  # </dev/null: this loop reads assets.tsv on stdin, and rpm 6 hands the
  # plaintext to gpg on *its* stdin, so anything that reads from ours would
  # swallow the rest of the work list.
  if ! rpmsign --resign "$dst" >sign.log 2>&1 </dev/null; then
    failed=$((failed + 1))
    { echo "$tag/$name: rpmsign failed"; sed 's/^/    /' sign.log; } >> failures.txt
    continue
  fi

  # rpmsign exits 0 when it has changed nothing: it skips a package that already
  # carries an identical signature, and it cannot distinguish that from a signing
  # backend that produced none. Check the bytes rather than the exit status.
  if ! python3 "$SCRIPTS/check-rpm-signature.py" --key "$KEY_IDS" "$dst" >/dev/null 2>&1; then
    failed=$((failed + 1))
    echo "$tag/$name: rpmsign exited 0 but the package is not signed by $KEY_IDS" >> failures.txt
    continue
  fi

  # The signature header is the only part allowed to differ. Anything else means
  # the package contents changed, and this is the last moment it can be caught:
  # the upload overwrites the original.
  if ! python3 - "$src" "$dst" <<'PY'
import struct, sys

def body_offset(blob):
    """Offset of the main header: past the lead and the signature header,
    whose data store is padded to an 8-byte boundary."""
    count, size = struct.unpack(">II", blob[104:112])
    end = 112 + 16 * count + size
    return end + (-end % 8)

a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
oa, ob = body_offset(a), body_offset(b)
if b[ob:ob + 3] != b"\x8e\xad\xe8":
    sys.exit("signed package has no main header where one is expected")
sys.exit(0 if a[oa:] == b[ob:] else "main header or payload changed")
PY
  then
    failed=$((failed + 1))
    echo "$tag/$name: content changed during signing" >> failures.txt
    continue
  fi

  printf '%s\t%s\t%s\n' "$tag" "$name" "$dst" >> to-upload.txt
  signed=$((signed + 1))
done < assets.tsv

echo "  signed $signed, already signed $skipped, failed $failed"
# Every asset must have been accounted for. Without this, anything that ends the
# loop early — a command that consumes the work list on stdin, say — reports a
# tidy summary over a fraction of the packages and exits 0.
if [ $((signed + skipped + failed)) -ne "$total" ]; then
  die "only $((signed + skipped + failed)) of $total asset(s) were processed — refusing to report on a partial pass"
fi
if [ "$failed" -gt 0 ]; then
  sed 's/^/    /' failures.txt
  die "$failed package(s) could not be signed — nothing has been uploaded"
fi

if [ ! -s to-upload.txt ]; then
  say "nothing to do"
  echo "  every published rpm is already signed by $KEY_IDS"
  echo "  if an earlier backfill's rebuild did not finish, the published repodata"
  echo "  still records pre-signing checksums — run rebuild-package-repos.sh"
  exit 0
fi

if [ "$PUBLISH" != 1 ]; then
  say "dry run — nothing uploaded"
  echo "  $signed re-signed package(s) are under $WORK/signed"
  echo "  re-run with PUBLISH=1 to replace the published assets"
  exit 0
fi

# ---------------------------------------------------------------- publish

# Re-verify the backup immediately before the first delete. Everything below
# destroys the published copy, and this is the last point at which the claim
# "the originals are recoverable" can still be checked.
say "re-verify the backup before replacing anything"
bad=0
while IFS=$'\t' read -r tag name size sha; do
  f="backup/$tag/$name"
  if [ ! -f "$f" ] || [ "$(stat -c%s "$f")" != "$size" ] \
     || [ "$(sha256sum "$f" | awk '{print $1}')" != "$sha" ]; then
    echo "  BAD $tag/$name" >&2; bad=$((bad+1))
  fi
done < backup/manifest.tsv
[ "$bad" = 0 ] || die "$bad backup file(s) do not match the manifest — refusing to replace published assets without a good backup"
echo "  $(wc -l < backup/manifest.tsv) original(s) verified"

say "upload"
# Assets are replaced a release at a time: one release lookup covers all of its
# assets, and stopping between releases never leaves a half-replaced one. Newest
# first, so the version `dnf install proxmox-sleep` resolves to is fixed first.
cut -f1 to-upload.txt | LC_ALL=C sort -u | sort -rV > upload-tags.txt
uploaded=0
tags_total=$(wc -l < upload-tags.txt)
tags_done=0
while read -r tag; do
  mapfile -t paths < <(awk -F'\t' -v t="$tag" '$1 == t {print $3}' to-upload.txt)
  echo "  [$((tags_done + 1))/$tags_total] $tag"
  upload_tag "$tag" "${paths[@]}" \
    || die "could not replace the assets of $tag — its rpms are probably now MISSING from that release.
       Put the originals back with: RESTORE=1 PUBLISH=1 ONLY_TAGS='$tag' $0 $WORK
       or upload the signed copies from $WORK/signed/$tag by hand."
  uploaded=$((uploaded + ${#paths[@]}))
  tags_done=$((tags_done + 1))
  [ "$UPLOAD_PACE" = 0 ] || sleep "$UPLOAD_PACE"
done < upload-tags.txt

[ "$tags_done" = "$tags_total" ] \
  || die "only $tags_done of $tags_total release(s) were uploaded — refusing to report success"

say "confirm every replacement is present"
# One more enumeration, not one request per asset. Sizes, not just names:
# --clobber replaces in place, so the name is there whether or not the
# replacement happened.
#
# The releases API is eventually consistent — an asset uploaded seconds ago can
# be absent or still 'uploading' in the next listing. Reporting that as a lost
# package would fail the run and, worse, skip the repository rebuild that the
# assets already replaced now need. Re-read a few times before believing it.
missing=0
for attempt in 1 2 3 4 5; do
  enumerate after.tsv
  missing=0
  : > mismatches.txt
  while IFS=$'\t' read -r tag name path; do
    want=$(stat -c%s "$path")
    got=$(awk -F'\t' -v t="$tag" -v n="$name" '$1 == t && $2 == n {print $3; exit}' after.tsv)
    if [ -z "$got" ]; then
      echo "  MISSING $tag/$name" >> mismatches.txt
      missing=$((missing + 1))
    elif [ "$got" != "$want" ]; then
      echo "  WRONG SIZE $tag/$name: published $got, signed copy is $want" >> mismatches.txt
      missing=$((missing + 1))
    fi
  done < to-upload.txt
  [ "$missing" -eq 0 ] && break
  if [ "$attempt" != 5 ]; then
    echo "  $missing not visible yet; re-reading (attempt $attempt)"
    sleep "${VERIFY_RETRY_DELAY:-10}"
  fi
done
if [ "$missing" -ne 0 ]; then
  cat mismatches.txt
  die "$missing replaced asset(s) are missing or do not match on their release.
       The signed copies are under $WORK/signed and the originals under
       $WORK/backup — put one set back, then rebuild the package repositories."
fi
echo "  all $uploaded replacement(s) present at the expected size"

say "done"
echo "  replaced $uploaded published rpm(s)"
echo "  the originals are still in $WORK/backup — keep it until the repositories"
echo "  have been rebuilt and a real dnf install has been tried"
echo "  the YUM repodata still records the old checksums —"
echo "  run rebuild-package-repos.sh now"
