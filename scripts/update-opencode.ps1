# update-opencode.ps1 — plan + apply updates for STALE opencode-family installs.
# Compatible with: Windows PowerShell 5.1+ and pwsh 7+.
#
# Usage:
#   .\scripts\update-opencode.ps1              # dry-run
#   .\scripts\update-opencode.ps1 -Apply       # execute
#   .\scripts\update-opencode.ps1 -Apply -Yes  # skip confirmation
#
# Strategy:
#   - Reuse detect-opencode.ps1's detection logic (inlined) to enumerate STALE installs.
#   - For each STALE install, emit the env-native update command.
#   - -Apply executes them; verify at the end by re-running detect.

#Requires -Version 5.1
[CmdletBinding()] param(
  [switch]$Apply,
  [switch]$Yes,
  [switch]$Help,
  [switch]$Version
)

if ($Help) { Get-Content $PSCommandPath -TotalCount 15; exit 0 }
if ($Version) { Write-Output "update-opencode.ps1 version 1.0.0"; exit 0 }

$ErrorActionPreference = 'SilentlyContinue'

$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:DetectScript = Join-Path $script:ScriptDir 'detect-opencode.ps1'

# ---- helpers ----
function Test-Cmd { param([string]$Name); return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-JsonField {
  param([string]$File, [string]$Key)
  if (-not (Test-Path $File)) { return 'MISSING' }
  try {
    $j = Get-Content $File -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $val = $j.$Key
    if ($null -eq $val) { return 'MISSING' }
    return $val.ToString()
  } catch { return 'MISSING' }
}
function Get-PkgVersion { param($File) return Get-JsonField $File 'version' }
function Get-PkgDep     { param($File, $Dep) return Get-JsonField $File $Dep }

function Get-RegistryLatest {
  param([string]$Pkg)
  $url = "https://registry.npmjs.org/$Pkg/latest"
  try { $j = Invoke-RestMethod $url -TimeoutSec 10 -ErrorAction Stop; return $j.version }
  catch { return 'FETCH_FAILED' }
}

function Compare-Versions {
  param([string]$A, [string]$B)
  if ($A -notmatch '^\d+(\.\d+)*$' -or $B -notmatch '^\d+(\.\d+)*$') { return 'UNKNOWN' }
  $va = [version]$A; $vb = [version]$B
  if ($va -gt $vb) { return 'GT' }
  if ($va -lt $vb) { return 'LT' }
  return 'EQ'
}

function Parse-Version-String {
  param([string]$Raw)
  if (-not $Raw) { return 'UNKNOWN' }
  if ($Raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
  return 'UNKNOWN'
}

# ---- Best Node selection ----
function Get-BestNode {
  $best = @{ Version = ''; Manager = ''; SwitchCmd = '' }

  # vite-plus
  if (Test-Cmd 'vp') {
    $vpNodeDir = Join-Path $HomeDir '.vite-plus\js_runtime\node'
    if (Test-Path $vpNodeDir) {
      Get-ChildItem $vpNodeDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $v = $_.Name -replace '^v',''
        if ($v -notmatch '^\d+(\.\d+)*$') { return }
        if (-not $best.Version -or ((Compare-Versions $v $best.Version) -eq 'GT')) {
          $best.Version = $v; $best.Manager = 'vite-plus'; $best.SwitchCmd = "vp env use $v"
        }
      }
    }
  }

  # nvm (POSIX, rare on Windows native)
  $nvmDir = if ($env:NVM_DIR) { $env:NVM_DIR } else { Join-Path $HomeDir '.nvm' }
  $nvmNodeDir = Join-Path $nvmDir 'versions\node'
  if (Test-Path $nvmNodeDir) {
    Get-ChildItem $nvmNodeDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $v = $_.Name -replace '^v',''
      if ($v -notmatch '^\d+(\.\d+)*$') { return }
      if (-not $best.Version -or ((Compare-Versions $v $best.Version) -eq 'GT')) {
        $best.Version = $v; $best.Manager = 'nvm'; $best.SwitchCmd = ". `"$nvmDir\nvm.sh`" ; nvm use $v"
      }
    }
  }

  # fnm
  if (Test-Cmd 'fnm') {
    try {
      $fnmList = (fnm list 2>$null) -join "`n"
      $fnmVersions = [regex]::Matches($fnmList, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
      foreach ($v in $fnmVersions) {
        if (-not $best.Version -or ((Compare-Versions $v $best.Version) -eq 'GT')) {
          $best.Version = $v; $best.Manager = 'fnm'; $best.SwitchCmd = "fnm use $v"
        }
      }
    } catch {}
  }

  # nvm-windows
  if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'nv\node'))) {
    $nvBase = Join-Path $env:APPDATA 'nv\node'
    Get-ChildItem $nvBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $v = $_.Name -replace '^v',''
      if ($v -notmatch '^\d+(\.\d+)*$') { return }
      if (-not $best.Version -or ((Compare-Versions $v $best.Version) -eq 'GT')) {
        $best.Version = $v; $best.Manager = 'nvm-windows'; $best.SwitchCmd = "nvm use $v"
      }
    }
  }

  # Volta
  if (Test-Cmd 'volta') {
    $vList = (volta list all 2>$null) -join "`n"
    $voltaVers = [regex]::Matches($vList, 'node@(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
    foreach ($v in $voltaVers) {
      if (-not $best.Version -or ((Compare-Versions $v $best.Version) -eq 'GT')) {
        $best.Version = $v; $best.Manager = 'volta'; $best.SwitchCmd = '(volta pins per-project, no shell switch)'
      }
    }
  }

  return $best
}

