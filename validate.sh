#!/bin/sh
# validate.sh — prove an installed hive-fleet copy is exactly what the
# release published.
#
# For every fleet-member binary in INSTALL_DIR:
#   1. re-compute its SHA-256 and compare it against the digest the release
#      manifest (sha256sums.txt) records for this platform's archive member,
#   2. run '<binary> --version' and require exit 0.
#
# Any mismatch or any failing binary prints a loud diagnosis and the script
# exits 1. All checks pass -> exit 0.
#
# The manifest records the digest of the ARCHIVE, so per-binary digests are
# taken from a freshly downloaded, manifest-verified copy of the archive —
# never from the network unverified, and never trusting the on-disk bytes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.sh | sh
#   INSTALL_DIR=/usr/local/bin sh validate.sh
#
# Environment:
#   TARGET_REPO  baked at publish time (ZephyrCloudIO/hive-dist); override for forks
#   VERSION      release tag to validate against, or "latest" (default)
#   INSTALL_DIR  where the binaries are installed (default "$HOME/.local/bin")

set -eu
# pipefail where the shell supports it (bash/ksh/zsh as sh); POSIX sh ignores it.
# The subshell probe is the portable way to detect support — SC3040's "POSIX sh
# has no pipefail" is exactly what the probe guards against.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

TARGET_REPO="${TARGET_REPO:-ZephyrCloudIO/hive-dist}"
VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Optional auth for the GitHub API: unauthenticated release resolution shares
# a 60/hour pool per egress IP, which shared CI runners exhaust. When the
# caller provides GITHUB_TOKEN (or GH_TOKEN), the API call below carries it;
# asset downloads from github.com do not need it for a public repo.
API_AUTH=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  API_AUTH="Authorization: Bearer $GITHUB_TOKEN"
elif [ -n "${GH_TOKEN:-}" ]; then
  API_AUTH="Authorization: Bearer $GH_TOKEN"
fi

api_get() {
  if [ -n "$API_AUTH" ]; then
    curl -fsSL -H "$API_AUTH" "$1"
  else
    curl -fsSL "$1"
  fi
}

BINARIES="hive-daemon hive-updater hive-iroh-peer hive-iroh-bench model-host"

die() {
  printf 'validate: error: %s\n' "$*" >&2
  exit 1
}

fail() {
  # a per-binary check failure: loud, counted, not immediately fatal so the
  # operator sees EVERY broken binary in one run.
  printf 'validate: FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  printf 'validate: OK: %s\n' "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

detect_platform() {
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "mac-arm64" ;;
        x86_64)        echo "mac-x64" ;;
        *) die "unsupported macOS architecture: $arch" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64|amd64)  echo "linux-x64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        *) die "unsupported Linux architecture: $arch" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      case "$arch" in
        x86_64|amd64) echo "windows-x64" ;;
        *) die "unsupported Windows (MSYS/MinGW) architecture: $arch" ;;
      esac
      ;;
    *)
      die "unsupported operating system: $os (use validate.ps1 on native Windows)"
      ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool found (need sha256sum or shasum)"
  fi
}

need curl
need uname
need awk
need tar

FAILURES=0
PLATFORM="$(detect_platform)"
EXT=""
[ "$PLATFORM" = "windows-x64" ] && EXT=".exe"

printf 'validate: platform: %s\n' "$PLATFORM"
printf 'validate: install dir: %s\n' "$INSTALL_DIR"
printf 'validate: target repo: %s\n' "$TARGET_REPO"

if [ "$VERSION" = "latest" ]; then
  RELEASE_API="https://api.github.com/repos/$TARGET_REPO/releases/latest"
  RELEASE_BASE="https://github.com/$TARGET_REPO/releases/latest/download"
else
  RELEASE_API="https://api.github.com/repos/$TARGET_REPO/releases/tags/$VERSION"
  RELEASE_BASE="https://github.com/$TARGET_REPO/releases/download/$VERSION"
fi

