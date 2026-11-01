# Double-click or: powershell -ExecutionPolicy Bypass -File .\run-windows.ps1
# Starts the event bridge (WebSocket :8765, MCP :8766/mcp) and opens the Godot
# client. The bridge stops when the game window closes.
# Extra harness flags can be passed through, e.g.  .\run-windows.ps1 --mode live
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Find-Python {
    foreach ($name in @("python3.14", "python3.13", "python3.12", "python3.11", "python3.10", "python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { continue }
        try {
            $ver = & $cmd.Source -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2>$null
            if ($ver -match '^(\d+)\.(\d+)$' -and ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10))) {
                return $cmd.Source
            }
        } catch { }
    }
    return $null
}

function Find-Godot {
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $cmd = Get-Command Godot* -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Godot\Godot*.exe",
        "$env:ProgramFiles\Godot\Godot*.exe",
        "$env:USERPROFILE\Downloads\Godot*.exe",
        "$env:USERPROFILE\scoop\apps\godot\current\Godot*.exe",
        "$env:USERPROFILE\scoop\shims\godot.exe"
    )
    foreach ($pattern in $candidates) {
        $hit = Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $hit) { return $hit.FullName }
    }
    return $null
}

function Test-PortInUse([int]$Port) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $false
    } catch {
        return $true
    }
}

if (Test-PortInUse 8765) {
    Write-Error "Port 8765 is already in use. Another Agent Office harness may be running. Close it first (or stop the process using that port)."
    exit 1
}

$godot = Find-Godot
if (-not $godot) {
    Write-Error "godot not found on PATH. Install Godot 4.3+ (standard build) from https://godotengine.org/download/windows/ and add it to PATH, or place Godot_v*-stable_win64.exe where this script can find it."
    exit 1
}

$classCache = Join-Path $PSScriptRoot ".godot\global_script_class_cache.cfg"
if (-not (Test-Path -LiteralPath $classCache)) {
    Write-Host "First-time Godot import (building .godot class cache)..."
    & $godot --headless --path $PSScriptRoot --import
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Godot import failed. Try opening the project in the editor once: `"$godot`" --path `"$PSScriptRoot`" --editor"
        exit 1
    }
}

$py = Find-Python
if (-not $py) {
    Write-Error "Python 3.10+ not found. Install from https://www.python.org/downloads/ and tick 'Add python.exe to PATH'."
    exit 1
}

$venvPython = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
$venvPip = Join-Path $PSScriptRoot ".venv\Scripts\pip.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host "Creating .venv with $py ..."
    & $py -m venv (Join-Path $PSScriptRoot ".venv")
}

$stamp = Join-Path $PSScriptRoot ".venv\.requirements.stamp"
$req = Join-Path $PSScriptRoot "requirements.txt"
$needInstall = -not (Test-Path -LiteralPath $stamp)
if (-not $needInstall) {
    $needInstall = (Get-Item $req).LastWriteTimeUtc -gt (Get-Item $stamp).LastWriteTimeUtc
}
if ($needInstall) {
    & $venvPip install -q -r $req
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Get-Date -Format o | Set-Content -LiteralPath $stamp
}

$cmdsArgs = @()
$cmdsFile = Join-Path $PSScriptRoot "agent_cmds.json"
if (Test-Path -LiteralPath $cmdsFile) {
    $cmdsArgs = @("--agent-cmds-file", "agent_cmds.json")
    Write-Host "CLI bindings: agent_cmds.json"
}

$harnessArgs = @("agent_harness.py", "--mcp-port", "8766", "--lite-port", "8787") + $cmdsArgs
# Live mode: worktrees + stream-json poses (text fallback remains in harness)
$isLive = $false
foreach ($a in $args) {
  if ($a -eq "live" -or $a -eq "--mode=live") { $isLive = $true }
}
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -eq "--mode" -and ($i + 1) -lt $args.Count -and $args[$i + 1] -eq "live") { $isLive = $true }
}
if ($cmdsArgs -contains "live") { $isLive = $true }
if ($isLive) {
  $harnessArgs += @("--worktrees", "--stream-json")
  Write-Host "Harness extras: --worktrees --stream-json"
}
$harnessArgs += @($args)
$bridge = Start-Process -FilePath $venvPython -ArgumentList $harnessArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2

if ($env:OFFICE_MCP_TOKEN) {
    Write-Host "MCP connector: http://127.0.0.1:8766/mcp  (token from `$env:OFFICE_MCP_TOKEN)"
} else {
    Write-Host "MCP connector: http://127.0.0.1:8766/mcp  (token in $PSScriptRoot\.office_token)"
Write-Host "Lite ops view: http://127.0.0.1:8787/lite"
}

try {
    & $godot --path $PSScriptRoot
} finally {
    if ($null -ne $bridge -and -not $bridge.HasExited) {
        Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue
        # Child CLI processes may linger; best-effort cleanup of this tree.
        try {
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$($bridge.Id)" -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}
