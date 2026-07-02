# Install Environments Reference

Deep-dive into every opencode-family install environment the detect/update
scripts handle. Use this when a row in the detect output is unclear, when an
update command fails, or when adding support for a new environment.

## Packages in scope

| Package | What it is |
|---|---|
| `opencode-ai` | The opencode CLI runtime (npm package; ships platform-specific binary via postinstall) |
| `oh-my-opencode` | Companion agent skills/automation bundle |
| `@opencode-ai/plugin` | Plugin SDK shipped inside `~/.opencode/package.json` plugin tree |

All three are independent npm packages with their own version cadence. The
`opencode upgrade` command only refreshes the standalone binary; it does NOT
touch the npm/pnpm/bun/vite-plus/volta global copies. Those need their native
package manager's update verb.

---

## Environments

### 1. Downloaded binary (curl install)

**Detection:**
- Linux/macOS: `~/.opencode/bin/opencode` (ELF/Mach-O)
- Windows: `~/.opencode/bin/opencode.exe`
- Reports version via `opencode --version`.

**Update command:**
```
opencode upgrade
```
- Auto-detects method; defaults to `curl` on Linux/macOS, `choco`/`scoop` on Windows.
- Supports `--method {curl,npm,pnpm,bun,brew,choco,scoop}` for explicit override.

**Gotchas:**
- This binary is NOT the same as the npm package's `bin/opencode` wrapper.
  The curl-installed binary is the standalone Go-compiled ELF.
- `~/.opencode/package.json` declares `@opencode-ai/plugin` separately.

---

### 2. Plugin tree (`~/.opencode/package.json`)

**Detection:**
- File: `~/.opencode/package.json` declares `@opencode-ai/plugin`.
- Installed copy: `~/.opencode/node_modules/@opencode-ai/plugin/package.json`.

**Update command:**
```bash
cd ~/.opencode && (bun install @opencode-ai/plugin@latest || npm install --save @opencode-ai/plugin@latest)
```
- Use bun if available (faster, matches the original install pattern); fall back to npm.
- This is separate from `opencode upgrade` — that handles the binary, not the plugin SDK.

---

### 3. npm global

**Detection:**
- `npm root -g` returns the global install root.
- Check for `<npm-root>/<pkg>/package.json` for each pkg.
- **Skip if path under `.vite-plus`** — vite-plus masquerades as npm global root.

**Update command:**
```
npm i -g <pkg>@latest
```

**Gotchas:**
- On vite-plus-managed systems, `npm i -g` may install into the vite-plus tree.
- npm v7+ may complain about `EBADENGINE`. Use Node >= 20.

---

### 4. pnpm global

**Detection:**
- `pnpm root -g` returns the global install root.
- Fallback dirs:
  - Linux/macOS: `~/.local/share/pnpm/global/node_modules/<pkg>/package.json`
  - Windows: `%LOCALAPPDATA%\pnpm\{.global,global,}\node_modules\<pkg>\package.json`

**Update command:**
```
pnpm add -g <pkg>@latest
```

**Gotchas:**
- Skip if `pnpm root -g` returns a `.vite-plus` path.

---

### 5. Bun global

Two patterns coexist:

**5a. Home-folder `~/package.json` pattern:**
- `~/package.json` declares `<pkg>` as a dep.
- Installed copy: `~/node_modules/<pkg>/package.json`.
- Update: `bun add -g <pkg>@latest`

**5b. Bun's global dir (`~/.bun/install/global`):**
- Update: `cd ~/.bun/install/global && bun install <pkg>@latest`

**Gotchas:**
- Bun caches every version under `~/.bun/install/cache/` — these are NOT installs.
- `trustedDependencies` in `~/package.json` must include `opencode-ai` for postinstall to run.

---

### 6. vite-plus packages

**Detection:**
- Path: `~/.vite-plus/packages/<pkg>/lib/node_modules/<pkg>/package.json`.

**Update command:**
```
vp install -g <pkg>@latest
```

**Gotchas:**
- vite-plus shims `npm`, `npx`, `pnpm`, `pnpx`, `node` via `~/.vite-plus/bin/`.
- Calling `npm i -g` on a vp-managed shell installs into the vp tree.

---

### 7. Volta

**Detection:**
- Path: `~/.volta/tools/image/packages/<pkg>/<version>/{lib/,}node_modules/<pkg>/package.json`.

**Update command:**
```
volta install <pkg>@latest
```

**Gotchas:**
- No shell-switch command for Node (Volta pins per-project).
- Volta shims `node`/`npm`/`npx` via `~/.volta/bin/`. PATH order matters.

---

### 8. nvm (POSIX)

**Detection:**
- Path: `$NVM_DIR/versions/node/v<ver>/lib/node_modules/<pkg>/package.json`.
- `$NVM_DIR` defaults to `~/.nvm`.

**Update command (per Node version):**
```bash
. "$NVM_DIR/nvm.sh" && nvm use <ver> && npm i -g <pkg>@latest
```

**Gotchas:**
- `nvm use` only affects the current shell. The script wraps it in `bash -c`.

---

### 9. nvm-windows

**Detection:**
- Path: `%APPDATA%\nv\node\<ver>\node_modules\<pkg>\package.json`.

**Update command:**
```
nvm use <ver> && npm i -g <pkg>@latest
```

**Gotchas:**
- Requires admin privileges to switch Node versions.

---

### 10. fnm

**Detection:**
- POSIX: `~/.fnm/node-versions/v<ver>/installation/lib/node_modules/<pkg>/package.json`
- macOS: `~/Library/Application Support/fnm/node-versions/...`
- Windows: `%LOCALAPPDATA%\fnm_multishells\<hash>\node_modules\<pkg>\package.json`

**Update command:**
```
fnm use <ver> && npm i -g <pkg>@latest
```

---

## Cross-environment invariants

1. **The binary at `~/.opencode/bin/opencode` always wins PATH** if it exists.
2. **vite-plus shims shadow npm-global** unless vite-plus is removed from PATH.
3. **Bun's `~/package.json` pattern** is fragile — any `bun add` in home mutates the global manifest.
4. **PATH shadowing** is the #1 cause of "I updated but `opencode --version` still shows old."
   - Fix: remove the stale binary or reorder PATH.
5. **Postinstall must run under a real Node.** If install scripts are skipped (`--ignore-scripts`, missing `trustedDependencies`), the binary won't be refreshed.
