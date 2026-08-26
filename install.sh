#!/bin/sh
# install.sh — hive-fleet POSIX installer.
#
# Downloads the fleet-member binaries for the detected platform from the
# latest (or a pinned) GitHub Release of the distribution repo, verifies the
# archive's SHA-256 against the release's sha256sums.txt manifest, and
# installs the binaries into INSTALL_DIR (default ~/.local/bin).
#
# Trust model: the digest in the release manifest is the ONLY trust anchor —
# there is no code signing. This script refuses to install anything whose
# digest does not match the manifest, and it never executes downloaded bytes
# before that check passes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh | sh
#   curl -fsSL ... | VERSION=v0.1.3 INSTALL_DIR=/usr/local/bin sh
#
# Environment:
#   TARGET_REPO  baked at publish time (ZephyrCloudIO/hive-dist); override for forks
#   VERSION      release tag to install, or "latest" (default)
#   INSTALL_DIR  destination directory (default "$HOME/.local/bin")

set -eu
# pipefail where the shell supports it (bash/ksh/zsh as sh); POSIX sh ignores it.
# The subshell probe is the portable way to detect support — SC3040's "POSIX sh
# has no pipefail" is exactly what the probe guards against.
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

TARGET_REPO="${TARGET_REPO:-ZephyrCloudIO/hive-dist}"
VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# The fleet-member binaries every release ships. Baked at publish time; the
# rail's dist-scripts template keeps this list in one place.
BINARIES="hive-daemon hive-updater hive-iroh-peer hive-iroh-bench model-host"

die() {
  printf 'install: error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'install: %s\n' "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# --- platform detection -------------------------------------------------------
# One of: mac-arm64, mac-x64, linux-x64, linux-arm64, windows-x64.
# windows-x64 covers WSL and Git Bash / MSYS2, where uname reports Linux-ish
# or MINGW/MSYS strings; the native Windows path is install.ps1.
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
      # WSL reports Linux; the Linux binary runs there natively.
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
      die "unsupported operating system: $os (use install.ps1 on native Windows)"
      ;;
  esac
}

# --- sha256 helper ------------------------------------------------------------
# Linux ships sha256sum; stock macOS ships shasum. Use whichever exists.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool found (need sha256sum or shasum)"
  fi
}

# --- main ---------------------------------------------------------------------
need curl
need uname
need awk
need tar

PLATFORM="$(detect_platform)"
info "platform: $PLATFORM"
info "target repo: $TARGET_REPO"

if [ "$VERSION" = "latest" ]; then
  RELEASE_API="https://api.github.com/repos/$TARGET_REPO/releases/latest"
  RELEASE_BASE="https://github.com/$TARGET_REPO/releases/latest/download"
else
  RELEASE_API="https://api.github.com/repos/$TARGET_REPO/releases/tags/$VERSION"
  RELEASE_BASE="https://github.com/$TARGET_REPO/releases/download/$VERSION"
fi

# Resolve the real tag for clear messages (and so 'latest' pins to a name).
TAG="$(curl -fsSL "$RELEASE_API" | awk -F'"' '/"tag_name"/ {print $4; exit}')" \
  || die "could not resolve release ($VERSION) for $TARGET_REPO"
[ -n "$TAG" ] || die "empty tag_name in release response for $TARGET_REPO ($VERSION)"
info "release: $TAG"

case "$PLATFORM" in
  windows-x64) ARCHIVE="hive-fleet-$PLATFORM.zip" ;;
  *)           ARCHIVE="hive-fleet-$PLATFORM.tar.gz" ;;
esac

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t hive-fleet)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

info "downloading $ARCHIVE"
curl -fsSL "$RELEASE_BASE/$ARCHIVE" -o "$WORKDIR/$ARCHIVE" \
  || die "download failed: $RELEASE_BASE/$ARCHIVE"

info "downloading sha256sums.txt"
curl -fsSL "$RELEASE_BASE/sha256sums.txt" -o "$WORKDIR/sha256sums.txt" \
  || die "download failed: $RELEASE_BASE/sha256sums.txt (release $TAG has no manifest?)"

# --- digest verification (the trust anchor) -----------------------------------
EXPECTED="$(awk -v f="$ARCHIVE" '$2 == f {print $1; exit}' "$WORKDIR/sha256sums.txt")"
[ -n "$EXPECTED" ] || die "$ARCHIVE not listed in sha256sums.txt for release $TAG"

ACTUAL="$(sha256_of "$WORKDIR/$ARCHIVE")"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  printf 'install: error: DIGEST MISMATCH for %s\n' "$ARCHIVE" >&2
  printf '  expected (manifest): %s\n' "$EXPECTED" >&2
  printf '  actual   (download): %s\n' "$ACTUAL" >&2
  die "refusing to install — the download is not what release $TAG published"
fi
info "digest verified: $ACTUAL"

# --- unpack -------------------------------------------------------------------
case "$ARCHIVE" in
  *.tar.gz)
    tar -xzf "$WORKDIR/$ARCHIVE" -C "$WORKDIR" \
      || die "failed to unpack $ARCHIVE"
    ;;
  *.zip)
    need unzip
    unzip -q "$WORKDIR/$ARCHIVE" -d "$WORKDIR/unpacked" \
      || die "failed to unpack $ARCHIVE"
    ;;
esac

# --- install ------------------------------------------------------------------
SUDO=""
if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR" 2>/dev/null || SUDO="sudo"
fi
if [ ! -w "$INSTALL_DIR" ] && [ -z "$SUDO" ]; then
  if [ "$INSTALL_DIR" = "/usr/local/bin" ]; then
    SUDO="sudo"
  else
    die "install dir $INSTALL_DIR is not writable (set INSTALL_DIR or run with sudo)"
  fi
fi
[ -z "$SUDO" ] || $SUDO mkdir -p "$INSTALL_DIR"

EXT=""
[ "$PLATFORM" = "windows-x64" ] && EXT=".exe"

for bin in $BINARIES; do
  src="$WORKDIR/$bin$EXT"
  [ -f "$src" ] || src="$WORKDIR/unpacked/$bin$EXT"
  [ -f "$src" ] || die "archive $ARCHIVE did not contain $bin$EXT"
  $SUDO install -m 0755 "$src" "$INSTALL_DIR/$bin$EXT" \
    || die "failed to install $bin$EXT into $INSTALL_DIR"
  info "installed $INSTALL_DIR/$bin$EXT"
done

case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *)
    printf 'install: note: %s is not on your PATH; add it, e.g.:\n' "$INSTALL_DIR" >&2
    # Single quotes are deliberate: the advice must print a literal $PATH.
    # shellcheck disable=SC2016
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR" >&2
    ;;
esac

info "done. Verify with: curl -fsSL https://raw.githubusercontent.com/$TARGET_REPO/main/validate.sh | sh"
