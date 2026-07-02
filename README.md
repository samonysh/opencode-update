# opencode-update

> **Detect, plan, and update** opencode-family components (`opencode-ai`, `oh-my-opencode`, `@opencode-ai/plugin`) across all install environments — npm, pnpm, bun, vite-plus, volta, nvm, fnm, and standalone binary — on Linux, macOS, and Windows.

## Features

- **Cross-platform**: bash (Linux/macOS/WSL/Git Bash) and PowerShell (Windows 5.1+/pwsh 7+)
- **Multi-environment detection**: finds every opencode install on your system regardless of package manager
- **Dry-run by default**: see what would change before mutating anything
- **Native tool per environment**: never cross-upgrade (no `npm` on a `bun` install, no `pnpm` on a `volta` install)
- **PATH shadow analysis**: explains why `which opencode` might not point to the version you expect
- **Comprehensive reference**: docs covering every install environment's layout, update commands, and gotchas

## Quick Start

```bash
# Clone
git clone https://github.com/samonysh/opencode-update.git
cd opencode-update

# Detect — read-only scan of all opencode installs on this machine
bash scripts/detect-opencode.sh

# Update plan (dry-run) — show what would be updated
bash scripts/update-opencode.sh

# Apply updates
bash scripts/update-opencode.sh --apply
```

### Windows PowerShell

```powershell
.\scripts\detect-opencode.ps1
.\scripts\update-opencode.ps1          # dry-run
.\scripts\update-opencode.ps1 -Apply   # execute
```

## Output Tables

| Section | Content |
|---|---|
| A. Registry latest | Latest npm registry versions for each package |
| B. Installed copies | All local installs with env type, path, version, freshness status |
| C. Node managers | Detected Node version managers with available versions |
| D. CLI resolution | Which `opencode` binary PATH resolves to, and whether it's the latest |

Status values: `FRESH` ✓ | `STALE` ✗ | `AHEAD` (pre-release) | `UNKNOWN` | `MISSING`

## Packages Managed

| Package | Description |
|---|---|
| `opencode-ai` | Core opencode CLI runtime |
| `oh-my-opencode` | Companion agent skills/automation bundle |
| `@opencode-ai/plugin` | Plugin SDK for opencode extensions |

## Environments Detected

The scripts scan these install locations:

- `~/.opencode/bin/opencode` — standalone binary (curl install)
- `~/.opencode/package.json` — plugin SDK tree
- `npm root -g` — npm global install
- `pnpm root -g` — pnpm global install
- `bun add -g` — bun global install
- `~/.vite-plus/packages/` — vite-plus managed packages
- `~/.volta/tools/image/packages/` — Volta managed packages
- `$NVM_DIR/versions/node/` — nvm per-version globals
- `~/.fnm/` — fnm installations
- `%APPDATA%\nv\node\` — nvm-windows installations

## Reference

- [Install Environments](docs/install-environments.md) — deep dive into each environment's layout, update commands, and gotchas
- [Node Managers](docs/node-managers.md) — how each Node version manager is detected, switched, and used during updates

## License

MIT
