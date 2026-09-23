#Requires -Version 5.1
<#
.SYNOPSIS
  Uninstalls the localagent package for the current user (no admin rights).

.DESCRIPTION
  Stops and unregisters the "LocalAgent Server" task, kills llama-server.exe
  processes started from this install, removes our entries from the omp and
  editor config files, removes the subagent pieces (uv tool, our config.toml
  when it is exactly the one install.ps1 wrote, the mcp.json server entry),
  removes the bin\ PATH entry, then deletes the install directory -- keeping
  models\ unless -RemoveModel is given.

  Not touched (and printed at the end): the omp binary, uv itself and the
  %USERPROFILE%\.local\bin PATH entry, VS Code itself and its extensions,
  any foreign entries in models.yml / config.yml / chatLanguageModels.json /
  mcp.json, and the model when -RemoveModel is not set.

.PARAMETER NonInteractive
  No confirmation prompt.

.PARAMETER RemoveModel
  Also delete the 23 GB model file (models\).

.PARAMETER InstallDir
  Package root if it was installed somewhere non-standard.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File uninstall.ps1 -NonInteractive
#>
[CmdletBinding()]
param(
  [switch]$NonInteractive,
  [switch]$RemoveModel,
  [string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

$modulePath = $null
foreach ($candidate in @(
    (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1'),
    (Join-Path -Path $PSScriptRoot -ChildPath 'lib\localagent.psm1')
  )) {
  if (Test-Path -LiteralPath $candidate) {
    $modulePath = $candidate
    break
  }
}
if (-not $modulePath) {
  throw 'lib\localagent.psm1 was not found (looked in ..\lib and .\lib next to this script).'
}
Import-Module -Name $modulePath -Force

$script:Paths = Get-LocalAgentPaths
if ($InstallDir) {
  $script:Paths = Get-LocalAgentPaths -InstallDir $InstallDir
}
$script:Constants = Get-LocalAgentConstants

function Write-Uninstall {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ('[uninstall] {0}' -f $Message)
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

Write-Host ('This removes the localagent install in {0}' -f $script:Paths.InstallDir)
Write-Host ('  task "{0}", the server processes, the PATH entry, our entries in' -f $script:Constants.TaskName)
Write-Host '  omp config.yml (modelRoles, setupVersion: 2), a leftover managed block in'
Write-Host '  models.yml (older installs), chatLanguageModels.json, .continue\config.yaml,'
Write-Host '  mcp.json, the subagent uv tool and (only if install.ps1 wrote it) the subagent config.toml.'
if ($RemoveModel) {
  Write-Host ('  -RemoveModel given: the model ({0}) is DELETED too.' -f $script:Paths.ModelFile)
}
else {
  Write-Host ('  the model in models\ is KEPT ({0}).' -f $script:Paths.Models)
}
if (-not $NonInteractive) {
  $answer = Read-Host 'Continue? (y/N)'
  if ($answer -notmatch '^[Yy]') {
    Write-Host 'aborted.'
    exit 1
  }
}

# ---------------------------------------------------------------------------
# 1. Stop the server and the task
# ---------------------------------------------------------------------------

try {
  Stop-ScheduledTask -TaskName ([string]$script:Constants.TaskName) -ErrorAction Stop
  Write-Uninstall ('task "{0}" stopped.' -f $script:Constants.TaskName)
}
catch {
  Write-Uninstall ('task "{0}" not running or not registered; skipping.' -f $script:Constants.TaskName)
}

$procs = @(Get-ServerProcess -InstallDir $script:Paths.InstallDir)
foreach ($proc in $procs) {
  try {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
    Write-Uninstall ('stopped llama-server pid {0}.' -f $proc.ProcessId)
  }
  catch {
    Write-Uninstall ('could not stop pid {0}: {1}' -f $proc.ProcessId, $_.Exception.Message)
  }
}
if ($procs.Count -eq 0) {
  Write-Uninstall 'no llama-server.exe from this install was running.'
}

# ---------------------------------------------------------------------------
# 2. Unregister the task
# ---------------------------------------------------------------------------

$unregistered = $false
try {
  Unregister-ScheduledTask -TaskName ([string]$script:Constants.TaskName) -Confirm:$false -ErrorAction Stop
  $unregistered = $true
}
catch {
  $unregistered = $false
}
if (-not $unregistered) {
  # schtasks fallback (same task, different registration path).
  & schtasks.exe /Delete /TN "$($script:Constants.TaskName)" /F | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $unregistered = $true
  }
}
if ($unregistered) {
  Write-Uninstall ('task "{0}" unregistered.' -f $script:Constants.TaskName)
}
else {
  Write-Uninstall ('task "{0}" was not registered (nothing to remove).' -f $script:Constants.TaskName)
}

# ---------------------------------------------------------------------------
# 3. Remove our entries from user config files
# ---------------------------------------------------------------------------

$modelsResult = Remove-ManagedBlock -Path $script:Paths.OmpModelsYml `
  -Begin '# >>> localagent' -End '# <<< localagent'
Write-Uninstall ('omp models.yml: our block {0} (a managed block only exists on installs older than the llama.cpp provider switch).' -f $modelsResult)

$rolesResult = Remove-YamlTopLevelMapKeys -Path $script:Paths.OmpConfigYml -Key 'modelRoles' `
  -Keys @('default', 'smol', 'slow', 'plan')
Write-Uninstall ('omp config.yml: our modelRoles keys {0}.' -f $rolesResult)

# setupVersion is only ours when it still holds our value (2). If omp's own
# setup wrote a newer value since, it is left alone.
$setupResult = Remove-YamlScalar -Path $script:Paths.OmpConfigYml -Key 'setupVersion' -Value '2'
Write-Uninstall ('omp config.yml: our setupVersion line {0}.' -f $setupResult)

$chatResult = Remove-JsonArrayEntry -Path $script:Paths.ChatModelsJson -Name ([string]$script:Constants.VsCodeEntryName)
Write-Uninstall ('chatLanguageModels.json: entry "{0}" {1}.' -f $script:Constants.VsCodeEntryName, $chatResult)

$continueResult = Remove-ManagedBlock -Path $script:Paths.ContinueConfig `
  -Begin '# >>> localagent' -End '# <<< localagent'
Write-Uninstall ('.continue\config.yaml: our block {0}.' -f $continueResult)

# ---------------------------------------------------------------------------
# 4. Remove the subagent MCP server pieces (-WithSubagent)
# ---------------------------------------------------------------------------

$uvCmd = Get-Command -Name 'uv.exe' -ErrorAction SilentlyContinue
if (-not $uvCmd) {
  $uvCmd = Get-Command -Name 'uv' -ErrorAction SilentlyContinue
}
if (-not $uvCmd) {
  # A stale session PATH: uv lives in %USERPROFILE%\.local\bin after the
  # installer ran, so try there before giving up.
  $uvShim = Join-Path -Path $script:Paths.UvBin -ChildPath 'uv.exe'
  if (Test-Path -LiteralPath $uvShim) {
    $uvCmd = [pscustomobject]@{ Source = $uvShim }
  }
}
if ($uvCmd) {
  & $uvCmd.Source tool uninstall ([string]$script:Constants.SubagentToolName) | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Uninstall ('subagent tool uninstalled (uv tool uninstall {0}).' -f $script:Constants.SubagentToolName)
  }
  else {
    Write-Uninstall ('subagent tool was not installed (uv tool uninstall exited with code {0}).' -f $LASTEXITCODE)
  }
}
else {
  Write-Uninstall 'uv is not installed; the subagent tool was not (or is no longer) uninstallable through it.'
  foreach ($shim in @($script:Paths.SubagentMcpExe, $script:Paths.SubagentExe)) {
    if (Test-Path -LiteralPath $shim) {
      Write-Uninstall ('WARNING: {0} is left behind (uv is gone); delete it by hand.' -f $shim)
    }
  }
}

# The config file is only ours when it is byte-for-byte what install.ps1
# wrote: the template filled with the same omp path (read back from the
# file) and the same server port (config.json). Anything else is kept.
$subagentConfig = $script:Paths.SubagentConfig
if (-not (Test-Path -LiteralPath $subagentConfig)) {
  Write-Uninstall ('subagent config: {0} does not exist; nothing to remove.' -f $subagentConfig)
}
else {
  $text = Get-Content -LiteralPath $subagentConfig -Raw
  $binary = Get-SubagentBinaryFromToml -Text $text
  $template = Join-Path -Path $PSScriptRoot -ChildPath 'templates\subagent.toml'
  $isOurs = $false
  if ($binary -and (Test-Path -LiteralPath $template)) {
    $port = 0
    try {
      if (Test-Path -LiteralPath $script:Paths.Config) {
        $port = [int](Get-JsonProperty -Object (Read-LocalAgentConfig -Path $script:Paths.Config) -Name 'port')
      }
    }
    catch {
      $port = 0
    }
    $expected = ConvertTo-SubagentToml -Path $template -OmpBinary $binary -Port $port
    $actualNorm = ($text -replace "`r?`n", "`n").TrimEnd("`n")
    $expectedNorm = ($expected -replace "`r?`n", "`n").TrimEnd("`n")
    $isOurs = ($actualNorm -eq $expectedNorm)
  }
  if ($isOurs) {
    Remove-Item -LiteralPath $subagentConfig -Force
    Write-Uninstall ('subagent config removed (it is exactly what install.ps1 wrote): {0}' -f $subagentConfig)
  }
  else {
    Write-Uninstall ('subagent config KEPT (it is not the file install.ps1 writes, or the template is missing): {0}' -f $subagentConfig)
  }
}

$mcpResult = Remove-JsonObjectKey -Path $script:Paths.McpJson -ObjectKey 'servers' -Name ([string]$script:Constants.SubagentMcpName)
Write-Uninstall ('mcp.json: server "{0}" {1}.' -f $script:Constants.SubagentMcpName, $mcpResult)

# ---------------------------------------------------------------------------
# 5. Remove the PATH entry
# ---------------------------------------------------------------------------

$pathResult = Remove-UserPath -Dir $script:Paths.Bin
Write-Uninstall ('user PATH: {0} {1}.' -f $script:Paths.Bin, $pathResult)

# ---------------------------------------------------------------------------
# 6. Delete the install directory (models\ kept unless -RemoveModel)
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $script:Paths.InstallDir)) {
  Write-Uninstall ('install directory {0} does not exist; nothing to delete.' -f $script:Paths.InstallDir)
}
elseif ($RemoveModel) {
  Remove-Item -LiteralPath $script:Paths.InstallDir -Recurse -Force
  Write-Uninstall ('install directory removed, including the model: {0}' -f $script:Paths.InstallDir)
}
else {
  $children = @(Get-ChildItem -LiteralPath $script:Paths.InstallDir -Force | Where-Object { $_.Name -ne 'models' })
  foreach ($child in $children) {
    try {
      Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
    }
    catch {
      Write-Uninstall ('WARNING: could not remove {0}: {1}' -f $child.FullName, $_.Exception.Message)
    }
  }
  Write-Uninstall ('install directory cleaned; models\ kept: {0} (re-run with -RemoveModel to delete it).' -f $script:Paths.Models)
}

# ---------------------------------------------------------------------------
# 7. What was NOT touched
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'NOT touched by this uninstall:'
Write-Host ('  - the omp binary itself: {0} stays, and so does the {1} PATH entry (delete the folder and remove the entry by hand if you want it gone)' -f $script:Paths.OmpExe, $script:Paths.OmpDir)
Write-Host ('  - omp config files other than our keys (anything else in {0} stays)' -f $script:Paths.OmpAgentDir)
Write-Host '  - uv itself and the %USERPROFILE%\.local\bin PATH entry (other tools may live there)'
Write-Host '  - VS Code and its extensions (the Continue extension, if it was installed, stays)'
Write-Host '  - foreign entries in models.yml / config.yml / chatLanguageModels.json / mcp.json (they were kept)'
if (-not $RemoveModel) {
  Write-Host ('  - the model file: {0}' -f $script:Paths.ModelFile)
}
Write-Host ''
Write-Host 'uninstall done.'
exit 0