# ---- paths ----
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { (Get-Location).Path }

# ---- Fetch registry latest ----
$script:Reg = @{}
foreach ($pkg in @('opencode-ai','oh-my-opencode','@opencode-ai/plugin')) {
  $script:Reg[$pkg] = Get-RegistryLatest $pkg
}

# ---- Collect STALE plan rows ----
$script:Plan = New-Object System.Collections.ArrayList
function Add-Plan {
  param([string]$Env, [string]$Path, [string]$Current, [string]$Latest, [string]$Cmd)
  [void]$script:Plan.Add(@{ Env=$Env; Path=$Path; Current=$Current; Latest=$Latest; Cmd=$Cmd })
}

# 1) Binary
$BinPath = Join-Path $HomeDir '.opencode\bin\opencode.exe'
if (-not (Test-Path $BinPath)) { $BinPath = Join-Path $HomeDir '.opencode\bin\opencode' }
if (Test-Path $BinPath) {
  $raw = & $BinPath --version 2>$null
  $v = Parse-Version-String $raw
  if ((Compare-Versions $v $script:Reg['opencode-ai']) -eq 'LT') {
    Add-Plan 'binary' $BinPath $v $script:Reg['opencode-ai'] 'opencode upgrade'
  }
}

# 1b) Plugin tree
$PlugPkg = Join-Path $HomeDir '.opencode\package.json'
if (Test-Path $PlugPkg) {
  $instPj = Join-Path $HomeDir '.opencode\node_modules\@opencode-ai\plugin\package.json'
  $instV = Get-PkgVersion $instPj
  if ((Compare-Versions $instV $script:Reg['@opencode-ai/plugin']) -eq 'LT') {
    $bunClause = if (Test-Cmd 'bun') { 'bun install @opencode-ai/plugin@latest' } else { 'npm install --save @opencode-ai/plugin@latest' }
    Add-Plan 'opencode-plugins' $PlugPkg $instV $script:Reg['@opencode-ai/plugin'] "cd `"$HomeDir\.opencode`"; $bunClause"
  }
}

# 2) npm global
if (Test-Cmd 'npm') {
  $npmRoot = (npm root -g 2>$null)
  if ($npmRoot -and (Test-Path $npmRoot) -and ($npmRoot -notlike '*\.vite-plus\*')) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $npmRoot "$pkg\package.json"
      $v = Get-PkgVersion $pj
      if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
        Add-Plan 'npm-global' $pj $v $script:Reg[$pkg] "npm i -g $pkg@latest"
      }
    }
  }
}

# 3) pnpm global
if (Test-Cmd 'pnpm') {
  $pnpmRoot = (pnpm root -g 2>$null)
  if ($pnpmRoot -and (Test-Path $pnpmRoot) -and ($pnpmRoot -notlike '*\.vite-plus\*')) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $pnpmRoot "$pkg\package.json"
      $v = Get-PkgVersion $pj
      if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
        Add-Plan 'pnpm-global' $pj $v $script:Reg[$pkg] "pnpm add -g $pkg@latest"
      }
    }
  }
}
# 3b) pnpm fallback
$PnpmFallback = if (Test-Path (Join-Path $env:LOCALAPPDATA 'pnpm')) { Join-Path $env:LOCALAPPDATA 'pnpm' } else { Join-Path $env:USERPROFILE '.local\share\pnpm' }
if (Test-Path $PnpmFallback) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    foreach ($cand in @('.global','global','')) {
      $pj = Join-Path $PnpmFallback "$cand\node_modules\$pkg\package.json"
      if (Test-Path $pj) {
        $v = Get-PkgVersion $pj
        if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
          Add-Plan 'pnpm-global' $pj $v $script:Reg[$pkg] "pnpm add -g $pkg@latest"
        }
      }
    }
  }
}

# 4) Bun global
if (Test-Cmd 'bun') {
  $HomePkg = Join-Path $HomeDir 'package.json'
  if (Test-Path $HomePkg) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $instPj = Join-Path $HomeDir "node_modules\$pkg\package.json"
      $instV = Get-PkgVersion $instPj
      if ((Compare-Versions $instV $script:Reg[$pkg]) -eq 'LT') {
        Add-Plan 'bun-global' "$HomePkg [$pkg]" $instV $script:Reg[$pkg] "bun add -g $pkg@latest"
      }
    }
  }
  $BunGlobal = Join-Path $HomeDir '.bun\install\global'
  if (Test-Path (Join-Path $BunGlobal 'node_modules')) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $BunGlobal "node_modules\$pkg\package.json"
      if (Test-Path $pj) {
        $v = Get-PkgVersion $pj
        if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
          Add-Plan 'bun-global' $pj $v $script:Reg[$pkg] "cd `"$BunGlobal`"; bun install $pkg@latest"
        }
      }
    }
  }
}

