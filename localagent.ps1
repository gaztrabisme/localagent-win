#Requires -Version 5.1
<#
.SYNOPSIS
  localagent CLI: control the local llama.cpp model server.

.DESCRIPTION
  Subcommands:
    serve      Foreground server for a manual run (the Scheduled Task runs
               llama-server.exe itself): keep the previous logs\server.log
               as server.1.log,
               start llama-server.exe with the argv built from config.json,
               wait on the process and exit with its code.
    start      Start the per-user logon task, then poll /health up to
               10 minutes.
    stop       Stop the task, then kill any llama-server.exe running from
               this install.
    restart    stop, re-register the task from config.json, start.
    status     Task state, /health, model alias from /props, PID, working
               set, config summary, and whether the subagent MCP server
               (install.ps1 -WithSubagent) is installed.
    logs       Tail logs\server.log (-Tail N, default 50).
    bench      Benchmark threads with llama-bench, write bench.json, set
               config threads to the fastest tg128 setting, re-register the
               task, start.
    config     Print the config.json path, open it in notepad and wait
               (unless -NonInteractive), then re-register the task so the
               next start uses the edited settings.
    model      Switch the served model: a Hugging Face "owner/repo:QUANT",
               a bare "owner/repo" (lists its .gguf files), a local .gguf
               path, a .gguf URL, --list, or default. Downloads, re-registers
               the task, restarts and prints tokens/s.

  Run `localagent <command> -?` or `localagent help` for this text.

.PARAMETER Command
  serve | start | stop | restart | status | logs | bench | config | model | help

.PARAMETER Target
  For `model`: what to switch to (see above).

.PARAMETER Alias
  For `model`: also change the served model alias (VS Code entry id and omp
  modelRoles follow). Default: keep the current alias.

.PARAMETER Force
  For `model`: switch even when the weights exceed total RAM minus 8 GB.

.PARAMETER List
  For `model`: same as `localagent model --list`.

.PARAMETER Tail
  Number of log lines for `logs` (default 50).

.PARAMETER NonInteractive
  Never open a window (config does not launch notepad).

.EXAMPLE
  localagent status
.EXAMPLE
  localagent start
.EXAMPLE
  localagent logs -Tail 200
.EXAMPLE
  localagent model unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'status',
  [Parameter(Position = 1)][string]$Target = '',
  [int]$Tail = 50,
  [string]$Alias = '',
  [switch]$Force,
  [switch]$List,
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# The installed layout is <InstallDir>\bin\localagent.ps1 with the module in
# <InstallDir>\lib\; running from the package root, the module is .\lib\.
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
$script:Constants = Get-LocalAgentConstants

function Write-Cli {
  # One timestamped console line (the CLI has no log file; the server has).
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
}

function Get-ServerExePath {
  # llama-server.exe (llama-cli.exe as fallback) inside <InstallDir>\llama.
  $exe = Join-Path -Path $script:Paths.Llama -ChildPath 'llama-server.exe'
  if (-not (Test-Path -LiteralPath $exe)) {
    $exe = Find-LlamaServerPath -Dir $script:Paths.Llama
  }
  if (-not $exe) {
    throw ('llama-server.exe not found under {0}; run install.ps1 first.' -f $script:Paths.Llama)
  }
  return $exe
}

function Get-ConfigOrThrow {
  if (-not (Test-Path -LiteralPath $script:Paths.Config)) {
    throw ('config.json not found at {0}; run install.ps1 first.' -f $script:Paths.Config)
  }
  return (Read-LocalAgentConfig -Path $script:Paths.Config)
}

function Update-ServerTask {
  # Re-registers the logon task from the current config.json.
  $task = Register-LocalAgentTask -InstallDir $script:Paths.InstallDir -ConfigPath $script:Paths.Config
  Write-Cli ('task "{0}" re-registered via {1} from {2}.' -f $script:Constants.TaskName, $task.Method, $script:Paths.Config)
}

function Invoke-ServerLogRotation {
  # llama-server truncates its --log-file when it opens it, so every start
  # from the CLI first moves the previous run's log to server.1.log (keep 3).
  New-Item -Path $script:Paths.Logs -ItemType Directory -Force | Out-Null
  if (Invoke-LogRotation -Path $script:Paths.ServerLog -MaxBytes 1) {
    Write-Cli 'previous server log kept as logs\server.1.log.'
  }
}

