#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the localagent package for the current user (no admin rights).

.DESCRIPTION
  Installs the Visual C++ runtime if the PC lacks it (the only system-wide
  step; may ask for administrator approval once), makes sure Python 3.10+
  and git are available (winget, else vendor installers), downloads and
  verifies llama.cpp + the Qwen3.6 GGUF model, writes config.json, installs
  the localagent CLI shim, registers the per-user logon Scheduled Task that
  serves the model on 127.0.0.1, wires up the omp coding agent and the VS
  Code editor integration, then runs smoke tests. Every step is logged to
  <InstallDir>\install.log; any failure prints one line naming the step.
  Windows PowerShell 5.1 compatible (also fine on 7).

  With -WithSubagent it also installs the subagent MCP server (per-user uv
  + the wheel from dist\), writes its config for the omp driver, and
  registers it in VS Code's mcp.json so Copilot agent mode gets a
  `delegate` tool. Without the switch none of that happens.

  Layout expected next to this script (the package):
    lib\localagent.psm1        helper module
    templates\task.xml         Scheduled Task definition
    templates\subagent.toml    subagent config template (-WithSubagent)
    dist\subagent-*.whl        the subagent wheel (-WithSubagent)
    localagent.ps1             the CLI (copied to <InstallDir>\bin)

.PARAMETER NonInteractive
  No prompts, no pauses; curl runs with --silent --show-error.

.PARAMETER ModelSource
  Path, UNC path or URL of the .gguf model. Default: the Hugging Face URL
  from Get-LocalAgentConstants. UNC/local paths are copied instead of
  downloaded.

.PARAMETER Editor
  copilot (default) | continue | none.

.PARAMETER InstallDir
  Package root. Default: $env:LOCALAPPDATA\localagent.

.PARAMETER SkipOmp
  Do not install/configure omp.

.PARAMETER SkipTools
  Do not install Python and git (Step-Tools); assume they are already there.

.PARAMETER SkipEditor
  Same as -Editor none.

.PARAMETER WithSubagent
  Also install the subagent MCP server and register it in VS Code.

.PARAMETER Threads
  Generation thread count for config.json. Default 16.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -NonInteractive
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -WithSubagent -NonInteractive
#>
[CmdletBinding()]
param(
  [switch]$NonInteractive,
  [string]$ModelSource = '',
  [ValidateSet('copilot', 'continue', 'none')][string]$Editor = 'copilot',
  [string]$InstallDir = '',
  [switch]$SkipOmp,
  [switch]$SkipTools,
  [switch]$SkipEditor,
  [switch]$WithSubagent,
  [int]$Threads = 16
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'lib\localagent.psm1') -Force

$script:Paths = $null
$script:LogPath = ''
$script:Config = $null
$script:Cores = 0
$script:SubagentInstalled = $false
$script:OmpExe = ''
$script:LlamaServerExe = ''

# ---------------------------------------------------------------------------
# Logging and step wrapper
# ---------------------------------------------------------------------------

function Write-Log {
  # One timestamped line to the console and to <InstallDir>\install.log.
  param([Parameter(Mandatory)][string]$Message)
  $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
  Write-Host $line
  if ($script:LogPath) {
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding ASCII
  }
}

function Invoke-Step {
  # Wraps one named step: logs start/end/duration; turns any exception into
  # a one-line failure naming the step, then rethrows for the top level.
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Log ('[step {0}] starting' -f $Name)
  try {
    & $Body
    Write-Log ('[step {0}] done ({1:n1}s)' -f $Name, $sw.Elapsed.TotalSeconds)
  }
  catch {
    $sw.Stop()
    $oneLine = ("{0}" -f $_.Exception.Message) -replace "`r?`n", ' '
    Write-Log ('[step {0}] FAILED after {1:n1}s: {2}' -f $Name, $sw.Elapsed.TotalSeconds, $oneLine)
    throw ("Step {0} failed: {1}" -f $Name, $oneLine)
  }
}

function Use-NativeOutput {
  # Runs a scriptblock with ErrorActionPreference=Continue so 2>&1 on native
  # commands cannot turn stderr lines into terminating errors (PS 5.1 quirk).
  param([Parameter(Mandatory)][scriptblock]$Body)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    return & $Body
  }
  finally {
    $ErrorActionPreference = $previous
  }
}

# ---------------------------------------------------------------------------
# Health checks (Test-LocalAgentHealth / Wait-LocalAgentHealth live in the
# module; shared with localagent.ps1)
# ---------------------------------------------------------------------------

