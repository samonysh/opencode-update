# Node Version Managers Reference

The update script's `pick_best_node` (bash) / `Get-BestNode` (PowerShell)
function walks every known Node manager, picks the highest installed Node
version, and returns a shell-switch command to activate it.

## Priority order

When multiple managers are present, the highest Node version wins regardless
of manager. Ties are broken by manager priority:

```
vite-plus > nvm > fnm > nvm-windows > volta > bun-runtime
```

(Bun runtime is excluded from node selection because Bun's embedded Node
isn't user-switchable.)

---

## vite-plus (vp)

**Layout:**
```
~/.vite-plus/
├── 0.1.23/  0.1.24/  0.2.1/         # vp versions
├── current -> 0.2.1/
├── bin/{node,npm,npx,pnpm,...}
├── js_runtime/node/v24.18.0/
└── packages/<pkg>/lib/node_modules/<pkg>/
```

**Switch command:**
```
vp env use <ver>
```

**Install global package:**
```
vp install -g <pkg>@latest [--node <NODE>]
```

**Quirks:**
- vite-plus shims `npm`/`pnpm` via `~/.vite-plus/bin/`.
- The detect script skips `.vite-plus` paths under npm-global to avoid double-counting.

---

## nvm (POSIX)

**Layout:**
```
$NVM_DIR/                          # default: ~/.nvm
├── nvm.sh
└── versions/node/v24.18.0/
    ├── bin/node
    └── lib/node_modules/          # per-version globals
```

**Switch command:**
```bash
. "$NVM_DIR/nvm.sh" && nvm use <ver>
```

**Quirks:**
- `nvm` is a shell function, not a binary. Must source `nvm.sh` before use.
- Each Node version has its own `lib/node_modules/`.

---

## fnm

**Layout (POSIX):**
```
~/.fnm/node-versions/v24.18.0/installation/bin/node
```

**Layout (macOS):**
```
~/Library/Application Support/fnm/node-versions/v24.18.0/installation/
```

**Layout (Windows):**
```
%LOCALAPPDATA%\fnm_multishells\<hash>\
%LOCALAPPDATA%\fnm\node-versions\v24.18.0\installation\
```

**Switch command:**
```
fnm use <ver>
```

**Quirks:**
- fnm requires shell-specific init (`eval "$(fnm env --shell bash)"`).
- On Windows, multishell dirs are ephemeral.

---

## nvm-windows

**Layout:**
```
%APPDATA%\nv\
├── nvm.exe
└── node/v24.18.0/
    └── node_modules/              # NOTE: no lib/ on Windows
%NVM_SYMLINK% -> %APPDATA%\nv\node\<active>\
```

**Switch command:**
```
nvm use <ver>
```
- Requires **administrator privileges**.
- Modifies the global symlink, persists across all shells.

---

## Volta

**Layout:**
```
~/.volta/
├── bin/{node,npm,npx,volta}
└── tools/image/
    ├── node/<ver>/bin/node
    └── packages/<pkg>/<ver>/{lib/,}node_modules/<pkg>/
```

**Switch command:**
- **None.** Volta pins per-project. `volta install node@<ver>` sets the user default.

**Install global package:**
```
volta install <pkg>@latest
```

---

## Bun runtime (excluded from node selection)

**Layout:**
```
~/.bun/
├── bin/{bun,opencode,...}
└── install/
    ├── cache/                      # download cache (NOT installs)
    └── global/node_modules/
```

**Why excluded:**
- Bun ships its own embedded Node (JavaScriptCore, not V8).
- `opencode-ai`'s postinstall needs a real Node to download the binary.
- For package updates, Bun is fine as the install tool. For postinstall, prefer vite-plus/nvm/fnm/Volta for the Node ABI.

**Quirks:**
- `trustedDependencies` in `~/package.json` controls postinstall for `opencode-ai`.