function Invoke-Serve {
  # Foreground: build argv from config.json (same as the task, including
  # --log-file), start llama-server in this console, wait, exit with its code.
  $serverExe = Get-ServerExePath
  $config = Get-ConfigOrThrow
  Invoke-ServerLogRotation

  $argv = ConvertTo-ServerArgs -Config $config -ModelPath $script:Paths.ModelFile -LogFile $script:Paths.ServerLog
  $argLine = ConvertTo-TaskArguments -Argv $argv -Raw
  Write-Cli ('serve: {0} {1}' -f $serverExe, $argLine)
  $proc = Start-Process -FilePath $serverExe -ArgumentList $argLine -WorkingDirectory $script:Paths.Llama -NoNewWindow -PassThru
  $null = $proc.Handle
  Write-Cli ('serve: llama-server pid {0}; logging to {1}' -f $proc.Id, $script:Paths.ServerLog)
  $proc.WaitForExit()
  $code = $proc.ExitCode
  Write-Cli ('serve: llama-server exited with code {0}' -f $code)
  exit $code
}

function Invoke-Start {
  # Start the Scheduled Task, then poll /health up to 10 minutes.
  $config = Get-ConfigOrThrow
  $port = [int]$config.port
  if (Test-LocalAgentHealth -Port $port) {
    Write-Cli ('server already up on port {0}.' -f $port)
    return
  }
  Invoke-ServerLogRotation
  try {
    Start-ScheduledTask -TaskName ([string]$script:Constants.TaskName) -ErrorAction Stop
  }
  catch {
    throw ('could not start the scheduled task "{0}": {1} (installed? run install.ps1 first.)' -f $script:Constants.TaskName, $_.Exception.Message)
  }
  Write-Cli ('task started; waiting for http://127.0.0.1:{0}/health (up to 10 minutes; first load reads ~23 GB)...' -f $port)
  if (-not (Wait-LocalAgentHealth -Port $port -TimeoutSeconds 600)) {
    throw ('server not healthy after 10 minutes; check {0}' -f $script:Paths.ServerLog)
  }
  Write-Cli ('server is up on port {0}.' -f $port)
}

function Invoke-Stop {
  # Stop the task (ignore "not registered"), then kill this install's
  # llama-server.exe processes.
  try {
    Stop-ScheduledTask -TaskName ([string]$script:Constants.TaskName) -ErrorAction Stop
    Write-Cli ('task "{0}" stopped.' -f $script:Constants.TaskName)
  }
  catch {
    Write-Cli ('task "{0}" not running or not registered; skipping.' -f $script:Constants.TaskName)
  }
  $procs = @(Get-ServerProcess)
  if ($procs.Count -eq 0) {
    Write-Cli 'no llama-server.exe from this install is running.'
    return
  }
  foreach ($proc in $procs) {
    try {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
      Write-Cli ('stopped llama-server pid {0}.' -f $proc.ProcessId)
    }
    catch {
      Write-Cli ('could not stop pid {0}: {1}' -f $proc.ProcessId, $_.Exception.Message)
    }
  }
}

function Invoke-Restart {
  Invoke-Stop
  Update-ServerTask
  Start-Sleep -Seconds 2
  Invoke-Start
}

