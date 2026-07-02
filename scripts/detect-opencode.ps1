# detect-opencode.ps1 — read-only detection of opencode-family installs + Node managers.
# Compatible with: Windows PowerShell 5.1+ and pwsh 7+.
# Output: 4 tables (registry latest / installed copies / node managers / CLI resolution).
# Exits: 0 if all known copies fresh AND CLI points to latest, else 1.
#
# Usage:
#   .\scripts\detect-opencode.ps1
#   .\scripts\detect-opencode.ps1 -Help

#Requires -Version 5.1
[CmdletBinding()] param(
  [switch]$Help,
  [switch]$Version
)

if ($Help) { Get-Content $PSCommandPath -TotalCount 10; exit 0 }
if ($Version) { Write-Output "detect-opencode.ps1 version 1.0.0"; exit 0 }

$ErrorActionPreference = 'SilentlyContinue'
$script:ExitCode = 0

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
function Get-PkgVersion { param($File) return Get-JsonField -File $File -Key 'version' }
function Get-PkgDep     { param($File, $Dep) return Get-JsonField -File $File -Key $Dep }

function Get-RegistryLatest {
  param([string]$Pkg)
  $url = "https://registry.npmjs.org/$Pkg/latest"
  try {
    $j = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop
    return $j.version
  } catch { return 'FETCH_FAILED' }
}

function Compare-Versions {
  param([string]$A, [string]$B)
  if ($A -notmatch '^\d+(\.\d+)*$' -or $B -notmatch '^\d+(\.\d+)*$') { return 'UNKNOWN' }
  $va = [version]$A; $vb = [version]$B
  if ($va -gt $vb) { return 'GT' }
  if ($va -lt $vb) { return 'LT' }
  return 'EQ'
}

function Get-Status {
  param([string]$Installed, [string]$Latest)
  if ($Installed -in @('MISSING','UNKNOWN','') -or [string]::IsNullOrWhiteSpace($Installed)) { return 'UNKNOWN' }
  switch (Compare-Versions $Installed $Latest) {
    'EQ' { return 'FRESH' }
    'LT' { return 'STALE' }
    'GT' { return 'AHEAD' }
    default { return 'UNKNOWN' }
  }
}

function Parse-Version-String {
  param([string]$Raw)
  if (-not $Raw) { return 'UNKNOWN' }
  if ($Raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
  return 'UNKNOWN'
}

# ---- paths ----
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { (Get-Location).Path }

# ---- print helpers ----
function Print-Table-Header {
  param([string]$Title, [string]$H1, [string]$H2, [string]$H3, [string]$H4)
  Write-Output ""
  Write-Output "=== $Title ==="
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f $H1, $H2, $H3, $H4
  ('-' * 100)
}

# ---- A. Registry latest ----
Print-Table-Header 'A. Registry latest (npm)' 'package' 'latest' '' ''
$Packages = @('opencode-ai', 'oh-my-opencode', '@opencode-ai/plugin')
$script:RegLatest = @{}
foreach ($pkg in $Packages) {
  $v = Get-RegistryLatest $pkg
  $script:RegLatest[$pkg] = $v
  "{0,-16} {1,-50}" -f $pkg, $v
}

# ---- B. Installed copies ----
Print-Table-Header 'B. Installed copies' 'env' 'path' 'version' 'status'
$script:Rows = New-Object System.Collections.ArrayList
$script:Seen = @{}

function Add-Row {
  param([string]$Env, [string]$Path, [string]$Ver, [string]$LatestRef)
  if ($Ver -eq 'MISSING' -or [string]::IsNullOrWhiteSpace($Ver)) { return }
  $key = "$Env|$Path"
  if ($script:Seen.ContainsKey($key)) { return }
  $script:Seen[$key] = $true
  [void]$script:Rows.Add(@{Env=$Env; Path=$Path; Ver=$Ver; Latest=$LatestRef})
}

# 1) Binary
$BinPath = Join-Path $HomeDir '.opencode\bin\opencode.exe'
if (-not (Test-Path $BinPath)) { $BinPath = Join-Path $HomeDir '.opencode\bin\opencode' }
if (Test-Path $BinPath) {
  $raw = & $BinPath --version 2>$null
  $v = Parse-Version-String $raw
  Add-Row 'binary' $BinPath $v $script:RegLatest['opencode-ai']
}

# 1b) Plugin tree
$PlugPkg = Join-Path $HomeDir '.opencode\package.json'
if (Test-Path $PlugPkg) {
  $depV = Get-PkgDep $PlugPkg '@opencode-ai/plugin'
  $instV = Get-PkgVersion (Join-Path $HomeDir '.opencode\node_modules\@opencode-ai\plugin\package.json')
  Add-Row 'opencode-plugins' $PlugPkg "declared=$depV installed=$instV" $script:RegLatest['@opencode-ai/plugin']
}

# 2) npm global
if (Test-Cmd 'npm') {
  $npmRoot = (npm root -g 2>$null)
  if ($npmRoot -and (Test-Path $npmRoot) -and ($npmRoot -notlike '*\.vite-plus\*')) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $npmRoot "$pkg\package.json"
      $v = Get-PkgVersion $pj
      Add-Row 'npm-global' $pj $v $script:RegLatest[$pkg]
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
      Add-Row 'pnpm-global' $pj $v $script:RegLatest[$pkg]
    }
  }
}

