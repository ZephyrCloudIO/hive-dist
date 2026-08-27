# Install, verify, update, uninstall — hive fleet

One page for every platform. Pick your row, paste the command.

| Platform | Installer | Where binaries land |
|---|---|---|
| macOS (Apple Silicon) | `install.sh` — auto-detects `mac-arm64` | `~/.local/bin` |
| macOS (Intel) | `install.sh` — auto-detects `mac-x64` | `~/.local/bin` |
| Linux / WSL / Git Bash | `install.sh` — auto-detects | `~/.local/bin` |
| Windows (native) | `install.ps1` (PowerShell) | `%LOCALAPPDATA%\Programs\hive\bin` |
| macOS / Linux (Homebrew) | `brew install hive` from this tap | Homebrew prefix |

Every install verifies the archive's SHA-256 against the release's
`sha256sums.txt` **before** a single downloaded byte is executed. A digest
mismatch deletes the download and exits non-zero — that digest is the whole
trust anchor.

## Install

### macOS (either chip) and Linux — one command

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh | sh
```

Auto-detects your platform, installs five binaries (`hive-daemon`,
`hive-updater`, `hive-iroh-peer`, `hive-iroh-bench`, `model-host`) into
`~/.local/bin`, and tells you if that directory is not on your `PATH`.

Pin a version or change the destination:

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh \
  | VERSION=v0.1.5 INSTALL_DIR=/usr/local/bin sh
```

### Windows — one command (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\Programs\hive\bin` and adds it to your user
`Path` automatically (open a new terminal to pick it up). To pin a version
or change the destination, download the script first and pass parameters:

```powershell
.\install.ps1 -Version v0.1.5 -InstallDir C:\tools\hive\bin
```

### Homebrew (macOS / Linux)

```sh
brew tap ZephyrCloudIO/hive-dist https://github.com/ZephyrCloudIO/hive-dist
brew install hive
```

## Verify the install — one command

Re-computes every installed binary's SHA-256 against the release manifest
and runs each binary's `--version`. `OK` lines plus exit 0 means the bytes
on disk are exactly what the release published.

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.sh | sh
```

Windows:

```powershell
irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.ps1 | iex
```

## Check that peers see each other

The fleet's endpoints run with global discovery **off** — two peers find
each other through the pairing file (static trust + addressing), never
through a public lookup service. The check below proves the full path:
identity minting, the trust gate accepting a handshake, a connection, and
real bytes moving.

### On one machine (loopback, ~30 seconds)

macOS / Linux:

```sh
mkdir -p /tmp/hive-check && cd /tmp/hive-check

# Mint two identities; each prints its own [[peer]] pairing block
hive-iroh-peer --state-dir id-a --name peer-a --mint-only --bind 127.0.0.1:4101 | grep -v '^iroh-peer' > peer-a.toml
hive-iroh-peer --state-dir id-b --name client --mint-only | grep -v '^iroh-peer' > client.toml

# Cross-pair: each side's trust file names the other
cp client.toml for-peer-a.toml
cp peer-a.toml for-client.toml

# Serve peer-a in the background
hive-iroh-peer --state-dir id-a --pairing for-peer-a.toml --name peer-a --bind 127.0.0.1:4101 &
sleep 1

# The client dials peer-a and moves 1 MiB each way
hive-iroh-bench --state-dir id-b --pairing for-client.toml --peer peer-a --mode check --bytes 1048576 --connects 3

kill %1
```

Windows (PowerShell):

```powershell
mkdir $env:TEMP\hive-check -Force | Out-Null; cd $env:TEMP\hive-check

hive-iroh-peer --state-dir id-a --name peer-a --mint-only --bind 127.0.0.1:4101 | ? { $_ -notmatch '^iroh-peer' } | Set-Content peer-a.toml
hive-iroh-peer --state-dir id-b --name client --mint-only | ? { $_ -notmatch '^iroh-peer' } | Set-Content client.toml

Copy-Item client.toml for-peer-a.toml
Copy-Item peer-a.toml for-client.toml

$peer = Start-Process hive-iroh-peer -PassThru -NoNewWindow -RedirectStandardOutput peer-a.log `
  -ArgumentList '--state-dir','id-a','--pairing','for-peer-a.toml','--name','peer-a','--bind','127.0.0.1:4101'
Start-Sleep 2

hive-iroh-bench --state-dir id-b --pairing for-client.toml --peer peer-a --mode check --bytes 1048576 --connects 3

Stop-Process -Id $peer.Id -Force
```

**What success looks like** — the bench prints one line and exits 0:

```
iroh-bench[check]: up 157.07 MB/s, down 270.88 MB/s (1048576 bytes each way), connect p50 0.6 ms over 3 samples, paths ["ip:127.0.0.1:4101"]
```

The `paths ["ip:127.0.0.1:4101"]` field is the proof: it is read from the
live QUIC connection, so the two installed binaries genuinely found each
other, passed the trust gate, and moved bytes. A peer the pairing file
does not name is refused with zero bytes exchanged — that is the gate
working, not a failure.

### Across two machines (LAN)

Same flow with two changes:

1. The serving machine binds its LAN interface instead of loopback:
   `--bind 0.0.0.0:4101`.
2. The dialing machine's pairing file lists the server's real address:
   `direct_addrs = ["192.168.1.20:4101"]` (the server's LAN IP) in its
   `[[peer]]` block.

Each machine still only trusts the identities named in its own pairing
file — swap the `--mint-only` blocks between machines the same way as
above.

## Update — one command

Re-run the installer. It resolves the latest release, verifies the digest,
and overwrites the binaries in place.

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.sh | sh
```

Windows:

```powershell
irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.ps1 | iex
```

Homebrew:

```sh
brew upgrade hive
```

## Uninstall — one command

macOS / Linux (default install dir):

```sh
rm -f ~/.local/bin/hive-daemon ~/.local/bin/hive-updater ~/.local/bin/hive-iroh-peer ~/.local/bin/hive-iroh-bench ~/.local/bin/model-host
```

(If you installed with `INSTALL_DIR=/usr/local/bin`, use that path with
`sudo` instead.)

Windows:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\hive"
```

Optionally also drop the install dir from your user `Path`:

```powershell
[Environment]::SetEnvironmentVariable('Path', (([Environment]::GetEnvironmentVariable('Path','User') -split ';' | ? { $_ -notlike '*\Programs\hive\bin' }) -join ';'), 'User')
```

Homebrew:

```sh
brew uninstall hive && brew untap ZephyrCloudIO/hive-dist
```

State directories (`--state-dir` you chose for peers or the daemon) are
not touched by any of the above; delete them separately if you created
any.
