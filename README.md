# hive-fleet — distribution

This repository is **pure distribution** for the hive fleet-member binaries.
It contains no source code. What it holds:

- **GitHub Releases** carrying the built binaries for five platforms, plus a
  `sha256sums.txt` manifest per release.
- **Installer and validator scripts** (`install.sh`, `install.ps1`,
  `validate.sh`, `validate.ps1`) that download, verify, install, and re-verify
  those binaries.
- **`Formula/hive.rb.tmpl`** — the Homebrew formula template, baked per
  release into `Formula/hive.rb` wrapping the same release assets.

The binaries themselves are built and published by the `hive-dist` rail's
release machinery. Each release ships:

| Binary | Role |
|---|---|
| `hive-daemon` | the fleet-member daemon |
| `hive-updater` | the digest-pinned self-updater |
| `hive-iroh-peer` | the iroh peer endpoint |
| `hive-iroh-bench` | the iroh throughput/latency bench |
| `model-host` | the model-serving host |

Platforms: `mac-arm64`, `mac-x64`, `linux-x64`, `linux-arm64`, `windows-x64`.

## Trust model

Every release carries a `sha256sums.txt` manifest. The installers **never**
pipe bytes into your system without first re-computing the downloaded
archive's SHA-256 and comparing it against the manifest. There is no code
signing yet — the digest pinned in the release manifest is the whole trust
anchor, matching the updater's digest-pinned model. If the digest does not
match, the installer deletes the download and exits non-zero.

## Install

### macOS / Linux / WSL / Git Bash (POSIX)

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh | sh
```

The script auto-detects your platform, downloads the matching archive and
`sha256sums.txt` from the **latest** release, verifies the digest, and
installs the binaries into `~/.local/bin` (falling back to
`/usr/local/bin` via `sudo` when `~/.local/bin` is not writable and you ask
for a system install with `INSTALL_DIR=/usr/local/bin`).

Useful environment overrides:

| Variable | Default | Meaning |
|---|---|---|
| `INSTALL_DIR` | `~/.local/bin` | where the binaries land |
| `VERSION` | `latest` | a specific release tag, e.g. `v0.1.3` |

```sh
# pinned version, system-wide install
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh \
  | VERSION=v0.1.3 INSTALL_DIR=/usr/local/bin sh
```

### Windows (native, PowerShell)

```powershell
irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\Programs\hive\bin` and adds it to the user `Path`
if it is not already there. Override with `-InstallDir` / `-Version` when
sourcing the script file rather than piping it.

### Homebrew (macOS / Linux)

`Formula/hive.rb.tmpl` is the formula **template**. The release machinery
bakes it per release — substituting the version and the four per-platform
SHA-256 digests from that release's `sha256sums.txt` — and commits the baked
`Formula/hive.rb` to this repo, which then doubles as a Homebrew tap:

```sh
brew tap ZephyrCloudIO/hive-dist https://github.com/ZephyrCloudIO/hive-dist
brew install hive
```

Until the first release lands there is no baked `Formula/hive.rb` — the
template is the source of truth for what it will contain. The baked formula
downloads the same release asset and verifies the same SHA-256.

## Validate an installation

After installing, prove the on-disk bytes are the published bytes:

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.sh | sh
```

or on Windows:

```powershell
irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.ps1 | iex
```

The validator:

1. Re-computes the SHA-256 of every installed binary and compares it against
   the digest recorded in the release manifest for your platform.
2. Runs each binary's `--version` and requires exit 0.

Any mismatch or any binary that fails to run prints a loud diagnosis and
exits 1. Silence plus `OK` lines means the install is exactly what the
release published.

## Layout

```
README.md              this file
install.sh             POSIX installer (mac/linux/WSL/Git Bash)
install.ps1            native-Windows installer (PowerShell)
validate.sh            POSIX validator
validate.ps1           native-Windows validator
Formula/hive.rb.tmpl   Homebrew formula template (baked per release)
```

The install/validate scripts are baked with this repo as the default target;
`TARGET_REPO` (sh) / `-TargetRepo` (ps1) override it for forks. Everything
else lives in the releases: one archive per platform per release, plus
`sha256sums.txt`.