# 3b) pnpm fallback
$PnpmFallback = if (Test-Path (Join-Path $env:LOCALAPPDATA 'pnpm')) { Join-Path $env:LOCALAPPDATA 'pnpm' } else { Join-Path $env:USERPROFILE '.local\share\pnpm' }
if (Test-Path $PnpmFallback) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    foreach ($cand in @('.global','global','')) {
      $pj = Join-Path $PnpmFallback "$cand\node_modules\$pkg\package.json"
      if (Test-Path $pj) { $v = Get-PkgVersion $pj; Add-Row 'pnpm-global' $pj $v $script:RegLatest[$pkg] }
    }
  }
}

# 4) Bun global
if (Test-Cmd 'bun') {
  $HomePkg = Join-Path $HomeDir 'package.json'
  if (Test-Path $HomePkg) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $depV = Get-PkgDep $HomePkg $pkg
      $instV = Get-PkgVersion (Join-Path $HomeDir "node_modules\$pkg\package.json")
      Add-Row 'bun-global' "$HomePkg [$pkg]" "declared=$depV installed=$instV" $script:RegLatest[$pkg]
    }
  }
  $BunGlobal = Join-Path $HomeDir '.bun\install\global'
  if (Test-Path (Join-Path $BunGlobal 'node_modules')) {
    foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
      $pj = Join-Path $BunGlobal "node_modules\$pkg\package.json"
      if (Test-Path $pj) { $v = Get-PkgVersion $pj; Add-Row 'bun-global' $pj "v=$v" $script:RegLatest[$pkg] }
    }
  }
}

# 5) vite-plus
$VpDir = Join-Path $HomeDir '.vite-plus'
if (Test-Path (Join-Path $VpDir 'packages')) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    $pj = Join-Path $VpDir "packages\$pkg\lib\node_modules\$pkg\package.json"
    $v = Get-PkgVersion $pj; Add-Row 'vite-plus' $pj $v $script:RegLatest[$pkg]
  }
}

# 6) Volta
$VoltaPkgs = Join-Path $HomeDir '.volta\tools\image\packages'
if (Test-Path $VoltaPkgs) {
  foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
    $pkgBase = Join-Path $VoltaPkgs $pkg
    if (Test-Path $pkgBase) {
      Get-ChildItem $pkgBase -Directory | ForEach-Object {
        $pj = Join-Path $_.FullName "lib\node_modules\$pkg\package.json"
        if (-not (Test-Path $pj)) { $pj = Join-Path $_.FullName "node_modules\$pkg\package.json" }
        $v = Get-PkgVersion $pj; Add-Row 'volta' $pj $v $script:RegLatest[$pkg]
      }
    }
  }
}

# 7) nvm-windows
if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'nv'))) {
  $nvBase = Join-Path $env:APPDATA 'nv\node'
  if (Test-Path $nvBase) {
    Get-ChildItem $nvBase -Directory | ForEach-Object {
      foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
        $pj = Join-Path $_.FullName "node_modules\$pkg\package.json"
        $v = Get-PkgVersion $pj; Add-Row 'nvm-windows' $pj $v $script:RegLatest[$pkg]
      }
    }
  }
}

# 8) fnm
if (Test-Cmd 'fnm') {
  try {
    $fnmBase = Join-Path $env:LOCALAPPDATA 'fnm_multishells'
    if (Test-Path $fnmBase) {
      Get-ChildItem $fnmBase -Directory | ForEach-Object {
        foreach ($pkg in @('opencode-ai','oh-my-opencode')) {
          $pj = Join-Path $_.FullName "node_modules\$pkg\package.json"
          $v = Get-PkgVersion $pj; Add-Row 'fnm' $pj $v $script:RegLatest[$pkg]
        }
      }
    }
  } catch {}
}

# Print B rows
foreach ($row in $script:Rows) {
  $ver = $row.Ver; $latest = $row.Latest
  if ($ver -match 'declared=.*installed=(.+)$') { $instV = $Matches[1].Trim(); $st = Get-Status $instV $latest }
  elseif ($ver -match '^v=(.+)$') { $instV = $Matches[1].Trim(); $st = Get-Status $instV $latest }
  else { $st = Get-Status $ver $latest }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f $row.Env, $row.Path, $ver, $st
  if ($st -eq 'STALE') { $script:ExitCode = 1 }
}

# ---- C. Node managers ----
Print-Table-Header 'C. Node version managers' 'manager' 'bin / path' 'versions' 'current'