function Invoke-Status {
  # Task state, /health, /props alias, PID + working set, config summary.
  $config = $null
  $port = [int]$script:Constants.Port
  if (Test-Path -LiteralPath $script:Paths.Config) {
    $config = Read-LocalAgentConfig -Path $script:Paths.Config
    $port = [int]$config.port
  }

  $taskState = 'not registered'
  try {
    $task = Get-ScheduledTask -TaskName ([string]$script:Constants.TaskName) -ErrorAction Stop
    $taskState = [string]$task.State
  }
  catch {
    $taskState = 'not registered'
  }

  $health = 'down'
  if (Test-LocalAgentHealth -Port $port) {
    $health = 'up (200)'
  }

  $alias = 'n/a'
  try {
    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/props' -f $port) -UseBasicParsing -TimeoutSec 3
    $props = ConvertFrom-Json -InputObject $resp.Content
    foreach ($key in @('model_alias', 'alias', 'model')) {
      $value = Get-JsonProperty -Object $props -Name $key
      if ($null -ne $value -and "$value" -ne '') {
        if ($key -eq 'model' -and "$value" -match '[\\/]') {
          $alias = [System.IO.Path]::GetFileName([string]$value)
        }
        else {
          $alias = [string]$value
        }
        break
      }
    }
  }
  catch {
    $alias = 'n/a (server down or /props unavailable)'
  }

  $procs = @(Get-ServerProcess)
  if ($procs.Count -gt 0) {
    $procText = ($procs | ForEach-Object { 'pid {0} ({1:n0} MB)' -f $_.ProcessId, $_.WorkingSetMB }) -join ', '
  }
  else {
    $procText = 'not running'
  }

  # The subagent MCP server (-WithSubagent): `uv tool list` names it when
  # installed. Any failure here degrades to a note, never a crash.
  $subagentState = 'not installed (install.ps1 -WithSubagent)'
  try {
    $uvCmd = Get-Command -Name 'uv.exe' -ErrorAction SilentlyContinue
    if (-not $uvCmd) {
      $uvCmd = Get-Command -Name 'uv' -ErrorAction SilentlyContinue
    }
    if ($uvCmd) {
      $toolList = (& $uvCmd.Source tool list | Out-String)
      if (Test-UvToolListText -Text $toolList -Name ([string]$script:Constants.SubagentToolName)) {
        $subagentState = 'installed (uv tool)'
      }
    }
    else {
      $uvShim = Join-Path -Path $script:Paths.UvBin -ChildPath 'uv.exe'
      if (Test-Path -LiteralPath $uvShim) {
        $toolList = (& $uvShim tool list | Out-String)
        if (Test-UvToolListText -Text $toolList -Name ([string]$script:Constants.SubagentToolName)) {
          $subagentState = 'installed (uv tool)'
        }
      }
    }
  }
  catch {
    $subagentState = 'unknown (uv tool list failed)'
  }

  Write-Host '---------------- localagent status ----------------'
  Write-Host ('  install dir : {0}' -f $script:Paths.InstallDir)
  Write-Host ('  task        : "{0}" is {1}' -f $script:Constants.TaskName, $taskState)
  Write-Host ('  health      : {0} (http://127.0.0.1:{1}/health)' -f $health, $port)
  Write-Host ('  model alias : {0}' -f $alias)
  if ($null -ne $config) {
    Write-Host ('  model file  : {0}' -f (Get-ActiveModelPath -Config $config))
  }
  Write-Host ('  process     : {0}' -f $procText)
  Write-Host ('  subagent    : {0}' -f $subagentState)
  if (Test-Path -LiteralPath $script:Paths.SubagentConfig) {
    Write-Host ('  subagent cfg: {0}' -f $script:Paths.SubagentConfig)
  }
  if ($null -ne $config) {
    Write-Host ('  config      : threads {0}, threads_batch {1}, ctx {2}, mtp {3}, n_predict {4}, alias "{5}"' -f `
        $config.threads, $config.threads_batch, $config.ctx, $config.mtp, $config.n_predict, $config.alias)
    Write-Host ('  config file : {0}' -f $script:Paths.Config)
  }
  else {
    Write-Host '  config      : MISSING (run install.ps1)'
  }
  Write-Host ('  server log  : {0}' -f $script:Paths.ServerLog)
  Write-Host '----------------------------------------------------'
}

function Invoke-Logs {
  # Tail logs\server.log.
  if (-not (Test-Path -LiteralPath $script:Paths.ServerLog)) {
    Write-Host ('no server log yet at {0}' -f $script:Paths.ServerLog)
    return
  }
  Get-Content -LiteralPath $script:Paths.ServerLog -Tail $Tail
}

function Invoke-Bench {
  # Stop, llama-bench -p 512 -n 128 -r 3 over a thread ladder, table +
  # bench.json, set config threads to the fastest tg128 row, start again.
  $serverExe = Get-ServerExePath
  $benchExe = Join-Path -Path (Split-Path -Path $serverExe -Parent) -ChildPath 'llama-bench.exe'
  if (-not (Test-Path -LiteralPath $benchExe)) {
    throw ('llama-bench.exe not found next to the server ({0}); it ships in the same zip.' -f $benchExe)
  }
  $config = Get-ConfigOrThrow

  Invoke-Stop

  # Deduplicated thread ladder: 8, 16, 32, then the machine's physical cores.
  $ladder = @()
  foreach ($t in @(8, 16, 32, [int]$config.threads_batch)) {
    if ($t -gt 0) {
      $ladder = @($ladder) + @($t)
    }
  }
  $ladder = @($ladder | Sort-Object -Unique)
  $threadArg = $ladder -join ','

  $argLine = '-m "{0}" -p 512 -n 128 -t {1} -r 3 -o json' -f (Get-ActiveModelPath -Config $config), $threadArg
  Write-Cli ('bench: llama-bench {0}' -f $argLine)
  Write-Cli 'bench: this runs several real generations; expect a few minutes...'

  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $proc = Start-Process -FilePath $benchExe -ArgumentList $argLine -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = Get-Content -LiteralPath $outFile -Raw
    $stderr = Get-Content -LiteralPath $errFile -Raw
  }
  finally {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
  if ($proc.ExitCode -ne 0) {
    throw ('llama-bench exited with code {0}.' -f $proc.ExitCode)
  }

  $rows = ConvertFrom-LlamaBenchJson -Text $stdout
  if ($rows.Count -eq 0) {
    throw 'llama-bench produced no parsable JSON rows.'
  }

  [System.IO.File]::WriteAllText($script:Paths.BenchJson, $stdout)
  Write-Cli ('bench: raw JSON written to {0}' -f $script:Paths.BenchJson)
  Write-Host ''
  $rows | Select-Object -Property Test, NThreads, AvgTs | Format-Table -AutoSize
  Write-Host ''

  $systemInfo = @($stderr -split "`r?`n" | Where-Object { $_ -match 'system_info' })
  if ($systemInfo.Count -gt 0) {
    Write-Cli ('bench: {0}' -f $systemInfo[0].Trim())
  }
  else {
    Write-Cli 'bench: no system_info line in llama-bench output.'
  }

  $best = Select-FastestThreads -Rows $rows -Test 'tg128'
  if ($null -ne $best) {
    $config.threads = [int]$best
    Write-LocalAgentConfig -Config $config -Path $script:Paths.Config
    Write-Cli ('bench: fastest tg128 at {0} threads; config.json updated.' -f $best)
  }
  else {
    Write-Cli 'bench: no tg128 rows found; config threads left unchanged.'
  }

  Update-ServerTask
  Invoke-Start
}

function Invoke-ConfigCommand {
  # Print the path; unless -NonInteractive, open notepad and wait for it to
  # close; then re-register the task so the next start uses the file.
  Write-Host $script:Paths.Config
  if (-not (Test-Path -LiteralPath $script:Paths.Config)) {
    Write-Host '(the file does not exist yet; run install.ps1)'
    return
  }
  if (-not $NonInteractive) {
    Write-Cli 'opening config.json in notepad; close notepad to apply the changes to the task...'
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:Paths.Config) -Wait | Out-Null
  }
  $null = Get-ConfigOrThrow
  Update-ServerTask
  Write-Cli 'run `localagent restart` to load the new settings now.'
}

function Get-ActiveModelPath {
  # config.model when set (localagent model), else the shipped file.
  param([Parameter(Mandatory)][psobject]$Config)
  $value = Get-JsonProperty -Object $Config -Name 'model'
  if ($null -ne $value -and "$value" -ne '') {
    return [string]$value
  }
  return $script:Paths.ModelFile
}

function Format-GB {
  param([long]$Bytes)
  return ('{0:n1} GB' -f ($Bytes / 1GB))
}

function Get-HfHeaders {
  # Authorization for gated repos when HF_TOKEN is set.
  $headers = @{}
  if ("$env:HF_TOKEN" -ne '') {
    $headers['Authorization'] = 'Bearer ' + $env:HF_TOKEN
  }
  return $headers
}

function Get-HfTree {
  # GET /api/models/<repo>/tree/main?recursive=true, following the Link:
  # rel="next" pages. Returns the entry objects.
  param([Parameter(Mandatory)][string]$Repo)
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $url = 'https://huggingface.co/api/models/{0}/tree/main?recursive=true' -f $Repo
  $headers = Get-HfHeaders
  $entries = @()
  while ($url) {
    try {
      $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 60
    }
    catch {
      $hint = ''
      if ("$env:HF_TOKEN" -eq '') {
        $hint = ' (a gated or private repo needs $env:HF_TOKEN)'
      }
      throw ('could not list {0} on Hugging Face: {1}{2}' -f $Repo, ($_.Exception.Message -replace "`r?`n", ' '), $hint)
    }
    # PS 5.1 emits a parsed JSON array as one object; foreach unrolls it.
    $parsed = ConvertFrom-Json -InputObject $resp.Content
    foreach ($entry in $parsed) {
      $entries = @($entries) + @($entry)
    }
    $url = $null
    $link = [string]$resp.Headers['Link']
    $m = [regex]::Match($link, '<([^>]+)>;\s*rel="next"')
    if ($m.Success) {
      $url = $m.Groups[1].Value
    }
  }
  return $entries
}

function Show-GgufSets {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sets)
  foreach ($set in $Sets) {
    $parts = ''
    if (@($set.Files).Count -gt 1) {
      $parts = ' ({0} parts)' -f @($set.Files).Count
    }
    Write-Host ('  {0,9}  {1}{2}' -f (Format-GB -Bytes $set.TotalBytes), $set.Files[0].Path, $parts)
  }
}

function Assert-ModelFits {
  param([Parameter(Mandatory)][long]$Bytes)
  $ram = Get-TotalRamBytes
  if ($ram -le 0) {
    Write-Cli 'could not read the total RAM; skipping the RAM check.'
    return
  }
  if (Test-ModelFitsRam -ModelBytes $Bytes -TotalRamBytes $ram) {
    Write-Cli ('RAM check: {0} of weights, {1} RAM: fits (limit is RAM minus 8 GB).' -f (Format-GB -Bytes $Bytes), (Format-GB -Bytes $ram))
    return
  }
  if ($Force) {
    Write-Cli ('RAM check: {0} of weights, {1} RAM: does not fit; continuing because of -Force.' -f (Format-GB -Bytes $Bytes), (Format-GB -Bytes $ram))
    return
  }
  Write-Cli ('RAM check: {0} of weights, {1} RAM: does not fit (limit is RAM minus 8 GB). Use -Force to try anyway.' -f (Format-GB -Bytes $Bytes), (Format-GB -Bytes $ram))
  exit 1
}

function Save-ModelFile {
  # One file into Dir via a .downloading temp name; skipped when already
  # there with the expected size (and hash, when one is known).
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Target,
    [long]$Size = 0,
    [string]$Sha256 = ''
  )
  if (Test-Path -LiteralPath $Target) {
    $len = (Get-Item -LiteralPath $Target).Length
    if ($Size -le 0 -or $len -eq $Size) {
      if ("$Sha256" -eq '') {
        Write-Cli ('already downloaded: {0}' -f $Target)
        return
      }
      Write-Cli ('verifying the existing {0} ...' -f (Split-Path -Path $Target -Leaf))
      $hash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
      if ([string]::Equals($hash, $Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Cli ('already downloaded and verified: {0}' -f $Target)
        return
      }
    }
    Remove-Item -LiteralPath $Target -Force
  }
  $headerLines = @()
  $headers = Get-HfHeaders
  foreach ($k in $headers.Keys) {
    $headerLines = @($headerLines) + @(('{0}: {1}' -f $k, $headers[$k]))
  }
  $tmp = "$Target.downloading"
  Write-Cli ('downloading {0} ({1}) to {2}; an interrupted download resumes on re-run...' -f $Url, $(if ($Size -gt 0) { Format-GB -Bytes $Size } else { 'size unknown' }), $Target)
  Invoke-Download -Url $Url -OutFile $tmp -ExpectedSize $Size -ExpectedSha256 $Sha256 -Silent:$NonInteractive -Header $headerLines | Out-Null
  Move-Item -LiteralPath $tmp -Destination $Target -Force
  if ("$Sha256" -ne '') {
    Write-Cli 'download verified (size + SHA256).'
  }
}

function Set-ServedAlias {
  # Follow an alias change in VS Code (entry id) and omp (modelRoles); only
  # files that already exist are touched.
  param([Parameter(Mandatory)][string]$NewAlias)
  if (Test-Path -LiteralPath $script:Paths.ChatModelsJson) {
    $r = Merge-JsonArrayEntry -Path $script:Paths.ChatModelsJson -Entry (Get-VsCodeModelEntry -Alias $NewAlias)
    Write-Cli ('VS Code chatLanguageModels.json: model id "{0}" ({1}).' -f $NewAlias, $r)
  }
  if (Test-Path -LiteralPath $script:Paths.OmpConfigYml) {
    $r = Set-YamlTopLevelMap -Path $script:Paths.OmpConfigYml -Key 'modelRoles' -Values (Get-OmpModelRoles -ModelId ('llama.cpp/{0}' -f $NewAlias))
    Write-Cli ('omp config.yml modelRoles: llama.cpp/{0} ({1}).' -f $NewAlias, $r)
  }
}

function Wait-ModelServer {
  # Health within TimeoutSeconds; gives up early when no llama-server from
  # this install has been running for three polls in a row (a load error).
  param([int]$Port, [int]$TimeoutSeconds)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $started = Get-Date
  $gone = 0
  while ((Get-Date) -lt $deadline) {
    if (Test-LocalAgentHealth -Port $Port) {
      return $true
    }
    if (((Get-Date) - $started).TotalSeconds -gt 15) {
      if (@(Get-ServerProcess).Count -eq 0) { $gone++ } else { $gone = 0 }
      if ($gone -ge 3) {
        return $false
      }
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Start-ModelServer {
  # Re-register the task from config.json, start it, wait for health.
  # Returns this run's server.log lines when the server did not come up
  # (the log was rotated just before the start).
  param([Parameter(Mandatory)][long]$ModelBytes)
  $config = Get-ConfigOrThrow
  $port = [int]$config.port
  Invoke-Stop
  Update-ServerTask
  Invoke-ServerLogRotation
  Start-ScheduledTask -TaskName ([string]$script:Constants.TaskName)
  $timeout = Get-ModelLoadTimeout -ModelBytes $ModelBytes
  Write-Cli ('task started; waiting up to {0} s for http://127.0.0.1:{1}/health ...' -f $timeout, $port)
  if (Wait-ModelServer -Port $port -TimeoutSeconds $timeout) {
    return $null
  }
  $lines = @()
  if (Test-Path -LiteralPath $script:Paths.ServerLog) {
    $lines = @(Get-Content -LiteralPath $script:Paths.ServerLog)
  }
  return ,$lines
}

function Measure-TokensPerSecond {
  # One 64-token chat completion; prints and returns timings.predicted_per_second.
  param([Parameter(Mandatory)][psobject]$Config)
  $body = @{
    model      = [string]$Config.alias
    messages   = @(@{ role = 'user'; content = 'Write two sentences about the sea.' })
    max_tokens = 64
  }
  $json = ConvertTo-Json -InputObject $body -Depth 6
  try {
    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/v1/chat/completions' -f [int]$Config.port) -Method Post -Body $json `
      -ContentType 'application/json' -UseBasicParsing -TimeoutSec 600
  }
  catch {
    Write-Cli ('speed check failed: {0}' -f ($_.Exception.Message -replace "`r?`n", ' '))
    return $null
  }
  $tps = Get-SmokeTimingsPerSecond -ResponseText $resp.Content
  if ($null -ne $tps) {
    Write-Cli ('generation speed: {0:n1} tokens/s (64-token completion)' -f $tps)
  }
  else {
    Write-Cli 'generation speed: no timings in the response.'
  }
  return $tps
}

function Invoke-ModelList {
  $config = Get-ConfigOrThrow
  $active = Get-ActiveModelPath -Config $config
  Write-Host ('models in {0} (* = active):' -f $script:Paths.Models)
  $files = @(Get-ChildItem -LiteralPath $script:Paths.Models -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
  foreach ($f in $files) {
    $mark = ' '
    if ([string]::Equals($f.FullName, $active, [System.StringComparison]::OrdinalIgnoreCase)) {
      $mark = '*'
    }
    Write-Host ('  {0} {1,9}  {2}' -f $mark, (Format-GB -Bytes $f.Length), $f.FullName.Substring($script:Paths.Models.Length).TrimStart('\'))
  }
  if (-not ($files | Where-Object { [string]::Equals($_.FullName, $active, [System.StringComparison]::OrdinalIgnoreCase) })) {
    Write-Host ('  * (outside models\) {0}' -f $active)
  }
}

function Invoke-Model {
  # PowerShell binds `--list` to -List, so it never reaches $Target.
  if ($List) {
    $Target = '--list'
  }
  $spec = Resolve-ModelSpec -Spec $Target
  if ($spec.Kind -eq 'invalid') {
    Write-Host 'usage: localagent model owner/repo:QUANT | owner/repo | C:\path\file.gguf | https://.../file.gguf | --list | default   [-Alias name] [-Force]'
    exit 1
  }
  if ($spec.Kind -eq 'list') {
    Invoke-ModelList
    return
  }
  $config = Get-ConfigOrThrow
  $modelPath = ''
  $bytes = [long]0

  switch ($spec.Kind) {
    'default' {
      $modelPath = ''
      $bytes = [long]$script:Constants.ModelSize
      if (-not (Test-Path -LiteralPath $script:Paths.ModelFile)) {
        throw ('the shipped model is missing ({0}); run install.ps1 again.' -f $script:Paths.ModelFile)
      }
    }
    'local' {
      if (-not (Test-Path -LiteralPath $spec.Value)) {
        throw ('no such file: {0}' -f $spec.Value)
      }
      $modelPath = (Resolve-Path -LiteralPath $spec.Value).ProviderPath
      $bytes = (Get-Item -LiteralPath $modelPath).Length
      $m = [regex]::Match($modelPath, '^(.*)-00001-of-(\d{5})\.gguf$')
      if ($m.Success) {
        $bytes = [long]0
        foreach ($part in @(Get-ChildItem -Path ('{0}-*-of-{1}.gguf' -f $m.Groups[1].Value, $m.Groups[2].Value) -File)) {
          $bytes += $part.Length
        }
      }
      Write-Cli ('using the local file in place (no copy): {0}' -f $modelPath)
      Assert-ModelFits -Bytes $bytes
    }
    'url' {
      $leaf = [System.Uri]::UnescapeDataString(([uri]$spec.Value).Segments[-1])
      if ($leaf -notmatch '(?i)\.gguf$') {
        throw ('the URL does not end in a .gguf file name: {0}' -f $spec.Value)
      }
      $dir = Join-Path -Path $script:Paths.Models -ChildPath 'url'
      New-Item -Path $dir -ItemType Directory -Force | Out-Null
      $modelPath = Join-Path -Path $dir -ChildPath $leaf
      $size = [long]0
      try {
        $head = Invoke-WebRequest -Uri $spec.Value -Method Head -Headers (Get-HfHeaders) -UseBasicParsing -TimeoutSec 60
        $size = [long]$head.Headers['Content-Length']
      }
      catch {
        $size = [long]0
      }
      if ($size -gt 0) {
        Assert-ModelFits -Bytes $size
      }
      Write-Cli 'NOTE: a URL download is not hash-pinned; only its size is checked when the server reports one.'
      Save-ModelFile -Url $spec.Value -Target $modelPath -Size $size
      $bytes = (Get-Item -LiteralPath $modelPath).Length
      if ($size -le 0) {
        Assert-ModelFits -Bytes $bytes
      }
    }
    'hf' {
      Write-Cli ('listing {0} on Hugging Face...' -f $spec.Repo)
      $tree = @(Get-HfTree -Repo $spec.Repo)
      if ("$($spec.Quant)" -eq '') {
        $sets = @(Get-HfGgufSets -Tree $tree)
        Write-Host ('{0}: {1} model file set(s). Pick one with localagent model {0}:<QUANT>' -f $spec.Repo, $sets.Count)
        Show-GgufSets -Sets $sets
        return
      }
      $pick = Select-HfGgufFiles -Tree $tree -Quant $spec.Quant
      if ($pick.Status -ne 'ok') {
        if ($pick.Status -eq 'none') {
          Write-Host ('no .gguf in {0} matches "{1}". Available:' -f $spec.Repo, $spec.Quant)
        }
        else {
          Write-Host ('"{0}" matches more than one file set in {1}; use a longer tag:' -f $spec.Quant, $spec.Repo)
        }
        Show-GgufSets -Sets @($pick.Candidates)
        exit 1
      }
      $bytes = [long]$pick.TotalBytes
      Assert-ModelFits -Bytes $bytes
      $dir = Join-Path -Path $script:Paths.Models -ChildPath (Get-HfModelDirName -Repo $spec.Repo)
      New-Item -Path $dir -ItemType Directory -Force | Out-Null
      $drive = Get-PSDrive -Name ($dir.Substring(0, 1)) -ErrorAction SilentlyContinue
      if ($drive -and $drive.Free -lt $bytes) {
        $have = [long]0
        foreach ($f in $pick.Files) {
          $t = Join-Path -Path $dir -ChildPath (($f.Path -split '/')[-1])
          if (Test-Path -LiteralPath $t) { $have += (Get-Item -LiteralPath $t).Length }
        }
        if ($drive.Free -lt ($bytes - $have)) {
          throw ('not enough disk: {0} needed, {1} free on {2}:' -f (Format-GB -Bytes ($bytes - $have)), (Format-GB -Bytes $drive.Free), $drive.Name)
        }
      }
      $first = $true
      foreach ($f in $pick.Files) {
        $leaf = ($f.Path -split '/')[-1]
        $target = Join-Path -Path $dir -ChildPath $leaf
        $encoded = (($f.Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $url = 'https://huggingface.co/{0}/resolve/main/{1}' -f $spec.Repo, $encoded
        Save-ModelFile -Url $url -Target $target -Size ([long]$f.Size) -Sha256 ([string]$f.Sha256)
        if ($first) {
          $modelPath = $target
          $first = $false
        }
      }
    }
  }

  # Point config.json at the model (model default: back to the shipped
  # file, MTP on, the default alias).
  if ($null -ne $config.PSObject.Properties['model']) {
    $config.PSObject.Properties.Remove('model')
  }
  if ($modelPath -ne '') {
    $config | Add-Member -NotePropertyName 'model' -NotePropertyValue $modelPath -Force
  }
  $newAlias = [string]$config.alias
  if ($spec.Kind -eq 'default') {
    $config.mtp = $true
    $newAlias = [string]$script:Constants.Alias
  }
  if ("$Alias" -ne '') {
    $newAlias = $Alias
  }
  if ($newAlias -ne [string]$config.alias) {
    $config.alias = $newAlias
    Set-ServedAlias -NewAlias $newAlias
  }
  Write-LocalAgentConfig -Config $config -Path $script:Paths.Config
  Write-Cli ('config.json: model {0}, alias "{1}", mtp {2}.' -f (Get-ActiveModelPath -Config $config), $config.alias, $config.mtp)

  $failLines = Start-ModelServer -ModelBytes $bytes
  if ($null -ne $failLines -and $config.mtp -and (Test-MtpLoadError -Lines $failLines)) {
    Write-Cli 'this model has no MTP head; running without.'
    $config.mtp = $false
    Write-LocalAgentConfig -Config $config -Path $script:Paths.Config
    $failLines = Start-ModelServer -ModelBytes $bytes
  }
  if ($null -ne $failLines) {
    Write-Host '--- last server.log lines ---'
    @($failLines) | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    throw ('the server did not become healthy with {0}; `localagent model default` goes back to the shipped model.' -f (Get-ActiveModelPath -Config $config))
  }
  Write-Cli ('server is up with {0}.' -f (Get-ActiveModelPath -Config $config))
  Measure-TokensPerSecond -Config $config | Out-Null
}

function Show-CliHelp {
  Write-Host @'
localagent - control the local llama.cpp model server

  localagent serve      foreground server for a manual run
  localagent start      start the task, wait for /health (up to 10 min)
  localagent stop       stop the task and kill this install's llama-server
  localagent restart    stop, re-register the task from config.json, start
  localagent status     task state, health, alias, pid, config summary,
                        subagent MCP server installed or not
  localagent logs       tail logs\server.log           [-Tail N, default 50]
  localagent bench      find the fastest thread count, save it in config
  localagent config     print config.json path, open it in notepad, then
                        re-register the task (restart to apply)
  localagent model X    switch models; X is one of
                          owner/repo:QUANT    Hugging Face repo and quant
                          owner/repo          list that repo's .gguf files
                          C:\path\file.gguf   a local file (used in place)
                          https://.../x.gguf  a URL (not hash-pinned)
                          --list              models\ contents, * = active
                          default             back to the shipped model
                        [-Alias name] [-Force (skip the RAM check)]

'@
}

switch ($Command) {
  'serve'   { Invoke-Serve }
  'start'   { Invoke-Start }
  'stop'    { Invoke-Stop }
  'restart' { Invoke-Restart }
  'status'  { Invoke-Status }
  'logs'    { Invoke-Logs }
  'bench'   { Invoke-Bench }
  'config'  { Invoke-ConfigCommand }
  'model'   { Invoke-Model }
  'help'    { Show-CliHelp }
  default {
    Write-Host ("unknown command '{0}'" -f $Command)
    Show-CliHelp
    exit 1
  }
}