TAG="$(api_get "$RELEASE_API" | awk -F'"' '/"tag_name"/ {print $4; exit}')" \
  || die "could not resolve release ($VERSION) for $TARGET_REPO"
[ -n "$TAG" ] || die "empty tag_name in release response for $TARGET_REPO ($VERSION)"
printf 'validate: release: %s\n' "$TAG"

case "$PLATFORM" in
  windows-x64) ARCHIVE="hive-fleet-$PLATFORM.zip" ;;
  *)           ARCHIVE="hive-fleet-$PLATFORM.tar.gz" ;;
esac

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t hive-fleet-validate)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

curl -fsSL "$RELEASE_BASE/$ARCHIVE" -o "$WORKDIR/$ARCHIVE" \
  || die "download failed: $RELEASE_BASE/$ARCHIVE"
curl -fsSL "$RELEASE_BASE/sha256sums.txt" -o "$WORKDIR/sha256sums.txt" \
  || die "download failed: $RELEASE_BASE/sha256sums.txt"

# Verify the ARCHIVE against the manifest first — everything below trusts
# only bytes that passed this check.
EXPECTED_ARCHIVE="$(awk -v f="$ARCHIVE" '$2 == f {print $1; exit}' "$WORKDIR/sha256sums.txt")"
[ -n "$EXPECTED_ARCHIVE" ] || die "$ARCHIVE not listed in sha256sums.txt for release $TAG"
ACTUAL_ARCHIVE="$(sha256_of "$WORKDIR/$ARCHIVE")"
if [ "$ACTUAL_ARCHIVE" != "$EXPECTED_ARCHIVE" ]; then
  printf 'validate: error: DIGEST MISMATCH for reference archive %s\n' "$ARCHIVE" >&2
  printf '  expected (manifest): %s\n' "$EXPECTED_ARCHIVE" >&2
  printf '  actual   (download): %s\n' "$ACTUAL_ARCHIVE" >&2
  die "cannot validate — the published reference bytes do not match the manifest"
fi
printf 'validate: reference archive digest verified: %s\n' "$ACTUAL_ARCHIVE"

case "$ARCHIVE" in
  *.tar.gz) tar -xzf "$WORKDIR/$ARCHIVE" -C "$WORKDIR" || die "failed to unpack $ARCHIVE" ;;
  *.zip)
    need unzip
    unzip -q "$WORKDIR/$ARCHIVE" -d "$WORKDIR/ref" || die "failed to unpack $ARCHIVE"
    ;;
esac

for bin in $BINARIES; do
  installed="$INSTALL_DIR/$bin$EXT"
  ref="$WORKDIR/$bin$EXT"
  [ -f "$ref" ] || ref="$WORKDIR/ref/$bin$EXT"

  if [ ! -f "$installed" ]; then
    fail "$bin$EXT is not installed at $installed"
    continue
  fi
  if [ ! -f "$ref" ]; then
    fail "reference archive $ARCHIVE did not contain $bin$EXT"
    continue
  fi

  installed_digest="$(sha256_of "$installed")"
  ref_digest="$(sha256_of "$ref")"
  if [ "$installed_digest" != "$ref_digest" ]; then
    fail "$bin$EXT digest mismatch: on-disk $installed_digest != published $ref_digest"
  else
    ok "$bin$EXT digest matches release $TAG ($installed_digest)"
  fi

  if "$installed" --version >/dev/null 2>&1; then
    ok "$bin$EXT --version exits 0"
  else
    fail "$bin$EXT --version did not exit 0"
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  printf 'validate: %d check(s) FAILED — the install is NOT what release %s published\n' \
    "$FAILURES" "$TAG" >&2
  exit 1
fi

# Word-splitting of $BINARIES is intentional here: it is a fixed, baked list
# of bare binary names, and splitting is how we count them.
# shellcheck disable=SC2086
set -- $BINARIES
printf 'validate: all %s binaries verified against release %s\n' "$#" "$TAG"