# vite-plus
if (Test-Cmd 'vp') {
  $vpBin = (Get-Command vp).Source
  $vpNodeDir = Join-Path $HomeDir '.vite-plus\js_runtime\node'
  $vpVersions = if (Test-Path $vpNodeDir) { (Get-ChildItem $vpNodeDir -Directory | Where-Object { $_.Name -notmatch '\.(lock|json)$' } | ForEach-Object { $_.Name }) -join ',' } else { '' }
  $curLink = Join-Path $HomeDir '.vite-plus\current'
  $curVer = if (Test-Path $curLink) { (Get-Item $curLink).Target | Split-Path -Leaf } else { '' }
  $nodeCur = if (Test-Cmd 'node') { (node --version 2>$null) } else { '' }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'vite-plus', $vpBin, $vpVersions, "vp=$curVer node=$nodeCur"
}

# nvm-windows
if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'nv'))) {
  $nvBase = Join-Path $env:APPDATA 'nv\node'
  $nvwVersions = if (Test-Path $nvBase) { (Get-ChildItem $nvBase -Directory | ForEach-Object { $_.Name }) -join ',' } else { '' }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'nvm-windows', "$env:APPDATA\nv", $nvwVersions, 'n/a'
}

# fnm
if (Test-Cmd 'fnm') {
  $fnmBin = (Get-Command fnm).Source
  try {
    $fnmList = (fnm list 2>$null) -join "`n"
    $fnmVersions = ([regex]::Matches($fnmList, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
    $fnmCur = (fnm current 2>$null)
  } catch { $fnmVersions = ''; $fnmCur = '' }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'fnm', $fnmBin, $fnmVersions, $fnmCur
}

# Volta
if (Test-Cmd 'volta') {
  $voltaBin = (Get-Command volta).Source
  try {
    $vList = (volta list all 2>$null) -join "`n"
    $voltaVersions = ([regex]::Matches($vList, 'node@(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
  } catch { $voltaVersions = '' }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'volta', $voltaBin, $voltaVersions, '(per-project pin)'
}

# Bun runtime
if (Test-Cmd 'bun') {
  $bunBin = (Get-Command bun).Source
  $bunVer = (bun --version 2>$null)
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'bun-runtime', $bunBin, '-', $bunVer
}

# ---- D. CLI resolution ----
Print-Table-Header 'D. CLI resolution' 'which' 'version' 'matches latest?' ''

$CliPath = ''
if (Test-Cmd 'opencode') { $CliPath = (Get-Command opencode).Source }
elseif (Test-Path (Join-Path $HomeDir '.opencode\bin\opencode.exe')) { $CliPath = Join-Path $HomeDir '.opencode\bin\opencode.exe' }

if ($CliPath) {
  $rawCli = & $CliPath --version 2>$null
  $cliV = Parse-Version-String $rawCli
  $cmp = Compare-Versions $cliV $script:RegLatest['opencode-ai']
  switch ($cmp) {
    'EQ' { $flag = 'YES (fresh)' }
    'LT' { $flag = 'NO (stale)'; $script:ExitCode = 1 }
    'GT' { $flag = 'AHEAD' }
    default { $flag = 'UNKNOWN'; $script:ExitCode = 1 }
  }
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'opencode', $CliPath, $cliV, $flag
} else {
  "{0,-16} {1,-50} {2,-22} {3,-10}" -f 'opencode', '(not in PATH)', '-', 'MISSING'
  $script:ExitCode = 1
}

# PATH shadow analysis
Write-Output ""
Write-Output "PATH shadow analysis:"
if (Test-Cmd 'opencode') { Write-Output ("  first hit            : " + (Get-Command opencode).Source) }
$binCheck = Join-Path $HomeDir '.opencode\bin\opencode.exe'
if (-not (Test-Path $binCheck)) { $binCheck = Join-Path $HomeDir '.opencode\bin\opencode' }
if (Test-Path $binCheck) { Write-Output ("  ~/.opencode/bin/opencode : " + (& $binCheck --version 2>$null)) }
$vpShim = Join-Path $HomeDir '.vite-plus\bin\opencode.exe'
if (-not (Test-Path $vpShim)) { $vpShim = Join-Path $HomeDir '.vite-plus\bin\opencode' }
if (Test-Path $vpShim) { Write-Output ("  ~/.vite-plus/bin/opencode : shim -> " + (Get-Item $vpShim).Target) }
$bunShim = Join-Path $HomeDir '.bun\bin\opencode.exe'
if (-not (Test-Path $bunShim)) { $bunShim = Join-Path $HomeDir '.bun\bin\opencode' }
if (Test-Path $bunShim) { Write-Output ("  ~/.bun/bin/opencode       : " + (& $bunShim --version 2>$null)) }
$pnpmShim = Join-Path $env:LOCALAPPDATA 'pnpm\opencode.exe'
if (Test-Path $pnpmShim) { Write-Output "  $pnpmShim exists" }

Write-Output ""
Write-Output "Exit: $($script:ExitCode) (0 = all known copies fresh AND CLI resolves to latest)."
exit $script:ExitCode