# 5) vite-plus
$VpDir = Join-Path $HomeDir '.vite-plus'
if (Test-Path (Join-Path $VpDir 'packages')) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    $pj = Join-Path $VpDir "packages\$pkg\lib\node_modules\$pkg\package.json"
    $v = Get-PkgVersion $pj
    if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
      Add-Plan 'vite-plus' $pj $v $script:Reg[$pkg] "vp install -g $pkg@latest"
    }
  }
}

# 6) Volta
$VoltaPkgs = Join-Path $HomeDir '.volta\tools\image\packages'
if (Test-Path $VoltaPkgs) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    $pkgBase = Join-Path $VoltaPkgs $pkg
    if (Test-Path $pkgBase) {
      Get-ChildItem $pkgBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pj = Join-Path $_.FullName "lib\node_modules\$pkg\package.json"
        if (-not (Test-Path $pj)) { $pj = Join-Path $_.FullName "node_modules\$pkg\package.json" }
        $v = Get-PkgVersion $pj
        if ((Compare-Versions $v $script:Reg[$pkg]) -eq 'LT') {
          Add-Plan 'volta' $pj $v $script:Reg[$pkg] "volta install $pkg@latest"
        }
      }
    }
  }
}

# 7) nvm-windows
if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'nv\node'))) {
  $nvBase = Join-Path $env:APPDATA 'nv\node'
  Get-ChildItem $nvBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $v = $_.Name -replace '^v',''
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $_.FullName "node_modules\$pkg\package.json"
      $pv = Get-PkgVersion $pj
      if ((Compare-Versions $pv $script:Reg[$pkg]) -eq 'LT') {
        Add-Plan 'nvm-windows' $pj $pv $script:Reg[$pkg] "nvm use $v ; npm i -g $pkg@latest"
      }
    }
  }
}

# 8) fnm
if (Test-Cmd 'fnm') {
  $fnmBase = Join-Path $env:LOCALAPPDATA 'fnm_multishells'
  if (Test-Path $fnmBase) {
    Get-ChildItem $fnmBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $dirVer = $_.Name -replace '^v','' -replace '[-_].*$',''
      foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
        $pj = Join-Path $_.FullName "node_modules\$pkg\package.json"
        $pv = Get-PkgVersion $pj
        if ((Compare-Versions $pv $script:Reg[$pkg]) -eq 'LT') {
          $useV = if ($dirVer -match '^\d+\.\d+\.\d+$') { $dirVer } else { '' }
          $cmd = if ($useV) { "fnm use $useV ; npm i -g $pkg@latest" } else { "npm i -g $pkg@latest" }
          Add-Plan 'fnm' $pj $pv $script:Reg[$pkg] $cmd
        }
      }
    }
  }
}

# ---- Print plan ----
Write-Output ""
Write-Output "=== Update plan ==="
$mode = if ($Apply) { 'APPLY (will mutate)' } else { 'DRY-RUN (no mutations)' }
Write-Output "Mode: $mode"
Write-Output ""