function Test-ModelFile {
  # True when the model file exists with the expected byte size and SHA256.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][long]$Size,
    [Parameter(Mandatory)][string]$Sha256
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }
  if ((Get-Item -LiteralPath $Path).Length -ne $Size) {
    return $false
  }
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  return [string]::Equals($hash, $Sha256, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Step functions (thin; the heavy lifting lives in lib/localagent.psm1)
# ---------------------------------------------------------------------------

function Step-Preflight {
  # Spec step 1: machine summary table; hard stop on real blockers,
  # warning between 24 and 30 GB of RAM; curl.exe required;
  # winget/code recorded but not required.
  # A model already present with the right size only needs room for the rest of the install.
  $minDisk = 30
  if ((Test-Path $script:Paths.ModelFile) -and ((Get-Item $script:Paths.ModelFile).Length -eq (Get-LocalAgentConstants).ModelSize)) { $minDisk = 6 }
  $pf = Test-Preflight -MinRamGB 24 -MinDiskGB $minDisk -InstallDir $script:Paths.InstallDir

  $table = ($pf | Select-Object -Property Is64Bit, OsVersion, TotalRamGB, FreeDiskGB, PhysicalCores, HasCurl, HasWinget, HasCode, HasVcRuntime, HasPython, HasGit, Ok |
    Format-Table -AutoSize | Out-String)
  Write-Host $table
  Write-Log ('preflight summary: {0}' -f (($table -replace "`r?`n", ' | ').Trim()))

  if (-not $pf.Ok) {
    throw ('preflight failed: ' + ($pf.Problems -join ' '))
  }
  if (-not $pf.HasCurl) {
    throw 'preflight failed: curl.exe was not found (ships with Windows 10 1803+).'
  }
  if ($pf.PhysicalCores -lt 1) {
    throw 'preflight failed: could not read the physical core count (Win32_Processor NumberOfCores).'
  }
  if ($pf.TotalRamGB -lt 30) {
    Write-Log ('WARNING: total RAM {0} GB is below the recommended 30 GB; continuing (hard minimum 24 GB).' -f $pf.TotalRamGB)
  }

  if (-not $pf.HasVcRuntime) {
    Write-Log 'Visual C++ runtime not found in System32; step 2 will install it.'
  }
  if (-not $pf.HasPython) {
    Write-Log 'no usable Python 3.10+ on PATH (or only the Microsoft Store alias); step 3 will install it.'
  }
  if (-not $pf.HasGit) {
    Write-Log 'git not found; step 3 will install it.'
  }

  $script:Cores = [int]$pf.PhysicalCores
  Write-Log ('preflight OK: {0} physical cores, {1} GB RAM, {2} GB free on {3}' -f `
    $pf.PhysicalCores, $pf.TotalRamGB, $pf.FreeDiskGB, $script:Paths.InstallDir)
}

function Step-VcRuntime {
  # Step 2: Microsoft Visual C++ 2015-2022 x64 runtime. The llama.cpp
  # win-cpu zip links vcruntime140/msvcp140/vcruntime140_1 dynamically and
  # does not bundle them; a fresh Windows has none, and llama-server.exe
  # then exits with STATUS_DLL_NOT_FOUND. This is the one step that writes
  # outside the user profile, so it can raise a UAC prompt.
  if (Test-VcRuntime) {
    Write-Log 'Visual C++ runtime present (vcruntime140.dll, msvcp140.dll, vcruntime140_1.dll in System32); nothing to do.'
    return
  }
  $constants = Get-LocalAgentConstants
  $exe = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-vc_redist.x64.exe'
  Write-Log ('Visual C++ runtime missing; downloading {0} ...' -f $constants.VcRedistUrl)
  Invoke-Download -Url $constants.VcRedistUrl -OutFile $exe -Silent:$NonInteractive | Out-Null

  Write-Log 'running vc_redist.x64.exe /install /quiet /norestart (system-wide; on a non-admin account Windows asks for administrator approval once)...'
  try {
    $proc = Start-Process -FilePath $exe -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru
  }
  catch {
    throw ('could not run the Visual C++ runtime installer (administrator approval declined or unavailable?): {0}. Install "Microsoft Visual C++ 2015-2022 Redistributable (x64)" from {1} by hand and re-run.' -f ($_.Exception.Message -replace "`r?`n", ' '), $constants.VcRedistUrl)
  }
  $code = [int]$proc.ExitCode
  Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
  if (-not (Test-VcRedistExitCode -ExitCode $code)) {
    throw ('vc_redist.x64.exe exited with code {0}. Install "Microsoft Visual C++ 2015-2022 Redistributable (x64)" from {1} by hand and re-run.' -f $code, $constants.VcRedistUrl)
  }
  $meaning = 'installed'
  if ($code -eq 3010) { $meaning = 'installed, Windows wants a reboot later (not needed for the server)' }
  if ($code -eq 1638) { $meaning = 'a newer or equal version was already installed' }
  Write-Log ('vc_redist.x64.exe exit code {0}: {1}.' -f $code, $meaning)

  if (-not (Test-VcRuntime)) {
    throw 'the Visual C++ runtime installer reported success but vcruntime140.dll, msvcp140.dll or vcruntime140_1.dll is still missing from System32. Install "Microsoft Visual C++ 2015-2022 Redistributable (x64)" by hand, reboot, and re-run.'
  }
  Write-Log 'Visual C++ runtime verified in System32.'
}

function Test-ToolsPython {
  # True when a real (non-Store-alias) Python 3.10+ answers on PATH.
  # Test-PythonAvailable does the probing; wrapped here for readable logs.
  return (Test-PythonAvailable)
}

function Install-ToolViaWinget {
  # One winget install with 3 attempts, 30 s apart. Returns $true only when
  # an attempt exits 0. $LASTEXITCODE is left behind for the caller to log.
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Label
  )
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Log ('{0}: winget install attempt {1}/3 (id {2}, user scope)...' -f $Label, $attempt, $Id)
    # winget.exe is an App Execution Alias. In some contexts (an elevated
    # prompt on managed PCs) it exists on PATH but cannot start: "The process
    # has no package identity". Treat that as "no winget" and let the caller
    # fall back to the vendor installer; retrying cannot help.
    try {
      Use-NativeOutput { & winget.exe install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --scope user | Out-String } | Out-Null
    }
    catch {
      Write-Log ('{0}: winget.exe could not start ({1}); using the vendor installer instead.' -f $Label, $_.Exception.Message)
      return $false
    }
    $code = $LASTEXITCODE
    if ($code -eq 0) {
      Write-Log ('{0}: winget reported success (exit code 0).' -f $Label)
      return $true
    }
    Write-Log ('{0}: winget attempt {1} exited with code {2}.' -f $Label, $attempt, $code)
    if ($attempt -lt 3) {
      Write-Log ('{0}: waiting 30 s before the next winget attempt...' -f $Label)
      Start-Sleep -Seconds 30
    }
  }
  return $false
}

function Step-Tools {
  # Python 3.10+ and git: winget (user scope, 3 attempts) when available,
  # otherwise a vendor installer (Python's is NOT hash-pinned, git's is).
  # Afterwards the session PATH is refreshed from the registry so the later
  # steps (uv, subagent, smoke tests) see both tools. Skipped with -SkipTools.
  $constants = Get-LocalAgentConstants

  # --- Python ---------------------------------------------------------------
  if (Test-ToolsPython) {
    $resolved = (Get-Command -Name 'python' -ErrorAction SilentlyContinue).Source
    Write-Log ('python already usable: {0} (>= {1})' -f $resolved, $constants.PythonMinVersion)
  }
  else {
    Write-Log ('python is missing or is only the Microsoft Store alias; installing {0} ...' -f $constants.PythonWingetId)
    if (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue) {
      Install-ToolViaWinget -Id $constants.PythonWingetId -Label 'python' | Out-Null
      Update-SessionPath
    }
    else {
      Write-Log 'python: winget.exe not found; using the vendor installer fallback.'
    }
    if (-not (Test-ToolsPython)) {
      Write-Log ('python still missing after winget; falling back to the python.org installer {0}' -f $constants.PythonFallbackUrl)
      Write-Log 'NOTE: this python.org fallback download is NOT hash-pinned (python.org publishes no per-file checksums on a stable URL); winget is the preferred path.'
      $exe = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-python-3.12.14-amd64.exe'
      Invoke-Download -Url $constants.PythonFallbackUrl -OutFile $exe -Silent:$NonInteractive | Out-Null
      Write-Log 'running python-3.12.14-amd64.exe /quiet InstallAllUsers=0 PrependPath=1 Include_test=0 (per-user)...'
      $proc = Start-Process -FilePath $exe -ArgumentList @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_test=0') -Wait -PassThru
      $code = [int]$proc.ExitCode
      Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
      if ($code -ne 0) {
        throw ('the python.org installer exited with code {0}.' -f $code)
      }
      Update-SessionPath
    }
    if (-not (Test-ToolsPython)) {
      throw ('python is still not usable after both install attempts (winget id {0}, python.org fallback). Install Python 3.10+ from https://www.python.org/downloads/ and re-run.' -f $constants.PythonWingetId)
    }
    $resolved = (Get-Command -Name 'python' -ErrorAction SilentlyContinue).Source
    Write-Log ('python installed and usable: {0}' -f $resolved)
  }

  # --- git ------------------------------------------------------------------
  if (Test-GitAvailable) {
    $resolved = (Get-Command -Name 'git' -ErrorAction SilentlyContinue).Source
    Write-Log ('git already usable: {0}' -f $resolved)
  }
  else {
    Write-Log ('git is missing; installing {0} ...' -f $constants.GitWingetId)
    if (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue) {
      Install-ToolViaWinget -Id $constants.GitWingetId -Label 'git' | Out-Null
      Update-SessionPath
    }
    else {
      Write-Log 'git: winget.exe not found; using the vendor installer fallback.'
    }
    if (-not (Test-GitAvailable)) {
      Write-Log ('git still missing after winget; falling back to the Git for Windows installer {0}' -f $constants.GitFallbackUrl)
      $exe = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-Git-2.55.0.5-64-bit.exe'
      Invoke-Download -Url $constants.GitFallbackUrl -OutFile $exe `
        -ExpectedSize $constants.GitSize -ExpectedSha256 $constants.GitSha256 `
        -Silent:$NonInteractive | Out-Null
      Write-Log 'running Git-2.55.0.5-64-bit.exe /VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS (per-user where the installer allows)...'
      $proc = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS') -Wait -PassThru
      $code = [int]$proc.ExitCode
      Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
      if ($code -ne 0) {
        throw ('the Git for Windows installer exited with code {0}.' -f $code)
      }
      Update-SessionPath
    }
    if (-not (Test-GitAvailable)) {
      throw 'git is still not usable after both install attempts (winget id Git.Git, Git for Windows fallback). Install git from https://git-scm.com/download/win and re-run.'
    }
    $resolved = (Get-Command -Name 'git' -ErrorAction SilentlyContinue).Source
    Write-Log ('git installed and usable: {0}' -f $resolved)
  }
}

function Step-Llama {
  # Spec step 2 (now 3/11): llama.cpp zip, verify, unzip, flatten, require AVX2.
  $constants = Get-LocalAgentConstants
  New-Item -Path $script:Paths.Llama -ItemType Directory -Force | Out-Null

  $serverExe = Find-LlamaServerPath -Dir $script:Paths.Llama
  if ($serverExe) {
    Write-Log ('llama.cpp binaries already present: {0}' -f $serverExe)
  }
  else {
    $zip = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-llama-b10757.zip'
    Write-Log ('downloading llama.cpp ({0} bytes)...' -f $constants.LlamaZipSize)
    Invoke-Download -Url $constants.LlamaZipUrl -OutFile $zip `
      -ExpectedSize $constants.LlamaZipSize -ExpectedSha256 $constants.LlamaZipSha256 `
      -Silent:$NonInteractive
    Expand-Archive -LiteralPath $zip -DestinationPath $script:Paths.Llama -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $serverExe = Find-LlamaServerPath -Dir $script:Paths.Llama
    if (-not $serverExe) {
      throw 'llama-server.exe (or llama-cli.exe) not found in the downloaded zip.'
    }
    # Flatten a zip layout that nests the binaries in a subfolder.
    $expected = Join-Path -Path $script:Paths.Llama -ChildPath 'llama-server.exe'
    if ($serverExe -ne $expected) {
      $srcDir = Split-Path -Path $serverExe -Parent
      Get-ChildItem -LiteralPath $srcDir -File | Move-Item -Destination $script:Paths.Llama -Force
      $serverExe = $expected
      Write-Log 'flattened nested zip layout so llama-server.exe sits in llama\.'
    }
  }

  $version = Invoke-NativeProbe -FilePath $serverExe -Arguments '--version' -TimeoutSeconds 60
  if ($version.TimedOut) {
    throw ('{0} --version did not exit within 60 seconds.' -f $serverExe)
  }
  if ($version.ExitCode -ne 0) {
    $hint = Get-NativeExitCodeHint -ExitCode $version.ExitCode
    if ($hint) {
      throw ('{0} --version failed: {1} (exit code {2})' -f $serverExe, $hint, $version.ExitCode)
    }
    throw ('{0} --version exited with code {1}. Output: {2}' -f $serverExe, $version.ExitCode, ($version.Output.Trim() -replace "`r?`n", ' | '))
  }
  Write-Log ('version output: {0}' -f (($version.Output.Trim() -replace "`r?`n", ' | ')))
  # CPU features (AVX2) are checked in Step-Task from server.log: llama-server
  # prints system_info only after a model is loaded.
  $script:LlamaServerExe = $serverExe
}

function Test-ServerCpuFeatures {
  # After the server is healthy: read the tail of server.log, log the
  # system_info and CPU backend lines, fail on AVX2 = 0. A missing
  # system_info line is a warning, not a failure.
  $log = $script:Paths.ServerLog
  if (-not (Test-Path -LiteralPath $log)) {
    Write-Log ('WARNING: {0} not found; cannot verify CPU features from the server log.' -f $log)
    return
  }
  $lines = @(Get-Content -LiteralPath $log -Tail 400 -ErrorAction SilentlyContinue)
  $cpu = Get-CpuInfoFromServerLog -Lines $lines
  if ($cpu.Backend) {
    Write-Log ('CPU backend: {0}' -f $cpu.Backend)
  }
  if (-not $cpu.SystemInfo) {
    Write-Log 'WARNING: no system_info line in the last 400 lines of server.log; CPU features not verified.'
    return
  }
  Write-Log ('CPU features: {0}' -f $cpu.SystemInfo)
  if (-not $cpu.HasAvx2) {
    throw 'the server reports AVX2 = 0; AVX2 is required for this model.'
  }
  $avx512 = '0'
  if ($cpu.Flags.ContainsKey('AVX512')) {
    $avx512 = [string]$cpu.Flags['AVX512']
  }
  Write-Log ('CPU features OK: AVX2 = 1, AVX512 = {0} (recorded, not required).' -f $avx512)
}

function Step-Model {
  # Spec step 3: model file via download (resumable) or path/UNC copy;
  # skipped when the file is already present with the right size and hash.
  $constants = Get-LocalAgentConstants
  $source = $constants.ModelUrl
  if ($ModelSource) {
    $source = $ModelSource
  }
  $target = $script:Paths.ModelFile
  $isUrl = ($source -match '^https?://')

  if (Test-ModelFile -Path $target -Size $constants.ModelSize -Sha256 $constants.ModelSha256) {
    Write-Log ('model already present and verified, skipping: {0}' -f $target)
    return
  }

  New-Item -Path $script:Paths.Models -ItemType Directory -Force | Out-Null
  $tmp = "$target.downloading"

  if ($isUrl) {
    Write-Log ('downloading model ({0} bytes) to {1}; an interrupted download resumes on re-run...' -f $constants.ModelSize, $tmp)
    Invoke-Download -Url $source -OutFile $tmp `
      -ExpectedSize $constants.ModelSize -ExpectedSha256 $constants.ModelSha256 `
      -Silent:$NonInteractive
    Move-Item -LiteralPath $tmp -Destination $target -Force
  }
  else {
    if (-not (Test-Path -LiteralPath $source)) {
      throw ("ModelSource '{0}' is neither a URL nor an existing file." -f $source)
    }
    Write-Log ('copying model from {0} to {1}...' -f $source, $target)
    if ($source -like '\\*') {
      & robocopy.exe (Split-Path -Path $source -Parent) $script:Paths.Models (Split-Path -Path $source -Leaf) /NFL /NDL /NJH /NJS | Out-Null
      if ($LASTEXITCODE -ge 8) {
        throw ('robocopy failed with exit code {0} for {1}.' -f $LASTEXITCODE, $source)
      }
      $copied = Join-Path -Path $script:Paths.Models -ChildPath (Split-Path -Path $source -Leaf)
      if ($copied -ne $target) {
        Move-Item -LiteralPath $copied -Destination $target -Force
      }
    }
    else {
      Copy-Item -LiteralPath $source -Destination $target -Force
    }
    if (-not (Test-ModelFile -Path $target -Size $constants.ModelSize -Sha256 $constants.ModelSha256)) {
      throw ('copied model failed verification (size/SHA256) from {0}.' -f $source)
    }
  }

  Write-Log ('model verified: {0} bytes, SHA256 OK.' -f $constants.ModelSize)
}

function Step-Config {
  # Spec step 4: config.json (threads = -Threads or 16, threads_batch =
  # physical cores) and a log line with the exact server argv.
  $config = New-LocalAgentConfig -PhysicalCores $script:Cores -Threads $Threads
  Write-LocalAgentConfig -Config $config -Path $script:Paths.Config
  $script:Config = $config

  $argv = ConvertTo-ServerArgs -Config $config -ModelPath $script:Paths.ModelFile -LogFile $script:Paths.ServerLog
  $script:ServerArgv = $argv
  Write-Log ('server command: llama-server.exe {0}' -f (ConvertTo-TaskArguments -Argv $argv -Raw))
  Write-Log ('config written: {0}' -f $script:Paths.Config)
}

function Step-Cli {
  # Spec step 5: localagent.ps1 + localagent.cmd shim into bin\, the module
  # into lib\ (the installed CLI imports ..\lib\localagent.psm1), the task
  # template into templates\ (the CLI re-registers the task from it), bin\
  # on the user PATH (registry + current session).
  $cliSource = Join-Path -Path $PSScriptRoot -ChildPath 'localagent.ps1'
  $shimSource = Join-Path -Path $PSScriptRoot -ChildPath 'localagent.cmd'
  $moduleSource = Join-Path -Path $PSScriptRoot -ChildPath 'lib\localagent.psm1'
  $taskSource = Join-Path -Path $PSScriptRoot -ChildPath 'templates\task.xml'
  foreach ($required in @($cliSource, $shimSource, $moduleSource, $taskSource)) {
    if (-not (Test-Path -LiteralPath $required)) {
      throw ('required package file was not found next to install.ps1 (the package is incomplete): {0}' -f $required)
    }
  }

  New-Item -Path $script:Paths.Bin -ItemType Directory -Force | Out-Null
  New-Item -Path (Join-Path -Path $script:Paths.InstallDir -ChildPath 'lib') -ItemType Directory -Force | Out-Null
  Copy-Item -LiteralPath $cliSource -Destination (Join-Path -Path $script:Paths.Bin -ChildPath 'localagent.ps1') -Force
  Copy-Item -LiteralPath $shimSource -Destination (Join-Path -Path $script:Paths.Bin -ChildPath 'localagent.cmd') -Force
  Copy-Item -LiteralPath $moduleSource -Destination (Join-Path -Path $script:Paths.InstallDir -ChildPath 'lib\localagent.psm1') -Force
  New-Item -Path $script:Paths.Templates -ItemType Directory -Force | Out-Null
  Copy-Item -LiteralPath $taskSource -Destination $script:Paths.TaskTemplate -Force

  $result = Add-UserPath -Dir $script:Paths.Bin -NoBroadcast
  Write-Log ('user PATH: {0} ({1})' -f $script:Paths.Bin, $result)
}

function Step-Task {
  # Spec step 6: per-user logon Scheduled Task that runs llama-server.exe
  # directly (Register-LocalAgentTask), then start it and wait up to 10
  # minutes for /health.
  $constants = Get-LocalAgentConstants
  $taskName = $constants.TaskName
  $template = Join-Path -Path $PSScriptRoot -ChildPath 'templates\task.xml'
  $task = Register-LocalAgentTask -InstallDir $script:Paths.InstallDir -ConfigPath $script:Paths.Config -TemplatePath $template
  Write-Log ('scheduled task "{0}" registered via {1} (user {2}): {3} {4}' -f $taskName, $task.Method, $task.User, $task.Execute, $task.Arguments)

  # llama-server truncates its --log-file on open; keep the previous run's.
  if (Invoke-LogRotation -Path $script:Paths.ServerLog -MaxBytes 1) {
    Write-Log 'previous server log kept as logs\server.1.log.'
  }
  Start-ScheduledTask -TaskName $taskName
  $port = [int](Get-JsonProperty -Object $script:Config -Name 'port')
  if ($port -le 0) {
    $port = $constants.Port
  }
  Write-Log ('task started; waiting up to 10 minutes for http://127.0.0.1:{0}/health (first load reads ~23 GB from disk)...' -f $port)
  if (-not (Wait-LocalAgentHealth -Port $port -TimeoutSeconds 600)) {
    throw ('the model server did not become healthy within 10 minutes; check {0}' -f $script:Paths.ServerLog)
  }
  Write-Log ('server healthy on port {0}.' -f $port)
  Test-ServerCpuFeatures
}

function Step-Omp {
  # omp 18.2.8: the release binary is downloaded straight into
  # %LOCALAPPDATA%\omp\omp.exe (no install script), verified against the
  # published size + SHA256, and its directory is added to the user PATH.
  # omp auto-discovers the llama-server on 127.0.0.1:8080 as its built-in
  # "llama.cpp" provider, so models.yml is not written at all any more;
  # config.yml only gets the modelRoles map and setupVersion: 2 (which
  # keeps the setup wizard from running).
  $constants = Get-LocalAgentConstants
  $alias = [string]$constants.Alias
  $ompExe = $script:Paths.OmpExe

  $present = $false
  if (Test-Path -LiteralPath $ompExe) {
    $hash = (Get-FileHash -LiteralPath $ompExe -Algorithm SHA256).Hash
    if ([string]::Equals($hash, $constants.OmpSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
      $present = $true
      Write-Log ('omp binary already present and verified: {0}' -f $ompExe)
    }
    else {
      Write-Log ("{0} exists but its SHA256 does not match the pinned omp {1}; replacing it." -f $ompExe, $constants.OmpRef)
    }
  }
  if (-not $present) {
    Write-Log ('downloading omp {0} ({1} bytes) to {2}...' -f $constants.OmpRef, $constants.OmpSize, $ompExe)
    Invoke-Download -Url $constants.OmpUrl -OutFile $ompExe `
      -ExpectedSize $constants.OmpSize -ExpectedSha256 $constants.OmpSha256 `
      -Silent:$NonInteractive | Out-Null
    Write-Log 'omp binary verified (size + SHA256).'
  }

  $pathResult = Add-UserPath -Dir $script:Paths.OmpDir -NoBroadcast
  Write-Log ('user PATH: {0} ({1})' -f $script:Paths.OmpDir, $pathResult)

  $otherOmp = Get-Command -Name 'omp' -ErrorAction SilentlyContinue
  if ($otherOmp -and $otherOmp.Source -and (-not $otherOmp.Source.StartsWith($script:Paths.OmpDir, [System.StringComparison]::OrdinalIgnoreCase))) {
    Write-Log ('NOTE: another omp is on this session''s PATH ({0}); the pinned {1} binary is {2} and whichever directory comes first in PATH wins.' -f $otherOmp.Source, $constants.OmpRef, $ompExe)
  }

  $modelId = 'llama.cpp/{0}' -f $alias
  $rolesResult = Set-YamlTopLevelMap -Path $script:Paths.OmpConfigYml -Key 'modelRoles' -Values (Get-OmpModelRoles -ModelId $modelId)
  Write-Log ('omp config.yml modelRoles: {0} ({1}).' -f $rolesResult, $modelId)

  $setupResult = Set-YamlScalar -Path $script:Paths.OmpConfigYml -Key 'setupVersion' -Value '2'
  Write-Log ('omp config.yml setupVersion: {0} (2; keeps the setup wizard quiet).' -f $setupResult)

  Write-Log 'NOTE: omp 18.2.8 ignores models.yml; an existing one (older install) is left alone and removed by uninstall.ps1.'

  $version = Invoke-NativeProbe -FilePath $ompExe -Arguments '--version' -TimeoutSeconds 120
  if ($version.TimedOut) {
    throw ('{0} --version did not exit within 120 seconds.' -f $ompExe)
  }
  if ($version.ExitCode -ne 0) {
    throw ('{0} --version exited with code {1}. Output: {2}' -f $ompExe, $version.ExitCode, ($version.Output.Trim() -replace "`r?`n", ' | '))
  }
  Write-Log ('omp version output: {0}' -f ($version.Output.Trim() -replace "`r?`n", ' | '))
  $script:OmpExe = $ompExe
}

function Step-Subagent {
  # Spec step 9 (-WithSubagent): the subagent MCP server. Installs uv
  # per-user from its pinned release zip when missing, installs the wheel as a uv tool, writes
  # %USERPROFILE%\.config\subagent\config.toml for the omp driver, registers
  # the MCP server in VS Code's mcp.json, then runs `subagent doctor --json`.
  $constants = Get-LocalAgentConstants

  # --- the wheel, staged into <InstallDir>\subagent
  $wheelSource = $null
  $wheels = @()
  $distDir = Join-Path -Path $PSScriptRoot -ChildPath 'dist'
  if (Test-Path -LiteralPath $distDir) {
    $wheels = @(Get-ChildItem -LiteralPath $distDir -Filter 'subagent-*.whl' -File -ErrorAction SilentlyContinue)
    if ($wheels.Count -eq 1) {
      $wheelSource = $wheels[0].FullName
    }
  }
  if (-not $wheelSource) {
    throw ('expected exactly one dist\subagent-*.whl next to install.ps1 (found {0}); build it with: uv build --wheel --out-dir dist' -f $wheels.Count)
  }
  New-Item -Path $script:Paths.Subagent -ItemType Directory -Force | Out-Null
  $wheel = Join-Path -Path $script:Paths.Subagent -ChildPath (Split-Path -Path $wheelSource -Leaf)
  Copy-Item -LiteralPath $wheelSource -Destination $wheel -Force
  Write-Log ('subagent wheel staged: {0}' -f $wheel)

  # --- uv, per-user: the pinned release zip, uv.exe + uvx.exe into
  # %USERPROFILE%\.local\bin (no install script is run)
  $uvCmd = Get-Command -Name 'uv.exe' -ErrorAction SilentlyContinue
  if (-not $uvCmd) {
    $uvCmd = Get-Command -Name 'uv' -ErrorAction SilentlyContinue
  }
  if (-not $uvCmd) {
    $zip = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-uv-x86_64-pc-windows-msvc.zip'
    $unpack = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'localagent-uv-unpack'
    Write-Log ('uv not found; downloading {0} ({1} bytes)...' -f $constants.UvZipUrl, $constants.UvZipSize)
    Invoke-Download -Url $constants.UvZipUrl -OutFile $zip `
      -ExpectedSize $constants.UvZipSize -ExpectedSha256 $constants.UvZipSha256 `
      -Silent:$NonInteractive | Out-Null
    Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
    New-Item -Path $script:Paths.UvBin -ItemType Directory -Force | Out-Null
    foreach ($name in @('uv.exe', 'uvx.exe')) {
      $hit = @(Get-ChildItem -LiteralPath $unpack -Recurse -Filter $name -File -ErrorAction SilentlyContinue) | Select-Object -First 1
      if (-not $hit) {
        throw ('{0} was not found in the uv zip {1}.' -f $name, $constants.UvZipUrl)
      }
      Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path -Path $script:Paths.UvBin -ChildPath $name) -Force
    }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue
    $pathResult = Add-UserPath -Dir $script:Paths.UvBin -NoBroadcast
    Write-Log ('uv.exe and uvx.exe placed in {0}; user PATH ({1}).' -f $script:Paths.UvBin, $pathResult)
    $uvExe = Join-Path -Path $script:Paths.UvBin -ChildPath 'uv.exe'
    $uvCmd = Get-Command -Name $uvExe -ErrorAction SilentlyContinue
    if (-not $uvCmd) {
      throw ('uv is still not resolvable after unpacking it to {0}.' -f $script:Paths.UvBin)
    }
  }
  Write-Log ('uv: {0}' -f $uvCmd.Source)

  # --- the tool (uv downloads a managed Python 3.12; no system Python needed)
  Write-Log ('installing the subagent tool: uv tool install --python {0} --force "{1}"' -f $constants.SubagentPython, $wheel)
  Use-NativeOutput { & $uvCmd.Source tool install --python $constants.SubagentPython --force $wheel 2>&1 | Out-String } | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw ('uv tool install exited with code {0}.' -f $LASTEXITCODE)
  }
  if (-not (Test-Path -LiteralPath $script:Paths.SubagentMcpExe)) {
    throw ('uv did not put subagent-mcp.exe at {0}; the MCP registration needs the full path.' -f $script:Paths.SubagentMcpExe)
  }
  Write-Log ('subagent tool installed; {0}' -f $script:Paths.SubagentMcpExe)
  $pathResult = Add-UserPath -Dir $script:Paths.UvBin -NoBroadcast
  Write-Log ('user PATH: {0} ({1})' -f $script:Paths.UvBin, $pathResult)

  # --- resolve omp by full path (this session may not have it on PATH yet)
  Update-SessionPath
  $omp = Find-OmpBinary
  if (-not $omp) {
    throw ('omp.exe was not found (Get-Command or {0}); run the omp step first or set [providers.local] binary by hand.' -f ((Get-OmpBinaryCandidates) -join ', '))
  }
  Write-Log ('omp binary: {0}' -f $omp)

  # --- the config (an existing [providers.local] is kept)
  $template = Join-Path -Path $PSScriptRoot -ChildPath 'templates\subagent.toml'
  $port = [int]$constants.Port
  $configPort = Get-JsonProperty -Object $script:Config -Name 'port'
  if ($configPort -and [int]$configPort -gt 0) {
    $port = [int]$configPort
  }
  $tomlResult = Set-SubagentToml -Path $script:Paths.SubagentConfig -TemplatePath $template -OmpBinary $omp -Port $port
  Write-Log ('subagent config: {0} ({1}; omp {2}, port {3})' -f $script:Paths.SubagentConfig, $tomlResult, $omp, $port)

  # --- register the MCP server in VS Code's mcp.json (other servers kept)
  $entry = [pscustomobject]@{
    type    = 'stdio'
    command = $script:Paths.SubagentMcpExe
    args    = @()
  }
  $mcpResult = Set-JsonObjectKey -Path $script:Paths.McpJson -ObjectKey 'servers' -Name ([string]$constants.SubagentMcpName) -Value $entry
  Write-Log ('mcp.json: {0} ({1})' -f $script:Paths.McpJson, $mcpResult)

  # --- smoke: doctor checks the omp binary and the llama-server health
  Write-Log 'smoke: subagent doctor --json (omp binary + llama-server health; no prompt run here)...'
  $probe = Invoke-NativeProbe -FilePath $script:Paths.SubagentExe -Arguments 'doctor --json' -TimeoutSeconds 300
  if ($probe.TimedOut) {
    throw 'subagent doctor did not exit within 300 seconds.'
  }
  $doctorText = ($probe.Output.Trim() -replace "`r?`n", ' | ')
  if ($probe.ExitCode -ne 0) {
    throw ('subagent doctor --json exited with code {0}: {1}' -f $probe.ExitCode, $doctorText)
  }
  Write-Log ('subagent doctor OK: {0}' -f $doctorText)
  $script:SubagentInstalled = $true
}

function Step-Editor {
  # Spec step 8: copilot -> chatLanguageModels.json merge; continue ->
  # extension install + config.yaml managed block.
  if ($Editor -eq 'none') {
    Write-Log 'editor integration disabled (-Editor none).'
    return
  }
  $hasCode = [bool](Get-Command -Name 'code' -ErrorAction SilentlyContinue)

  if ($Editor -eq 'copilot') {
    $fileExisted = Test-Path -LiteralPath $script:Paths.ChatModelsJson
    $mergeResult = Merge-JsonArrayEntry -Path $script:Paths.ChatModelsJson -Entry (Get-VsCodeModelEntry)
    Write-Log ('chatLanguageModels.json: {0}' -f $mergeResult)
    if (-not $fileExisted -and -not $hasCode) {
      Write-Log 'NOTE: VS Code was not found; chatLanguageModels.json was written anyway so the model appears when VS Code is installed later.'
    }
  }

  if ($Editor -eq 'continue') {
    if (-not $hasCode) {
      throw 'Editor=continue needs the VS Code `code` CLI, which was not found; use -Editor copilot or -Editor none.'
    }
    Use-NativeOutput { & code --install-extension Continue.continue | Out-String } | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw ('`code --install-extension Continue.continue` exited with code {0}.' -f $LASTEXITCODE)
    }
    $block = @(
      'models:',
      '  - name: Qwen3.6 35B-A3B (local CPU)',
      '    provider: openai',
      '    model: qwen3.6-35b-a3b',
      '    apiBase: http://127.0.0.1:8080/v1',
      '    apiKey: local',
      '    roles:',
      '      - chat',
      '      - edit',
      '      - apply'
    )
    $blockResult = Set-ManagedBlock -Path $script:Paths.ContinueConfig `
      -Begin '# >>> localagent' -End '# <<< localagent' -Content $block
    Write-Log ('continue config.yaml: {0}' -f $blockResult)
  }
}

function Step-Smoke {
  # Spec step 9: /health, a tool-call chat completion (get_weather), the
  # measured generation speed, and the omp one-shot prompt.
  $constants = Get-LocalAgentConstants
  $port = [int](Get-JsonProperty -Object $script:Config -Name 'port')
  if ($port -le 0) {
    $port = $constants.Port
  }

  if (-not (Test-LocalAgentHealth -Port $port)) {
    throw ('/health did not return 200 on port {0}.' -f $port)
  }
  Write-Log ('smoke: /health OK (200) on port {0}.' -f $port)

  $body = @{
    model       = [string]$constants.Alias
    messages    = @(
      @{ role = 'user'; content = "What's the weather in Hanoi? Use the tool." }
    )
    tools       = @(
      @{
        type     = 'function'
        function = @{
          name        = 'get_weather'
          description = 'Get the current weather for a city.'
          parameters  = @{
            type       = 'object'
            properties = @{
              city = @{ type = 'string' }
            }
            required   = @('city')
          }
        }
      }
    )
    tool_choice = 'auto'
    max_tokens  = 512
  }
  $json = ConvertTo-Json -InputObject $body -Depth 8
  Write-Log 'smoke: asking the model to call get_weather (thinking may be long; up to 5 minutes)...'
  $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/v1/chat/completions' -f $port) `
    -Method Post -Body $json -ContentType 'application/json' -UseBasicParsing -TimeoutSec 300
  if ($resp.StatusCode -ne 200) {
    throw ('chat completion returned HTTP {0}.' -f $resp.StatusCode)
  }
  $toolName = Get-SmokeToolCallName -ResponseText $resp.Content
  if ($toolName -ne 'get_weather') {
    $snippet = $resp.Content
    if ($snippet.Length -gt 300) {
      $snippet = $snippet.Substring(0, 300)
    }
    throw ("expected choices[0].message.tool_calls[0].function.name = 'get_weather' but got '{0}'. Response: {1}" -f $toolName, $snippet)
  }
  Write-Log 'smoke: tool call OK (get_weather).'

  $tps = Get-SmokeTimingsPerSecond -ResponseText $resp.Content
  if ($null -ne $tps) {
    Write-Log ('generation speed: {0:n1} tokens/sec' -f $tps)
  }
  else {
    Write-Log 'generation speed: no timings.predicted_per_second in the response.'
  }

  if (-not $SkipOmp) {
    $ompExe = $script:OmpExe
    if (-not $ompExe) {
      $ompExe = Find-OmpBinary
    }
    if (-not $ompExe) {
      Write-Log 'NOTE: omp executable not found in this session; skipping the omp smoke test.'
    }
    else {
      # omp 18.2.8 discovers the llama-server as its built-in "llama.cpp"
      # provider; pass the model explicitly so the one-shot never falls back
      # to a configured cloud model.
      $ompModel = 'llama.cpp/{0}' -f [string]$constants.Alias
      Write-Log ('smoke: running omp --model {0} --no-session -p "Reply with exactly: OK" (up to 600 s; the first omp prompt is about 20k tokens)...' -f $ompModel)
      $probe = Invoke-NativeProbe -FilePath $ompExe -Arguments ('--model {0} --no-session -p "Reply with exactly: OK"' -f $ompModel) -TimeoutSeconds 600 -EmptyStdin
      $text = ($probe.Output.Trim() -replace "`r?`n", ' | ')
      if ($probe.TimedOut) {
        throw ('omp smoke test timed out after 600 seconds. Output: {0}' -f $text)
      }
      if ($probe.ExitCode -ne 0) {
        throw ('omp smoke test failed (exit code {0}). Output: {1}' -f $probe.ExitCode, $text)
      }
      Write-Log ('smoke: omp OK: {0}' -f $text)
    }
  }
}

function Show-ReadyBlock {
  # Spec step 9 finale: the "ready" block, printed and logged.
  $constants = Get-LocalAgentConstants
  $lines = @(
    '==================================================================',
    ' localagent is ready',
    '==================================================================',
    ('  Model    : {0} on http://127.0.0.1:8080/v1 (alias "{1}", localhost only)' -f $constants.ModelFileName, $constants.Alias),
    '  omp      : open a NEW terminal and run: omp   (uses the local model, no flags)',
    '  Terminal already open? Paste this line first:',
    '             $env:PATH = "$env:LOCALAPPDATA\omp;$env:LOCALAPPDATA\localagent\bin;$env:PATH"',
    '  VS Code  : Copilot Chat model picker -> "Local Qwen3.6" (reload the window if it was open)',
    '  CLI      : localagent status | logs | bench | restart | stop   (new terminal)',
    ('  Logs     : {0}' -f $script:Paths.ServerLog),
    '  Uninstall: powershell -ExecutionPolicy Bypass -File uninstall.ps1',
    '=================================================================='
  )
  if ($script:SubagentInstalled) {
    $lines = @($lines) + @(
      '  MCP      : VS Code -> MCP servers -> "local-subagent" (Copilot agent mode gets a delegate tool)',
      ('             config: {0}; check: subagent doctor --json' -f $script:Paths.SubagentConfig)
    )
  }
  foreach ($line in $lines) {
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding ASCII
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
  if (-not $InstallDir) {
    $InstallDir = (Get-LocalAgentPaths).InstallDir
  }
  $script:Paths = Get-LocalAgentPaths -InstallDir $InstallDir
  foreach ($dir in @($script:Paths.InstallDir, $script:Paths.Models, $script:Paths.Bin, $script:Paths.Logs)) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
  }
  $script:LogPath = Join-Path -Path $script:Paths.InstallDir -ChildPath 'install.log'
  $script:StartedAt = Get-Date

  Write-Log ('install starting: NonInteractive={0}; Editor={1}; InstallDir={2}; SkipOmp={3}; SkipTools={4}; SkipEditor={5}; WithSubagent={6}; Threads={7}; ModelSource={8}' -f `
      $NonInteractive, $Editor, $script:Paths.InstallDir, $SkipOmp, $SkipTools, $SkipEditor, $WithSubagent, $Threads, $(if ($ModelSource) { $ModelSource } else { '(default HF url)' }))

  Invoke-Step '1/13 Preflight' { Step-Preflight }
  Invoke-Step '2/13 VcRuntime' { Step-VcRuntime }
  if ($SkipTools) {
    Write-Log '[step 3/13 Tools] skipped (-SkipTools)'
  }
  else {
    Invoke-Step '3/13 Tools' { Step-Tools }
  }
  Invoke-Step '4/13 Llama' { Step-Llama }
  Invoke-Step '5/13 Model' { Step-Model }
  Invoke-Step '6/13 Config' { Step-Config }
  Invoke-Step '7/13 Cli' { Step-Cli }
  Invoke-Step '8/13 Task' { Step-Task }
  if ($SkipOmp) {
    Write-Log '[step 9/13 Omp] skipped (-SkipOmp)'
  }
  else {
    Invoke-Step '9/13 Omp' { Step-Omp }
  }
  if ($WithSubagent) {
    Invoke-Step '10/13 Subagent' { Step-Subagent }
  }
  else {
    Write-Log '[step 10/13 Subagent] skipped (-WithSubagent not given)'
  }
  if ($SkipEditor -or $Editor -eq 'none') {
    Write-Log '[step 11/13 Editor] skipped (-SkipEditor / -Editor none)'
  }
  else {
    Invoke-Step '11/13 Editor' { Step-Editor }
  }
  Invoke-Step '12/13 Smoke' { Step-Smoke }
  Write-Log '[step 13/13 Ready]'
  # One WM_SETTINGCHANGE after all PATH edits: new terminals and Explorer
  # pick up the user PATH. Already-open terminals do not; the ready block
  # prints the line to paste there.
  Send-PathSettingChange
  Write-Log 'user PATH change broadcast to running programs (WM_SETTINGCHANGE).'
  Show-ReadyBlock
  Write-Log ('install finished OK in {0:n0}s; log: {1}' -f ((Get-Date) - $script:StartedAt).TotalSeconds, $script:LogPath)
  exit 0
}
catch {
  $oneLine = ("{0}" -f $_.Exception.Message) -replace "`r?`n", ' '
  Write-Host ''
  Write-Host ('INSTALL FAILED: {0}' -f $oneLine) -ForegroundColor Red
  Write-Host ('See the log for the failing step: {0}' -f $script:LogPath)
  if ($script:LogPath) {
    Add-Content -LiteralPath $script:LogPath -Value ('INSTALL FAILED: {0}' -f $oneLine) -Encoding ASCII
  }
  if (-not $NonInteractive) {
    Read-Host 'Press Enter to close' | Out-Null
  }
  exit 1
}