if ($script:Plan.Count -eq 0) {
  Write-Output "Nothing to update - all known copies are FRESH."
  Write-Output ""
  Write-Output "Running full detect for verification:"
  if (Test-Path $script:DetectScript) { & $script:DetectScript; exit $LASTEXITCODE }
  exit 0
}

"{0,-16} {1,-50} {2,-14} {3,-14} {4}" -f 'env','path','current','latest','update_cmd'
Write-Output ('-' * 120)
foreach ($row in $script:Plan) {
  "{0,-16} {1,-50} {2,-14} {3,-14} {4}" -f $row.Env, $row.Path, $row.Current, $row.Latest, $row.Cmd
}

# Best Node info
$best = Get-BestNode
Write-Output ""
Write-Output ("Best Node available: " + $best.Version + " (via " + $best.Manager + ")")
if ($best.SwitchCmd -and ($best.SwitchCmd -ne '(volta pins per-project, no shell switch)')) {
  Write-Output ("  Activate with: " + $best.SwitchCmd)
}

# Dry-run exit
if (-not $Apply) {
  Write-Output ""
  Write-Output "Dry-run only. To execute, re-run with -Apply."
  exit 0
}

# ---- Apply ----
Write-Output ""
if (-not $Yes) {
  $ans = Read-Host -Prompt "Proceed with the above updates? [y/N]"
  if ($ans -notmatch '^[yY]') { Write-Output "aborted"; exit 1 }
}

# Activate best Node if applicable
if ($best.SwitchCmd -and ($best.SwitchCmd -ne '(volta pins per-project, no shell switch)')) {
  Write-Output ""
  Write-Output "[node] activating $($best.Version) via $($best.Manager) ..."
  try { Invoke-Expression $best.SwitchCmd 2>&1 | ForEach-Object { "  [node] $_" } }
  catch { Write-Output "  [node] (switch failed or n/a, continuing)" }
}

# Execute each plan command
Write-Output ""
foreach ($row in $script:Plan) {
  Write-Output ""
  Write-Output ("[" + $row.Env + "] " + $row.Cmd)
  Write-Output ("  path: " + $row.Path + " (" + $row.Current + " -> " + $row.Latest + ")")

  $skip = $false
  switch ($row.Env) {
    'binary' { if (-not (Test-Cmd 'opencode') -and -not (Test-Path $BinPath)) { Write-Output "  SKIP: opencode binary not in PATH"; $skip = $true } }
    'opencode-plugins' { if (-not (Test-Cmd 'bun') -and -not (Test-Cmd 'npm')) { Write-Output "  SKIP: neither bun nor npm in PATH"; $skip = $true } }
    { $_ -in 'npm-global','nvm','nvm-windows','fnm' } { if (-not (Test-Cmd 'npm')) { Write-Output "  SKIP: npm not in PATH"; $skip = $true } }
    'pnpm-global' { if (-not (Test-Cmd 'pnpm')) { Write-Output "  SKIP: pnpm not in PATH"; $skip = $true } }
    'bun-global' { if (-not (Test-Cmd 'bun')) { Write-Output "  SKIP: bun not in PATH"; $skip = $true } }
    'vite-plus' { if (-not (Test-Cmd 'vp')) { Write-Output "  SKIP: vp not in PATH"; $skip = $true } }
    'volta' { if (-not (Test-Cmd 'volta')) { Write-Output "  SKIP: volta not in PATH"; $skip = $true } }
  }
  if ($skip) { continue }

  try { $out = Invoke-Expression $row.Cmd 2>&1; $out | ForEach-Object { "  $_" }; Write-Output "  OK" }
  catch { Write-Output "  FAILED - see output above" }
}

# ---- Verify ----
Write-Output ""
Write-Output "=== Verify (re-running detect) ==="
if (Test-Path $script:DetectScript) { & $script:DetectScript; $verifyExit = $LASTEXITCODE }
else { Write-Output "(detect-opencode.ps1 not found alongside this script; skipping verify)"; $verifyExit = 0 }

Write-Output ""
if ($verifyExit -eq 0) { Write-Output "[OK] All known copies are FRESH and CLI resolves to latest." }
else {
  Write-Output "[FAIL] Some copies still STALE or CLI does not resolve to latest. See table above."
  Write-Output "  Common fix: reorder PATH so the desired opencode binary is first, or"
  Write-Output "  remove the stale copy (e.g. remove `$env:USERPROFILE\.opencode\bin\opencode.exe if you prefer bun-global)."
}
exit $verifyExit
