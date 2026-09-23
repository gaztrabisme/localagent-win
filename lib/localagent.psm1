#Requires -Version 5.1
<#
.SYNOPSIS
  Pure helper functions for the localagent Windows package.

.DESCRIPTION
  Imported by install.ps1, localagent.ps1 and uninstall.ps1. Everything that
  can be tested without a live llama-server lives here: config to argv
  building, JSON merge helpers, YAML top-level map helpers, managed text
  blocks, preflight parsing and download verification. No state is kept in
  the module; side effects are limited to the files/registry the functions
  are told to touch.

  Written for Windows PowerShell 5.1 (no ternary operator, no null
  coalescing, no ConvertFrom-Json -AsHashtable, no pwsh-only cmdlets).
  ASCII only.
#>

# ---------------------------------------------------------------------------
# Internal helpers (not exported)
# ---------------------------------------------------------------------------

function ConvertTo-FsPath {
  # Resolves a PSDrive-qualified path (e.g. TestDrive:\x) to a real filesystem
  # path so [System.IO.File] calls work in tests.
  param([Parameter(Mandatory)][string]$Path)
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-InvariantString {
  # Formats a value with the invariant culture so argument building never
  # depends on the machine locale (0.6 must not become 0,6 on a German box).
  param([Parameter(Mandatory)][object]$Value)
  if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
    return ([double]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64]) {
    return ([long]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
  }
  return [string]$Value
}

function Write-TextFileUtf8 {
  # Writes an array of lines as UTF-8 without a BOM, CRLF line endings on
  # Windows. Avoids Set-Content -Encoding UTF8, which adds a BOM on 5.1.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
  )
  $fsPath = ConvertTo-FsPath -Path $Path
  $parent = Split-Path -Path $fsPath -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
  }
  [System.IO.File]::WriteAllLines($fsPath, $Lines)
}

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

function Get-LocalAgentPaths {
  <#
  .SYNOPSIS
    Returns every filesystem path the localagent package uses.

  .DESCRIPTION
    Single source of truth for install.ps1, localagent.ps1 and
    uninstall.ps1. OmpAgentDir, VsCodeUserDir, ContinueConfig, UvBin,
    SubagentConfig and SubagentMcpExe are fixed user-profile locations;
    everything else lives under InstallDir.

  .PARAMETER InstallDir
    Package root. Defaults to $env:LOCALAPPDATA\localagent.

  .OUTPUTS
    System.Collections.Hashtable

  .EXAMPLE
    $p = Get-LocalAgentPaths; $p.Config
  #>
  param([string]$InstallDir)

  if (-not $InstallDir) {
    $InstallDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'localagent'
  }
  $models = Join-Path -Path $InstallDir -ChildPath 'models'
  $logs = Join-Path -Path $InstallDir -ChildPath 'logs'
  $templates = Join-Path -Path $InstallDir -ChildPath 'templates'
  $ompAgentDir = Join-Path -Path $env:USERPROFILE -ChildPath '.omp\agent'
  $ompDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'omp'
  $vsCodeUserDir = Join-Path -Path $env:APPDATA -ChildPath 'Code\User'
  $uvBin = Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin'

  return @{
    InstallDir    = $InstallDir
    Llama         = Join-Path -Path $InstallDir -ChildPath 'llama'
    Models        = $models
    ModelFile     = Join-Path -Path $models -ChildPath (Get-LocalAgentConstants).ModelFileName
    Config        = Join-Path -Path $InstallDir -ChildPath 'config.json'
    Bin           = Join-Path -Path $InstallDir -ChildPath 'bin'
    Logs          = $logs
    ServerLog     = Join-Path -Path $logs -ChildPath 'server.log'
    Templates     = $templates
    TaskTemplate  = Join-Path -Path $templates -ChildPath 'task.xml'
    OmpDir        = $ompDir
    OmpExe        = Join-Path -Path $ompDir -ChildPath 'omp.exe'
    BenchJson     = Join-Path -Path $InstallDir -ChildPath 'bench.json'
    Subagent      = Join-Path -Path $InstallDir -ChildPath 'subagent'
    OmpAgentDir   = $ompAgentDir
    OmpModelsYml  = Join-Path -Path $ompAgentDir -ChildPath 'models.yml'
    OmpConfigYml  = Join-Path -Path $ompAgentDir -ChildPath 'config.yml'
    VsCodeUserDir = $vsCodeUserDir
    ChatModelsJson = Join-Path -Path $vsCodeUserDir -ChildPath 'chatLanguageModels.json'
    McpJson        = Join-Path -Path $vsCodeUserDir -ChildPath 'mcp.json'
    ContinueConfig = Join-Path -Path $env:USERPROFILE -ChildPath '.continue\config.yaml'
    UvBin          = $uvBin
    SubagentConfig = Join-Path -Path $env:USERPROFILE -ChildPath '.config\subagent\config.toml'
    SubagentMcpExe = Join-Path -Path $uvBin -ChildPath (Get-LocalAgentConstants).SubagentMcpExe
    SubagentExe    = Join-Path -Path $uvBin -ChildPath 'subagent.exe'
  }
}

function Get-LocalAgentConstants {
  <#
  .SYNOPSIS
    Returns the fixed download URLs, hashes, sizes and names of the package.

  .DESCRIPTION
    Hashes and sizes are the published values for the llama.cpp b10757
    CPU build and the Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL GGUF. Kept in one
    place so install/uninstall never drift apart.

  .OUTPUTS
    System.Collections.Hashtable

  .EXAMPLE
    $c = Get-LocalAgentConstants; $c.ModelUrl
  #>
  return @{
    LlamaZipUrl    = 'https://github.com/ggml-org/llama.cpp/releases/download/b10757/llama-b10757-bin-win-cpu-x64.zip'
    LlamaZipSha256 = '35692755857b0fed103b648d792e74ea8022dbe9519a0c1e5bf0b4ce51412bed'
    LlamaZipSize   = 18373860
    ModelUrl       = 'https://huggingface.co/havenoammo/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf'
    ModelSha256    = 'ab94e2da12d2bdc22777ba1b7422bbf8d5d9d0bee1164ca7343a0cee3310038a'
    ModelSize      = 23257919904
    ModelFileName  = 'Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf'
    OmpRef         = 'v18.2.8'
    OmpUrl         = 'https://github.com/can1357/oh-my-pi/releases/download/v18.2.8/omp-windows-x64.exe'
    OmpSha256      = 'b95431cb63b073c36c3664f6d9e2611de8d28d6e6e21ede657c8f83f0e7034b3'
    OmpSize        = 218729472
    VcRedistUrl    = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    PythonMinVersion = '3.10'
    PythonWingetId = 'Python.Python.3.12'
    PythonFallbackUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'
    PythonFallbackSha256 = '67b5635e80ea51072b87941312d00ec8927c4db9ba18938f7ad2d27b328b95fb'
    PythonFallbackSize = 26964224
    GitWingetId    = 'Git.Git'
    GitFallbackUrl = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe'
    GitSha256      = 'd065a4e23c3d9a6b5073d609b5be0830227ec3ca053c083ba385061ddfaf94c6'
    GitSize        = 65343712
    Alias          = 'qwen3.6-35b-a3b'
    Port           = 8080
    TaskName       = 'LocalAgent Server'
    VsCodeEntryName = 'Local Qwen3.6'
    UvZipUrl        = 'https://github.com/astral-sh/uv/releases/download/0.12.18/uv-x86_64-pc-windows-msvc.zip'
    UvZipSize       = 17891221
    UvZipSha256     = 'cae6a3bc25239f83dffb467a4b180508d9da23986c04639ebfa44e43e6a84bff'
    SubagentPython  = '3.12'
    SubagentToolName = 'subagent'
    SubagentMcpExe  = 'subagent-mcp.exe'
    SubagentMcpName = 'local-subagent'
    SubagentModel   = 'qwen3.6-35b-a3b'
  }
}

# ---------------------------------------------------------------------------
# Config object and server argv
# ---------------------------------------------------------------------------

function New-LocalAgentConfig {
  <#
  .SYNOPSIS
    Builds the default llama-server config object (spec step 4).

  .DESCRIPTION
    threads_batch is set to the machine's physical core count here. The
    shipped templates/config.json keeps "threads_batch": 0 as a placeholder
    meaning "physical cores" for the installer to fill in.

  .PARAMETER PhysicalCores
    Physical core count (Win32_Processor NumberOfCores, summed over sockets).

  .PARAMETER Threads
    Generation thread count. Default 16; install.ps1 -Threads overrides it.

  .OUTPUTS
    System.Management.Automation.PSCustomObject

  .EXAMPLE
    $cfg = New-LocalAgentConfig -PhysicalCores 64
  #>
  param(
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int]$PhysicalCores,
    [ValidateRange(1, 1024)][int]$Threads = 16
  )

  return [pscustomobject]@{
    port          = 8080
    host          = '127.0.0.1'
    threads       = $Threads
    threads_batch = $PhysicalCores
    ctx           = 131072
    parallel      = 1
    mtp           = $true
    mtp_draft_max = 3
    alias         = (Get-LocalAgentConstants).Alias
    n_predict     = 16384
    sampling      = [pscustomobject]@{
      temp             = 0.6
      top_p            = 0.95
      top_k            = 20
      min_p            = 0
      presence_penalty = 0
    }
    extra_args    = @()
  }
}

function ConvertTo-ServerArgs {
  <#
  .SYNOPSIS
    Builds the llama-server argv from a config object.

  .DESCRIPTION
    Returns the arguments exactly as the package spec lists them:
    -m/--host/--port/-t/-tb/-c/-np/--jinja/-fa on/--cache-reuse/-ctk/-ctv/
    sampling flags/-n/--alias, then the MTP flags when config.mtp is true,
    then --log-file/--log-timestamps/--log-colors off when -LogFile is
    given, then
    config.extra_args. The executable name is not included; the caller
    prepends the llama-server.exe path. All numbers are formatted with the
    invariant culture.

  .PARAMETER Config
    Config object as produced by New-LocalAgentConfig or Read-LocalAgentConfig.
    A non-empty config.model (set by `localagent model`) replaces ModelPath.

  .PARAMETER ModelPath
    Full path to the shipped .gguf model file.

  .PARAMETER LogFile
    When given, llama-server writes its log there (truncated at start) with
    timestamps and without ANSI colors:
    --log-file <LogFile> --log-timestamps --log-colors off.

  .OUTPUTS
    System.String[]

  .EXAMPLE
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath $p.ModelFile
  #>
  param(
    [Parameter(Mandatory)][psobject]$Config,
    [Parameter(Mandatory)][string]$ModelPath,
    [string]$LogFile = ''
  )

  $model = $ModelPath
  $configModel = $Config.PSObject.Properties['model']
  if ($null -ne $configModel -and "$($configModel.Value)" -ne '') {
    $model = [string]$configModel.Value
  }

  $argv = [System.Collections.Generic.List[string]]::new()
  $argv.Add('-m'); $argv.Add($model)
  $argv.Add('--host'); $argv.Add([string]$Config.host)
  $argv.Add('--port'); $argv.Add((ConvertTo-InvariantString -Value $Config.port))
  $argv.Add('-t'); $argv.Add((ConvertTo-InvariantString -Value $Config.threads))
  $argv.Add('-tb'); $argv.Add((ConvertTo-InvariantString -Value $Config.threads_batch))
  $argv.Add('-c'); $argv.Add((ConvertTo-InvariantString -Value $Config.ctx))
  $argv.Add('-np'); $argv.Add((ConvertTo-InvariantString -Value $Config.parallel))
  $argv.Add('--jinja')
  $argv.Add('-fa'); $argv.Add('on')
  $argv.Add('--cache-reuse'); $argv.Add('256')
  $argv.Add('-ctk'); $argv.Add('q8_0')
  $argv.Add('-ctv'); $argv.Add('q8_0')

  $sampling = $Config.sampling
  $argv.Add('--temp'); $argv.Add((ConvertTo-InvariantString -Value $sampling.temp))
  $argv.Add('--top-p'); $argv.Add((ConvertTo-InvariantString -Value $sampling.top_p))
  $argv.Add('--top-k'); $argv.Add((ConvertTo-InvariantString -Value $sampling.top_k))
  $argv.Add('--min-p'); $argv.Add((ConvertTo-InvariantString -Value $sampling.min_p))
  $argv.Add('--presence-penalty'); $argv.Add((ConvertTo-InvariantString -Value $sampling.presence_penalty))

  $argv.Add('-n'); $argv.Add((ConvertTo-InvariantString -Value $Config.n_predict))
  $argv.Add('--alias'); $argv.Add([string]$Config.alias)

  if ($Config.mtp) {
    $argv.Add('--spec-type'); $argv.Add('draft-mtp')
    $argv.Add('--spec-draft-n-max'); $argv.Add((ConvertTo-InvariantString -Value $Config.mtp_draft_max))
  }

  if ("$LogFile" -ne '') {
    $argv.Add('--log-file'); $argv.Add($LogFile)
    $argv.Add('--log-timestamps')
    $argv.Add('--log-colors'); $argv.Add('off')
  }

  if ($null -ne $Config.extra_args) {
    foreach ($extra in @($Config.extra_args)) {
      if ("$extra" -ne '') { $argv.Add([string]$extra) }
    }
  }

  return $argv.ToArray()
}

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

function Read-LocalAgentConfig {
  <#
  .SYNOPSIS
    Reads a localagent config.json into a PSCustomObject.

  .PARAMETER Path
    Path to the config.json file.

  .OUTPUTS
    System.Management.Automation.PSCustomObject

  .EXAMPLE
    $cfg = Read-LocalAgentConfig -Path $p.Config
  #>
  param([Parameter(Mandatory)][string]$Path)

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    throw "LocalAgent config not found: $Path"
  }
  $raw = Get-Content -LiteralPath $fsPath -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "LocalAgent config is empty: $Path"
  }
  try {
    return ConvertFrom-Json -InputObject $raw
  }
  catch {
    throw "LocalAgent config is not valid JSON: $Path ($_)"
  }
}

function Write-LocalAgentConfig {
  <#
  .SYNOPSIS
    Writes a config object as JSON (ConvertTo-Json -Depth 8).

  .DESCRIPTION
    Uses ConvertTo-Json -InputObject so an empty extra_args array survives
    as [] on PowerShell 5.1 (piping an empty array drops it). Written as
    UTF-8 without a BOM.

  .PARAMETER Config
    Config object (New-LocalAgentConfig / Read-LocalAgentConfig).

  .PARAMETER Path
    Destination config.json path. Parent folders are created if missing.

  .EXAMPLE
    Write-LocalAgentConfig -Config $cfg -Path $p.Config
  #>
  param(
    [Parameter(Mandatory)][psobject]$Config,
    [Parameter(Mandatory)][string]$Path
  )

  $json = ConvertTo-Json -InputObject $Config -Depth 8
  $fsPath = ConvertTo-FsPath -Path $Path
  $parent = Split-Path -Path $fsPath -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($fsPath, $json + [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

function Get-SystemFacts {
  <#
  .SYNOPSIS
    Internal: one small CIM/Get-Command probe of the machine.

  .DESCRIPTION
    Not exported. Kept separate from Test-Preflight so tests can Mock it
    (or pass the same shape of object through Test-Preflight -Facts).

  .PARAMETER InstallDir
    Determines which drive's free space is reported.

  .OUTPUTS
    System.Management.Automation.PSCustomObject with Is64Bit, OsVersion,
    TotalRamGB, FreeDiskGB, PhysicalCores, HasCurl, HasWinget, HasCode,
    HasVcRuntime, HasPython, HasGit.
  #>
  param([string]$InstallDir)

  if (-not $InstallDir) {
    $InstallDir = (Get-LocalAgentPaths).InstallDir
  }

  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)

  $freeDiskGB = 0
  $drive = $null
  if ($InstallDir -and $InstallDir.Length -ge 2 -and $InstallDir.Substring(1, 1) -eq ':') {
    $drive = $InstallDir.Substring(0, 2)
  }
  if ($drive) {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction SilentlyContinue
    if ($disk) {
      $freeDiskGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    }
  }

  $cores = 0
  $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
  if ($procs.Count -gt 0) {
    $sum = ($procs | Measure-Object -Property NumberOfCores -Sum).Sum
    if ($null -ne $sum) { $cores = [int]$sum }
  }

  return [pscustomobject]@{
    Is64Bit       = [Environment]::Is64BitOperatingSystem
    OsVersion     = [string]$os.Version
    TotalRamGB    = $totalRamGB
    FreeDiskGB    = $freeDiskGB
    PhysicalCores = $cores
    HasCurl       = [bool](Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue)
    HasWinget     = [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)
    HasCode       = [bool](Get-Command -Name 'code' -ErrorAction SilentlyContinue)
    HasVcRuntime  = (Test-VcRuntime)
    HasPython     = (Test-PythonAvailable)
    HasGit        = (Test-GitAvailable)
  }
}

function Test-VcRuntime {
  <#
  .SYNOPSIS
    True when the Visual C++ 2015-2022 x64 runtime DLLs are in System32.

  .DESCRIPTION
    llama.cpp's win-cpu build links vcruntime140.dll, msvcp140.dll and
    vcruntime140_1.dll dynamically and the release zip does not bundle
    them; a fresh Windows install has none of them, and llama-server.exe
    then dies with STATUS_DLL_NOT_FOUND (0xC0000135). All three must be
    present.

  .PARAMETER System32
    Directory to check. Defaults to $env:SystemRoot\System32 (tests point
    it at a temp folder).

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (-not (Test-VcRuntime)) { 'install vc_redist.x64.exe' }
  #>
  param([string]$System32)

  if (-not $System32) {
    $System32 = Join-Path -Path $env:SystemRoot -ChildPath 'System32'
  }
  foreach ($dll in (Get-VcRuntimeDllNames)) {
    if (-not (Test-Path -LiteralPath (Join-Path -Path $System32 -ChildPath $dll))) {
      return $false
    }
  }
  return $true
}

function Get-VcRuntimeDllNames {
  # The three DLLs llama-server.exe imports from the VC++ runtime.
  return @('vcruntime140.dll', 'msvcp140.dll', 'vcruntime140_1.dll')
}

function Test-VcRedistExitCode {
  <#
  .SYNOPSIS
    Maps a vc_redist.x64.exe exit code to success or failure.

  .DESCRIPTION
    0 = installed, 3010 = installed but a reboot is pending (the DLLs are
    already usable), 1638 = a newer or equal version is already installed.
    Everything else is a failure.

  .PARAMETER ExitCode
    Exit code of vc_redist.x64.exe /install /quiet /norestart.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (-not (Test-VcRedistExitCode -ExitCode $proc.ExitCode)) { throw 'vc_redist failed' }
  #>
  param([Parameter(Mandatory)][long]$ExitCode)

  return ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 1638)
}

# ---------------------------------------------------------------------------
# Python and git on PATH (Step-Tools, preflight HasPython / HasGit)
# ---------------------------------------------------------------------------

function Test-RealPythonPath {
  <#
  .SYNOPSIS
    True when a resolved python path is not the Microsoft Store alias.

  .DESCRIPTION
    On a fresh Windows the `python` command resolves into
    %LOCALAPPDATA%\Microsoft\WindowsApps, where the Store stub prints "Python
    was not found" instead of running an interpreter. The path is compared
    case-insensitively against the WindowsApps root (a path exactly at the
    root or one level below it is rejected); anything else counts as a real
    interpreter. Both paths are injectable so tests need no Windows.

  .PARAMETER Path
    The resolved command path (Get-Command python).Source).

  .PARAMETER WindowsAppsRoot
    The WindowsApps directory. Defaults to
    $env:LOCALAPPDATA\Microsoft\WindowsApps.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    Test-RealPythonPath -Path (Get-Command python).Source
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
    [AllowEmptyString()][string]$WindowsAppsRoot = ''
  )

  if ("$Path" -eq '') {
    return $false
  }
  if ("$WindowsAppsRoot" -eq '') {
    $WindowsAppsRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps'
  }
  $full = "$Path"
  $root = "$WindowsAppsRoot"
  try { $full = [System.IO.Path]::GetFullPath($full) } catch { }
  try { $root = [System.IO.Path]::GetFullPath($root) } catch { }
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if ($full.StartsWith($root, $comparison)) {
    if ($full.Length -eq $root.Length) {
      return $false
    }
    $next = $full.Substring($root.Length, 1)
    if ($next -eq '\' -or $next -eq '/') {
      return $false
    }
  }
  return $true
}

function Get-PythonVersionFromText {
  <#
  .SYNOPSIS
    Parses "Python 3.12.4" out of `python --version` output.

  .DESCRIPTION
    Accepts the whole output (both streams are captured together) and
    returns the first "python <digits and dots>" match as a
    System.Version, or $null when nothing parsable is there.

  .PARAMETER Text
    Output of python --version.

  .OUTPUTS
    System.Version or $null

  .EXAMPLE
    $v = Get-PythonVersionFromText -Text 'Python 3.12.4'
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $null
  }
  foreach ($line in ($Text -split "`r?`n")) {
    $match = [regex]::Match($line, '(?i)python\s+(\d+(\.\d+)+)')
    if ($match.Success) {
      $parsed = $null
      if ([version]::TryParse($match.Groups[1].Value, [ref]$parsed)) {
        return $parsed
      }
    }
  }
  return $null
}

function Test-PythonAvailable {
  <#
  .SYNOPSIS
    True when a real Python of at least the pinned minimum is on PATH.

  .DESCRIPTION
    Resolves the command (default `python`), rejects the Microsoft Store
    alias (Test-RealPythonPath), runs `--version` in a captured probe and
    compares the parsed version against the PythonMinVersion constant
    (3.10). Everything Step-Tools needs to decide "keep it".

  .PARAMETER CommandName
    Command to probe. Default 'python'.

  .PARAMETER TimeoutSeconds
    Probe budget. Default 60.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (Test-PythonAvailable) { 'python is fine' }
  #>
  param(
    [string]$CommandName = 'python',
    [int]$TimeoutSeconds = 60
  )

  $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
  if (-not $cmd -or -not $cmd.Source) {
    return $false
  }
  if (-not (Test-RealPythonPath -Path $cmd.Source)) {
    return $false
  }
  $probe = Invoke-NativeProbe -FilePath $cmd.Source -Arguments '--version' -TimeoutSeconds $TimeoutSeconds
  if ($probe.TimedOut -or $probe.ExitCode -ne 0) {
    return $false
  }
  $version = Get-PythonVersionFromText -Text $probe.Output
  if ($null -eq $version) {
    return $false
  }
  $minimum = [version](Get-LocalAgentConstants).PythonMinVersion
  return ($version -ge $minimum)
}

function Test-GitAvailable {
  <#
  .SYNOPSIS
    True when `git --version` runs successfully.

  .PARAMETER CommandName
    Command to probe. Default 'git'.

  .PARAMETER TimeoutSeconds
    Probe budget. Default 60.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (Test-GitAvailable) { 'git is fine' }
  #>
  param(
    [string]$CommandName = 'git',
    [int]$TimeoutSeconds = 60
  )

  $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
  if (-not $cmd -or -not $cmd.Source) {
    return $false
  }
  $probe = Invoke-NativeProbe -FilePath $cmd.Source -Arguments '--version' -TimeoutSeconds $TimeoutSeconds
  return (-not $probe.TimedOut -and $probe.ExitCode -eq 0)
}

function Update-SessionPath {
  <#
  .SYNOPSIS
    Rebuilds $env:PATH from the machine + user registry values.

  .DESCRIPTION
    An installer that just ran (winget, the Python or git setup) updates the
    registry but not this session. Called after such a step so later probes
    and later install steps see the new tools. Machine entries come first,
    then user entries, then any session-only entries from before the call
    (e.g. a directory added for this run only); duplicates are dropped
    case-insensitively.

  .EXAMPLE
    Update-SessionPath
  #>
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:PATH = Join-PathList -Lists @($machine, $user, $env:PATH)
}

function Join-PathList {
  <#
  .SYNOPSIS
    Joins semicolon-separated PATH strings, keeping the first occurrence.

  .DESCRIPTION
    Empty pieces are dropped, trailing backslashes are ignored for the
    duplicate check, comparison is case-insensitive, order is preserved.

  .PARAMETER Lists
    PATH strings, highest priority first.

  .OUTPUTS
    System.String

  .EXAMPLE
    Join-PathList -Lists @($machinePath, $userPath, $env:PATH)
  #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Lists)

  $seen = @{}
  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($list in $Lists) {
    foreach ($piece in ("$list" -split ';')) {
      $t = $piece.Trim()
      if ($t -eq '') {
        continue
      }
      $k = $t.TrimEnd('\').ToLowerInvariant()
      if (-not $seen.ContainsKey($k)) {
        $seen[$k] = $true
        $parts.Add($t)
      }
    }
  }
  return ($parts.ToArray() -join ';')
}

function Get-NativeExitCodeHint {
  <#
  .SYNOPSIS
    Explains a Windows loader exit code in plain words, or returns ''.

  .DESCRIPTION
    A process that cannot even start exits with an NTSTATUS value that
    PowerShell reports as a negative $LASTEXITCODE. The two that matter for
    llama-server.exe:
      0xC0000135 (-1073741515) STATUS_DLL_NOT_FOUND     -> VC++ runtime missing
      0xC000007B (-1073741701) STATUS_INVALID_IMAGE_FORMAT -> 32/64-bit mismatch
    Unsigned forms (3221225781, 3221225595) are accepted too.

  .PARAMETER ExitCode
    The $LASTEXITCODE value.

  .OUTPUTS
    System.String ('' when the code has no known meaning)

  .EXAMPLE
    $hint = Get-NativeExitCodeHint -ExitCode $LASTEXITCODE
  #>
  param([Parameter(Mandatory)][long]$ExitCode)

  $code = $ExitCode
  if ($code -lt 0) {
    $code = $code + 4294967296
  }
  if ($code -eq 3221225781) {
    return 'Visual C++ runtime missing (STATUS_DLL_NOT_FOUND, 0xC0000135): vcruntime140.dll / msvcp140.dll / vcruntime140_1.dll are not installed. Install the Microsoft Visual C++ 2015-2022 Redistributable (x64) and re-run.'
  }
  if ($code -eq 3221225595) {
    return 'a DLL has the wrong architecture (STATUS_INVALID_IMAGE_FORMAT, 0xC000007B): a 32-bit DLL shadows the 64-bit one, or the zip is not the x64 build.'
  }
  return ''
}

function Test-Preflight {
  <#
  .SYNOPSIS
    Checks the machine against the package minimums (spec step 1).

  .DESCRIPTION
    Records curl/winget/code presence, whether the Visual C++ runtime is
    installed (HasVcRuntime) and whether a real Python 3.10+ and git are
    on PATH (HasPython, HasGit; install.ps1 installs whatever is false) but
    does not require any of them. Fails on:
    not 64-bit, OS major below 10, total RAM below MinRamGB, or free disk
    on the install drive below MinDiskGB. Get-SystemFacts does the CIM
    queries; tests Mock it, or inject a matching object with -Facts.

  .PARAMETER MinRamGB
    Minimum total RAM in GB. Default 30.

  .PARAMETER MinDiskGB
    Minimum free disk in GB on the install drive. Default 30.

  .PARAMETER InstallDir
    Package root; its drive is checked. Defaults to the standard install dir.

  .PARAMETER Facts
    Optional pre-collected facts object (dependency injection for tests).

  .OUTPUTS
    System.Management.Automation.PSCustomObject with Is64Bit, OsVersion,
    TotalRamGB, FreeDiskGB, PhysicalCores, HasCurl, HasWinget, HasCode,
    HasVcRuntime, HasPython, HasGit, Ok, Problems.

  .EXAMPLE
    $pf = Test-Preflight; if (-not $pf.Ok) { $pf.Problems }
  #>
  param(
    [int]$MinRamGB = 30,
    [int]$MinDiskGB = 30,
    [string]$InstallDir,
    [psobject]$Facts
  )

  if ($Facts) {
    $facts = $Facts
  }
  else {
    if (-not $InstallDir) {
      $InstallDir = (Get-LocalAgentPaths).InstallDir
    }
    $facts = Get-SystemFacts -InstallDir $InstallDir
  }

  $problems = @()
  if (-not $facts.Is64Bit) {
    $problems += 'Not a 64-bit operating system.'
  }
  $osMajor = 0
  $parsed = $false
  try {
    $v = [version]$facts.OsVersion
    $osMajor = $v.Major
    $parsed = $true
  }
  catch {
    $parsed = $false
  }
  if (-not $parsed) {
    $problems += "Could not parse OS version '$($facts.OsVersion)'."
  }
  elseif ($osMajor -lt 10) {
    $problems += "Windows 10 or 11 required, found version '$($facts.OsVersion)'."
  }
  if ($facts.TotalRamGB -lt $MinRamGB) {
    $problems += ("Total RAM {0} GB is below the required {1} GB." -f $facts.TotalRamGB, $MinRamGB)
  }
  if ($facts.FreeDiskGB -lt $MinDiskGB) {
    $problems += ("Free disk {0} GB on the install drive is below the required {1} GB." -f $facts.FreeDiskGB, $MinDiskGB)
  }

  # Older facts objects (tests) may lack these; missing means false.
  $hasVcRuntime = $false
  $vcProp = $facts.PSObject.Properties['HasVcRuntime']
  if ($null -ne $vcProp) {
    $hasVcRuntime = [bool]$vcProp.Value
  }
  $hasPython = $false
  $pyProp = $facts.PSObject.Properties['HasPython']
  if ($null -ne $pyProp) {
    $hasPython = [bool]$pyProp.Value
  }
  $hasGit = $false
  $gitProp = $facts.PSObject.Properties['HasGit']
  if ($null -ne $gitProp) {
    $hasGit = [bool]$gitProp.Value
  }

  return [pscustomobject]@{
    Is64Bit       = [bool]$facts.Is64Bit
    OsVersion     = [string]$facts.OsVersion
    TotalRamGB    = $facts.TotalRamGB
    FreeDiskGB    = $facts.FreeDiskGB
    PhysicalCores = $facts.PhysicalCores
    HasCurl       = [bool]$facts.HasCurl
    HasWinget     = [bool]$facts.HasWinget
    HasCode       = [bool]$facts.HasCode
    HasVcRuntime  = $hasVcRuntime
    HasPython     = $hasPython
    HasGit        = $hasGit
    Ok            = ($problems.Count -eq 0)
    Problems      = [string[]]$problems
  }
}

# ---------------------------------------------------------------------------
# llama.cpp system_info parsing
# ---------------------------------------------------------------------------

function Get-SystemInfoFlags {
  <#
  .SYNOPSIS
    Parses llama.cpp's system_info line into FLAG = value pairs.

  .DESCRIPTION
    The line looks like:
      system_info: n_threads = 4 | AVX = 1 | AVX2 = 1 | AVX512 = 0 | ...
    Everything before the first pair is ignored by the regex; each
    "NAME = value" segment up to the next '|' becomes a hashtable entry.

  .PARAMETER Text
    The system_info line (or the whole version output; extra text is ignored).

  .OUTPUTS
    System.Collections.Hashtable

  .EXAMPLE
    $flags = Get-SystemInfoFlags -Text $line; $flags['AVX2']
  #>
  param([Parameter(Mandatory)][string]$Text)

  $flags = @{}
  $pairs = [regex]::Matches($Text, '([A-Za-z][A-Za-z0-9_]*)\s*=\s*([^|]*)')
  foreach ($pair in $pairs) {
    $key = $pair.Groups[1].Value.Trim()
    $value = $pair.Groups[2].Value.Trim()
    if ($key -ne '') {
      $flags[$key] = $value
    }
  }
  return $flags
}

function Test-Avx2 {
  <#
  .SYNOPSIS
    Reports whether a parsed system_info flags table has AVX2 = 1.

  .PARAMETER Flags
    Hashtable from Get-SystemInfoFlags.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (-not (Test-Avx2 -Flags $flags)) { throw 'AVX2 required' }
  #>
  param([Parameter(Mandatory)][hashtable]$Flags)

  # .NET Framework Hashtable has no TryGetValue; ContainsKey + indexer instead.
  if (-not $Flags.ContainsKey('AVX2')) {
    return $false
  }
  return ("$($Flags['AVX2'])".Trim() -eq '1')
}

# ---------------------------------------------------------------------------
# JSON array entry merge (chatLanguageModels.json)
# ---------------------------------------------------------------------------

function Merge-JsonArrayEntry {
  <#
  .SYNOPSIS
    Inserts or replaces an entry in a JSON array file, keyed by a field.

  .DESCRIPTION
    Used for %APPDATA%\Code\User\chatLanguageModels.json. Creates the file
    (with []) if missing, replaces the element whose KeyName equals the
    new entry's, or appends. Existing entries are kept. Written as UTF-8
    without a BOM with ConvertTo-Json -Depth 8.

  .PARAMETER Path
    JSON array file.

  .PARAMETER Entry
    The entry object (PSCustomObject).

  .PARAMETER KeyName
    Field that identifies an entry. Default 'name'.

  .OUTPUTS
    System.String: 'created', 'replaced' or 'appended'.

  .EXAMPLE
    Merge-JsonArrayEntry -Path $p.ChatModelsJson -Entry (Get-VsCodeModelEntry)
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][psobject]$Entry,
    [string]$KeyName = 'name'
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  $list = @()
  $action = 'created'

  if (Test-Path -LiteralPath $fsPath) {
    $raw = Get-Content -LiteralPath $fsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try {
        $parsed = ConvertFrom-Json -InputObject $raw
      }
      catch {
        throw "Not valid JSON, refusing to merge into: $Path ($_)"
      }
      if ($null -ne $parsed) {
        $list = @($parsed)
      }
    }
    $action = 'appended'
  }

  $entryValue = $null
  $entryProps = $Entry.PSObject.Properties
  if ($entryProps -and $entryProps[$KeyName]) {
    $entryValue = $entryProps[$KeyName].Value
  }

  $index = -1
  for ($i = 0; $i -lt $list.Count; $i++) {
    $candidate = $list[$i]
    if ($null -eq $candidate) { continue }
    $candProps = $candidate.PSObject.Properties
    if ($candProps -and $candProps[$KeyName]) {
      if ("$($candProps[$KeyName].Value)" -eq "$entryValue") {
        $index = $i
        break
      }
    }
  }

  if ($index -ge 0) {
    $list[$index] = $Entry
    $action = 'replaced'
  }
  else {
    $list = @($list) + @($Entry)
  }

  $json = ConvertTo-Json -InputObject @($list) -Depth 8
  $parent = Split-Path -Path $fsPath -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($fsPath, $json + [Environment]::NewLine)
  return $action
}

function Remove-JsonArrayEntry {
  <#
  .SYNOPSIS
    Removes an entry from a JSON array file, keyed by a field (uninstall).

  .DESCRIPTION
    Counterpart of Merge-JsonArrayEntry. Other entries are kept. Missing
    file or no matching entry leaves everything untouched.

  .PARAMETER Path
    JSON array file.

  .PARAMETER Name
    Value of the identifying field to remove.

  .PARAMETER KeyName
    Field that identifies an entry. Default 'name'.

  .OUTPUTS
    System.String: 'removed' or 'absent'.

  .EXAMPLE
    Remove-JsonArrayEntry -Path $p.ChatModelsJson -Name 'Local Qwen3.6'
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name,
    [string]$KeyName = 'name'
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return 'absent'
  }
  $raw = Get-Content -LiteralPath $fsPath -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return 'absent'
  }
  try {
    $parsed = ConvertFrom-Json -InputObject $raw
  }
  catch {
    throw "Not valid JSON, refusing to edit: $Path ($_)"
  }
  if ($null -eq $parsed) {
    return 'absent'
  }

  $kept = @()
  $removed = 0
  foreach ($item in @($parsed)) {
    $match = $false
    if ($null -ne $item) {
      $props = $item.PSObject.Properties
      if ($props -and $props[$KeyName]) {
        if ("$($props[$KeyName].Value)" -eq $Name) {
          $match = $true
        }
      }
    }
    if ($match) {
      $removed++
    }
    else {
      $kept = @($kept) + @($item)
    }
  }

  if ($removed -eq 0) {
    return 'absent'
  }
  $json = ConvertTo-Json -InputObject @($kept) -Depth 8
  [System.IO.File]::WriteAllText($fsPath, $json + [Environment]::NewLine)
  return 'removed'
}

# ---------------------------------------------------------------------------
# Managed text blocks (models.yml), mirroring ensure_omp_provider in
# the start-llm launcher
# ---------------------------------------------------------------------------

function Set-ManagedBlock {
  <#
  .SYNOPSIS
    Creates, replaces or appends a marked block in a text file.

  .DESCRIPTION
    Mirrors ensure_omp_provider from start-llm:
      - file missing            -> created (block is the whole file)
      - Begin marker present    -> replaced in place, one blank line eaten
                                   on each side of the block
      - no Begin marker         -> appended after a blank line
    -ConflictPattern adds the start-llm refusal behaviour for foreign
    content: when the file has no managed block and matches the regex
    (e.g. '^\s*providers:\s*$' for a hand-written provider map), the file
    is left untouched and 'skipped' is returned.

  .PARAMETER Path
    Target text file. Parent folders are created when missing.

  .PARAMETER Begin
    Begin marker line, e.g. '# >>> localagent'.

  .PARAMETER End
    End marker line, e.g. '# <<< localagent'.

  .PARAMETER Content
    Block body as an array of lines (or one multi-line string).

  .PARAMETER ConflictPattern
    Optional regex; refuses to append when the file matches and has no
    managed block.

  .OUTPUTS
    System.String: 'created', 'replaced', 'appended' or 'skipped'.

  .EXAMPLE
    Set-ManagedBlock -Path $p.OmpModelsYml -Begin '# >>> localagent' -End '# <<< localagent' -Content (Get-OmpModelsBlock)
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Begin,
    [Parameter(Mandatory)][string]$End,
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Content,
    [string]$ConflictPattern
  )

  # Normalize the content to a clean array of lines (no trailing blanks).
  $blockLines = [System.Collections.Generic.List[string]]::new()
  $joined = ($Content -join "`n")
  if (-not [string]::IsNullOrWhiteSpace($joined)) {
    foreach ($line in ($joined -split "`r?`n")) {
      $blockLines.Add([string]$line)
    }
    while ($blockLines.Count -gt 0 -and $blockLines[$blockLines.Count - 1] -eq '') {
      $blockLines.RemoveAt($blockLines.Count - 1)
    }
  }
  $fullBlock = [System.Collections.Generic.List[string]]::new()
  $fullBlock.Add($Begin)
  foreach ($line in $blockLines) { $fullBlock.Add($line) }
  $fullBlock.Add($End)

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    Write-TextFileUtf8 -Path $fsPath -Lines $fullBlock.ToArray()
    return 'created'
  }

  $existing = @(Get-Content -LiteralPath $fsPath)
  $beginIdx = -1
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -eq $Begin) { $beginIdx = $i; break }
  }

  if ($beginIdx -ge 0) {
    $endIdx = -1
    for ($j = $beginIdx + 1; $j -lt $existing.Count; $j++) {
      if ($existing[$j] -eq $End) { $endIdx = $j; break }
    }
    if ($endIdx -lt 0) {
      throw "Managed block start '$Begin' found without end marker '$End' in: $Path"
    }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $beginIdx; $i++) { $result.Add([string]$existing[$i]) }
    while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
      $result.RemoveAt($result.Count - 1)
    }
    foreach ($line in $fullBlock) { $result.Add($line) }
    for ($j = $endIdx + 1; $j -lt $existing.Count; $j++) { $result.Add([string]$existing[$j]) }
    while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
      $result.RemoveAt($result.Count - 1)
    }
    Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
    return 'replaced'
  }

  if ($ConflictPattern) {
    foreach ($line in $existing) {
      if ($line -match $ConflictPattern) {
        return 'skipped'
      }
    }
  }

  $result = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $existing) { $result.Add([string]$line) }
  while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
    $result.RemoveAt($result.Count - 1)
  }
  if ($result.Count -gt 0) { $result.Add('') }
  foreach ($line in $fullBlock) { $result.Add($line) }
  Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
  return 'appended'
}

function Remove-ManagedBlock {
  <#
  .SYNOPSIS
    Removes a marked block from a text file (uninstall).

  .DESCRIPTION
    Deletes the Begin..End span and the blank lines directly around it.
    Everything else in the file is kept byte for byte.

  .PARAMETER Path
    Target text file.

  .PARAMETER Begin
    Begin marker line.

  .PARAMETER End
    End marker line.

  .OUTPUTS
    System.String: 'removed' or 'absent'.

  .EXAMPLE
    Remove-ManagedBlock -Path $p.OmpModelsYml -Begin '# >>> localagent' -End '# <<< localagent'
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Begin,
    [Parameter(Mandatory)][string]$End
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return 'absent'
  }
  $existing = @(Get-Content -LiteralPath $fsPath)
  $beginIdx = -1
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -eq $Begin) { $beginIdx = $i; break }
  }
  if ($beginIdx -lt 0) {
    return 'absent'
  }
  $endIdx = -1
  for ($j = $beginIdx + 1; $j -lt $existing.Count; $j++) {
    if ($existing[$j] -eq $End) { $endIdx = $j; break }
  }
  if ($endIdx -lt 0) {
    throw "Managed block start '$Begin' found without end marker '$End' in: $Path"
  }

  $result = [System.Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $beginIdx; $i++) { $result.Add([string]$existing[$i]) }
  while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
    $result.RemoveAt($result.Count - 1)
  }
  $j = $endIdx + 1
  while ($j -lt $existing.Count -and [string]$existing[$j] -eq '') { $j++ }
  for (; $j -lt $existing.Count; $j++) { $result.Add([string]$existing[$j]) }
  while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
    $result.RemoveAt($result.Count - 1)
  }
  Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
  return 'removed'
}

# ---------------------------------------------------------------------------
# YAML top-level map editing (config.yml modelRoles)
# ---------------------------------------------------------------------------

function Set-YamlTopLevelMap {
  <#
  .SYNOPSIS
    Replaces or appends a top-level map block in a YAML file.

  .DESCRIPTION
    No YAML module is used: the file is edited line by line. The block is
    a top-level "key:" line followed by 2-space indented "name: value"
    lines. When the key exists, its block (up to the next top-level line)
    is replaced; otherwise the block is appended after a blank line.
    Everything else is kept. Limitation: values are written as plain
    scalars, values needing quotes are not quoted, and comments inside a
    replaced block are lost.

  .PARAMETER Path
    YAML file. Created when missing.

  .PARAMETER Key
    Top-level key, e.g. 'modelRoles'.

  .PARAMETER Values
    Hashtable (or ordered dictionary) of the block entries.

  .OUTPUTS
    System.String: 'created', 'replaced' or 'appended'.

  .EXAMPLE
    Set-YamlTopLevelMap -Path $p.OmpConfigYml -Key 'modelRoles' -Values [ordered]@{ default = 'local/qwen3.6-35b-a3b' }
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Values
  )

  $block = [System.Collections.Generic.List[string]]::new()
  $block.Add("${Key}:")
  foreach ($entry in $Values.GetEnumerator()) {
    $value = ''
    if ($null -ne $entry.Value) { $value = "$($entry.Value)" }
    $block.Add(('  ' + "$($entry.Key)" + ': ' + $value))
  }

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    Write-TextFileUtf8 -Path $fsPath -Lines $block.ToArray()
    return 'created'
  }

  $existing = @(Get-Content -LiteralPath $fsPath)
  $keyPattern = '^' + [regex]::Escape($Key) + ':\s*(#.*)?$'
  $keyIdx = -1
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -match $keyPattern) { $keyIdx = $i; break }
  }

  if ($keyIdx -ge 0) {
    $spanEnd = $existing.Count
    for ($j = $keyIdx + 1; $j -lt $existing.Count; $j++) {
      if ($existing[$j] -match '^\S') { $spanEnd = $j; break }
    }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $keyIdx; $i++) { $result.Add([string]$existing[$i]) }
    foreach ($line in $block) { $result.Add($line) }
    for ($j = $spanEnd; $j -lt $existing.Count; $j++) { $result.Add([string]$existing[$j]) }
    Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
    return 'replaced'
  }

  $result = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $existing) { $result.Add([string]$line) }
  while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
    $result.RemoveAt($result.Count - 1)
  }
  if ($result.Count -gt 0) { $result.Add('') }
  foreach ($line in $block) { $result.Add($line) }
  Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
  return 'appended'
}

function Remove-YamlTopLevelMapKeys {
  <#
  .SYNOPSIS
    Removes named entries from a top-level map block in a YAML file.

  .DESCRIPTION
    Uninstall counterpart of Set-YamlTopLevelMap. Only the listed keys are
    removed; other entries in the same block, and the rest of the file, are
    kept. When the block ends up empty, the "key:" line (and the blank line
    around it) is removed too.

  .PARAMETER Path
    YAML file.

  .PARAMETER Key
    Top-level key whose block is edited, e.g. 'modelRoles'.

  .PARAMETER Keys
    Entry names to remove.

  .OUTPUTS
    System.String: 'removed' or 'absent'.

  .EXAMPLE
    Remove-YamlTopLevelMapKeys -Path $p.OmpConfigYml -Key 'modelRoles' -Keys @('default','smol','slow','plan')
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string[]]$Keys
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return 'absent'
  }
  $existing = @(Get-Content -LiteralPath $fsPath)
  $keyPattern = '^' + [regex]::Escape($Key) + ':\s*(#.*)?$'
  $keyIdx = -1
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -match $keyPattern) { $keyIdx = $i; break }
  }
  if ($keyIdx -lt 0) {
    return 'absent'
  }
  $spanEnd = $existing.Count
  for ($j = $keyIdx + 1; $j -lt $existing.Count; $j++) {
    if ($existing[$j] -match '^\S') { $spanEnd = $j; break }
  }

  $kept = [System.Collections.Generic.List[string]]::new()
  $removed = 0
  for ($i = $keyIdx + 1; $i -lt $spanEnd; $i++) {
    $line = [string]$existing[$i]
    # "  name: value", "  name:" or "  name: # comment"; the value is free text.
    $entryMatch = [regex]::Match($line, '^\s+([^\s:#][^:#]*?)\s*:(?:\s.*)?$')
    if ($entryMatch.Success -and ($Keys -icontains $entryMatch.Groups[1].Value.Trim())) {
      $removed++
    }
    else {
      $kept.Add($line)
    }
  }

  if ($removed -eq 0) {
    return 'absent'
  }

  $result = [System.Collections.Generic.List[string]]::new()
  if ($kept.Count -gt 0) {
    for ($i = 0; $i -le $keyIdx; $i++) { $result.Add([string]$existing[$i]) }
    foreach ($line in $kept) { $result.Add($line) }
    for ($j = $spanEnd; $j -lt $existing.Count; $j++) { $result.Add([string]$existing[$j]) }
  }
  else {
    for ($i = 0; $i -lt $keyIdx; $i++) { $result.Add([string]$existing[$i]) }
    while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
      $result.RemoveAt($result.Count - 1)
    }
    for ($j = $spanEnd; $j -lt $existing.Count; $j++) { $result.Add([string]$existing[$j]) }
    while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
      $result.RemoveAt($result.Count - 1)
    }
  }
  Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
  return 'removed'
}

function Set-YamlScalar {
  <#
  .SYNOPSIS
    Replaces or appends one top-level "key: value" line in a YAML file.

  .DESCRIPTION
    No YAML module is used: the file is edited line by line. Only a
    top-level "key:" line (no leading whitespace) is considered; when the
    key exists its line is replaced, otherwise the line is appended after a
    blank line. Every other line, including nested keys of other blocks, is
    kept byte for byte. A missing file is created holding just that line.

  .PARAMETER Path
    YAML file. Created when missing.

  .PARAMETER Key
    Top-level key, e.g. 'setupVersion'.

  .PARAMETER Value
    Scalar value written as "key: value" (plain, unquoted).

  .OUTPUTS
    System.String: 'created', 'replaced', 'appended' or 'present' (the line
    was already exactly "key: value").

  .EXAMPLE
    Set-YamlScalar -Path $p.OmpConfigYml -Key 'setupVersion' -Value 2
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Value
  )

  $line = '{0}: {1}' -f $Key, $Value
  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    Write-TextFileUtf8 -Path $fsPath -Lines @($line)
    return 'created'
  }

  $existing = @(Get-Content -LiteralPath $fsPath)
  $keyPattern = '^' + [regex]::Escape($Key) + ':(\s.*)?$'
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -match $keyPattern) {
      if ([string]$existing[$i] -eq $line) {
        return 'present'
      }
      $existing[$i] = $line
      Write-TextFileUtf8 -Path $fsPath -Lines ([string[]]$existing)
      return 'replaced'
    }
  }

  $result = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $existing) { $result.Add([string]$entry) }
  while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
    $result.RemoveAt($result.Count - 1)
  }
  if ($result.Count -gt 0) { $result.Add('') }
  $result.Add($line)
  Write-TextFileUtf8 -Path $fsPath -Lines $result.ToArray()
  return 'appended'
}

function Remove-YamlScalar {
  <#
  .SYNOPSIS
    Removes one top-level "key: value" line from a YAML file (uninstall).

  .DESCRIPTION
    Counterpart of Set-YamlScalar. The line is removed only when its value
    is exactly the given one (case-insensitive, whitespace-trimmed), so a
    value the user or omp itself set later is never touched. Everything
    else in the file is kept.

  .PARAMETER Path
    YAML file.

  .PARAMETER Key
    Top-level key, e.g. 'setupVersion'.

  .PARAMETER Value
    Only remove the line when this is its value, e.g. '2'.

  .OUTPUTS
    System.String: 'removed' or 'absent' (no file, no such key, or a
    different value).

  .EXAMPLE
    Remove-YamlScalar -Path $p.OmpConfigYml -Key 'setupVersion' -Value '2'
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Value
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return 'absent'
  }
  $existing = @(Get-Content -LiteralPath $fsPath)
  $keyPattern = '^' + [regex]::Escape($Key) + ':(\s.*)?$'
  for ($i = 0; $i -lt $existing.Count; $i++) {
    if ($existing[$i] -match $keyPattern) {
      # "key: value" -> everything after the first colon, trimmed.
      $current = ''
      $colon = ([string]$existing[$i]).IndexOf(':')
      if ($colon -ge 0) {
        $current = ([string]$existing[$i]).Substring($colon + 1).Trim()
      }
      if ($current -ieq $Value) {
        $kept = [System.Collections.Generic.List[string]]::new()
        for ($j = 0; $j -lt $existing.Count; $j++) {
          if ($j -ne $i) { $kept.Add([string]$existing[$j]) }
        }
        Write-TextFileUtf8 -Path $fsPath -Lines $kept.ToArray()
        return 'removed'
      }
      return 'absent'
    }
  }
  return 'absent'
}

function Get-OmpModelRoles {
  <#
  .SYNOPSIS
    Returns the omp modelRoles map for one provider-qualified model id.

  .DESCRIPTION
    omp 18.2.8 discovers the local llama-server itself as provider
    "llama.cpp", so the roles point at "llama.cpp/<model id>" instead of a
    models.yml provider. Callers pass the full id, e.g.
    "llama.cpp/qwen3.6-35b-a3b"; write it with Set-YamlTopLevelMap.

  .PARAMETER ModelId
    Provider-qualified model id, e.g. 'llama.cpp/qwen3.6-35b-a3b'.

  .OUTPUTS
    System.Collections.Specialized.OrderedDictionary

  .EXAMPLE
    Set-YamlTopLevelMap -Path $p.OmpConfigYml -Key 'modelRoles' -Values (Get-OmpModelRoles -ModelId 'llama.cpp/qwen3.6-35b-a3b')
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$ModelId)

  if ("$ModelId" -eq '') {
    $ModelId = 'llama.cpp/{0}' -f (Get-LocalAgentConstants).Alias
  }
  return [ordered]@{
    default = $ModelId
    smol    = $ModelId
    slow    = $ModelId
    plan    = $ModelId
  }
}

# ---------------------------------------------------------------------------
# Spec-defined payloads: VS Code model entry
# ---------------------------------------------------------------------------

function Get-VsCodeModelEntry {
  <#
  .SYNOPSIS
    Returns the chatLanguageModels.json provider entry (spec step 8).

  .DESCRIPTION
    The exact object from the spec; name and model id come from
    Get-LocalAgentConstants. Merge into
    %APPDATA%\Code\User\chatLanguageModels.json with Merge-JsonArrayEntry.

  .OUTPUTS
    System.Management.Automation.PSCustomObject

  .EXAMPLE
    Merge-JsonArrayEntry -Path $p.ChatModelsJson -Entry (Get-VsCodeModelEntry)
  #>
  param([string]$Alias = '')

  $constants = Get-LocalAgentConstants
  $alias = [string]$constants.Alias
  if ("$Alias" -ne '') {
    $alias = $Alias
  }
  $url = 'http://127.0.0.1:' + (ConvertTo-InvariantString -Value $constants.Port) + '/v1/chat/completions'

  return [pscustomobject]@{
    name     = [string]$constants.VsCodeEntryName
    vendor   = 'customendpoint'
    apiType  = 'chat-completions'
    models   = @(
      [pscustomobject]@{
        id              = $alias
        name            = 'Local Qwen3.6 35B-A3B'
        url             = $url
        toolCalling     = $true
        vision          = $false
        maxInputTokens  = 120000
        maxOutputTokens = 16384
      }
    )
  }
}

# ---------------------------------------------------------------------------
# Subagent MCP server (install.ps1 -WithSubagent): JSON object merge,
# config.toml template fill, omp binary discovery, uv tool list parsing
# ---------------------------------------------------------------------------

function Set-JsonObjectKey {
  <#
  .SYNOPSIS
    Sets one key of a named object inside a JSON object file.

  .DESCRIPTION
    Used for %APPDATA%\Code\User\mcp.json, which is one JSON object holding
    a "servers" object of MCP server definitions: the key Name inside the
    object ObjectKey is created or replaced, every other server (and every
    other property of the file) is kept. A missing file (or an empty one) is
    created holding just that object. Written as UTF-8 without a BOM with
    ConvertTo-Json -Depth 8. Property order of the existing file is kept.

  .PARAMETER Path
    JSON object file.

  .PARAMETER ObjectKey
    Name of the inner object, e.g. 'servers'. Created when missing.

  .PARAMETER Name
    Key to set inside the inner object, e.g. 'local-subagent'.

  .PARAMETER Value
    The object to store.

  .OUTPUTS
    System.String: 'created' (no file or empty file), 'added' or 'replaced'.

  .EXAMPLE
    Set-JsonObjectKey -Path $p.McpJson -ObjectKey 'servers' -Name 'local-subagent' -Value ([pscustomobject]@{ type = 'stdio'; command = $exe; args = @() })
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ObjectKey,
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()][object]$Value
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  $root = $null
  $hadRoot = $false
  if (Test-Path -LiteralPath $fsPath) {
    $raw = Get-Content -LiteralPath $fsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try {
        $root = ConvertFrom-Json -InputObject $raw
      }
      catch {
        throw "Not valid JSON, refusing to merge into: $Path ($_)"
      }
      $hadRoot = $true
    }
  }

  $action = 'created'
  if ($hadRoot) {
    $action = 'added'
    # ConvertFrom-Json unwraps a one-element array on 5.1, so the array check
    # has to look at the text.
    if ($raw.TrimStart().StartsWith('[') -or $root -isnot [pscustomobject]) {
      throw "JSON root is not an object, refusing to merge into: $Path"
    }
  }
  else {
    # PS 5.1 has no PSCustomObject constructor; the cast is the only way.
    $root = [pscustomobject]@{}
  }

  $parent = Get-JsonProperty -Object $root -Name $ObjectKey
  if ($null -eq $parent) {
    $parent = [pscustomobject]@{}
    Add-Member -InputObject $root -MemberType NoteProperty -Name $ObjectKey -Value $parent -Force
  }
  elseif ($parent -isnot [pscustomobject]) {
    throw ("'{0}' is not a JSON object, refusing to merge into: {1}" -f $ObjectKey, $Path)
  }
  elseif ($null -ne (Get-JsonProperty -Object $parent -Name $Name)) {
    $action = 'replaced'
  }

  Add-Member -InputObject $parent -MemberType NoteProperty -Name $Name -Value $Value -Force

  $json = ConvertTo-Json -InputObject $root -Depth 8
  $fsParent = Split-Path -Path $fsPath -Parent
  if ($fsParent -and -not (Test-Path -LiteralPath $fsParent)) {
    New-Item -Path $fsParent -ItemType Directory -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($fsPath, $json + [Environment]::NewLine)
  return $action
}

function Remove-JsonObjectKey {
  <#
  .SYNOPSIS
    Removes one key of a named object inside a JSON object file (uninstall).

  .DESCRIPTION
    Counterpart of Set-JsonObjectKey: deletes the key Name inside the object
    ObjectKey and keeps everything else, including an empty ObjectKey left
    behind. Missing file, missing object or missing key leaves the file
    untouched.

  .PARAMETER Path
    JSON object file.

  .PARAMETER ObjectKey
    Name of the inner object, e.g. 'servers'.

  .PARAMETER Name
    Key to remove, e.g. 'local-subagent'.

  .OUTPUTS
    System.String: 'removed' or 'absent'.

  .EXAMPLE
    Remove-JsonObjectKey -Path $p.McpJson -ObjectKey 'servers' -Name 'local-subagent'
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ObjectKey,
    [Parameter(Mandatory)][string]$Name
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return 'absent'
  }
  $raw = Get-Content -LiteralPath $fsPath -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return 'absent'
  }
  try {
    $root = ConvertFrom-Json -InputObject $raw
  }
  catch {
    throw "Not valid JSON, refusing to edit: $Path ($_)"
  }
  if ($raw.TrimStart().StartsWith('[') -or $null -eq $root -or $root -isnot [pscustomobject]) {
    return 'absent'
  }
  $parent = Get-JsonProperty -Object $root -Name $ObjectKey
  if ($null -eq $parent -or $parent -isnot [pscustomobject]) {
    return 'absent'
  }
  $prop = $parent.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    return 'absent'
  }
  $parent.PSObject.Properties.Remove($Name)
  $json = ConvertTo-Json -InputObject $root -Depth 8
  [System.IO.File]::WriteAllText($fsPath, $json + [Environment]::NewLine)
  return 'removed'
}

function ConvertTo-SubagentToml {
  <#
  .SYNOPSIS
    Fills the placeholders of templates/subagent.toml.

  .DESCRIPTION
    Replaces {{OMP_BINARY}} (the full path to omp.exe) and {{PORT}} (the
    llama-server port the health candidates point at), then fails if any
    {{...}} placeholder is left, so a renamed placeholder cannot slip
    through silently. Pure: nothing is written; install.ps1 and
    uninstall.ps1 write (or compare) the result themselves.

  .PARAMETER Path
    Path to templates/subagent.toml.

  .PARAMETER OmpBinary
    Full path of the omp executable the provider runs.

  .PARAMETER Port
    llama-server port for the health candidates. 0 or omitted uses
    Get-LocalAgentConstants Port (8080).

  .OUTPUTS
    System.String (the filled config.toml text)

  .EXAMPLE
    $toml = ConvertTo-SubagentToml -Path 'templates\subagent.toml' -OmpBinary $omp -Port 8080
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$OmpBinary,
    [int]$Port = 0
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    throw "Subagent config template not found: $Path"
  }
  $toml = Get-Content -LiteralPath $fsPath -Raw
  if ($Port -le 0) {
    $Port = (Get-LocalAgentConstants).Port
  }
  $toml = $toml.Replace('{{OMP_BINARY}}', $OmpBinary)
  $toml = $toml.Replace('{{PORT}}', (ConvertTo-InvariantString -Value $Port))
  if ($toml.Contains('{{')) {
    throw "Subagent template still contains placeholders after filling: $Path"
  }
  return $toml
}

function Set-SubagentToml {
  <#
  .SYNOPSIS
    Writes the subagent config.toml from the template, unless it is the
    user's own.

  .DESCRIPTION
    Fills templates/subagent.toml (ConvertTo-SubagentToml) and writes it to
    Path, creating parent folders. A file that already declares a
    [providers.local] table is left untouched (returns 'kept'), so a config
    the user (or an earlier install with different settings) owns is never
    overwritten. UTF-8 without a BOM.

  .PARAMETER Path
    Destination config.toml (default %USERPROFILE%\.config\subagent\config.toml).

  .PARAMETER TemplatePath
    Path to templates/subagent.toml.

  .PARAMETER OmpBinary
    Full path of the omp executable the provider runs.

  .PARAMETER Port
    llama-server port for the health candidates. 0 or omitted uses
    Get-LocalAgentConstants Port (8080).

  .OUTPUTS
    System.String: 'created', 'replaced' or 'kept'.

  .EXAMPLE
    Set-SubagentToml -Path $p.SubagentConfig -TemplatePath 'templates\subagent.toml' -OmpBinary $omp -Port 8080
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$TemplatePath,
    [Parameter(Mandatory)][string]$OmpBinary,
    [int]$Port = 0
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  $action = 'created'
  if (Test-Path -LiteralPath $fsPath) {
    $action = 'replaced'
    $existing = Get-Content -LiteralPath $fsPath -Raw
    if (Test-TomlTablePresent -Text $existing -Name 'providers.local') {
      return 'kept'
    }
  }
  $toml = ConvertTo-SubagentToml -Path $TemplatePath -OmpBinary $OmpBinary -Port $Port
  Write-TextFileUtf8 -Path $fsPath -Lines ($toml -split "`r?`n")
  return $action
}

function Test-TomlTablePresent {
  <#
  .SYNOPSIS
    True when a TOML text declares the named table.

  .DESCRIPTION
    Line-based, no TOML parser: matches a "[name]" header line (comments
    after it are fine). "[providers.local]" does not match
    "[providers.local.health]". Used to leave an existing subagent config
    with its own [providers.local] alone.

  .PARAMETER Text
    TOML text.

  .PARAMETER Name
    Full table name, e.g. 'providers.local'.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (Test-TomlTablePresent -Text $toml -Name 'providers.local') { 'keep the user config' }
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory)][string]$Name
  )

  $pattern = '(?m)^\s*\[' + [regex]::Escape($Name) + '\]\s*(#.*)?$'
  return [bool]($Text -match $pattern)
}

function Get-SubagentBinaryFromToml {
  <#
  .SYNOPSIS
    Reads the provider binary path back out of a subagent config.toml.

  .DESCRIPTION
    The value of binary = "..." or binary = '...' inside [providers.local], or $null. Used
    by uninstall.ps1 to re-fill the template with the same binary path the
    installer wrote, so an untouched config file compares byte for byte and
    can be deleted safely.

  .PARAMETER Text
    TOML text.

  .OUTPUTS
    System.String or $null

  .EXAMPLE
    $bin = Get-SubagentBinaryFromToml -Text (Get-Content $p.SubagentConfig -Raw)
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

  $current = ''
  foreach ($line in ($Text -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -match '^\[(.+)\]\s*(#.*)?$') {
      $current = $Matches[1].Trim()
      continue
    }
    if ($current -eq 'providers.local' -and $t -match '^binary\s*=\s*(["''])(.*)\1\s*(#.*)?$') {
      return $Matches[2]
    }
  }
  return $null
}

function Get-OmpBinaryCandidates {
  <#
  .SYNOPSIS
    The paths the omp Windows installer (and bun) put omp.exe at.

  .DESCRIPTION
    Most likely first. install.ps1 resolves omp through Get-Command first
    (Find-OmpBinary) and uses these as the fallback, so the subagent config
    always carries a full path.

  .OUTPUTS
    System.String[]

  .EXAMPLE
    Get-OmpBinaryCandidates
  #>
  return @(
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'omp\omp.exe'),
    (Join-Path -Path $env:USERPROFILE -ChildPath '.omp\bin\omp.exe'),
    (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin\omp.exe'),
    (Join-Path -Path $env:USERPROFILE -ChildPath '.bun\bin\omp.exe')
  )
}

function Find-OmpBinary {
  <#
  .SYNOPSIS
    Locates omp.exe: Get-Command first, then the known install paths.

  .DESCRIPTION
    Resolves the omp executable the subagent config can run by full path.
    Get-Command only sees what this session's PATH holds, so install.ps1
    refreshes $env:PATH from the registry after installing omp before it
    calls this; the fallback list is Get-OmpBinaryCandidates (overridable
    for tests). Returns $null when nothing is found.

  .PARAMETER CommandName
    Command to look up. Default 'omp'; empty skips the lookup.

  .PARAMETER Candidates
    Fallback paths. Default Get-OmpBinaryCandidates.

  .OUTPUTS
    System.String or $null

  .EXAMPLE
    $omp = Find-OmpBinary; if (-not $omp) { throw 'omp.exe not found' }
  #>
  param(
    [string]$CommandName = 'omp',
    [string[]]$Candidates
  )

  $exe = $null
  if ($CommandName) {
    $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
      $exe = [string]$cmd.Source
    }
  }
  if (-not $exe) {
    if (-not $Candidates -or $Candidates.Count -eq 0) {
      $Candidates = Get-OmpBinaryCandidates
    }
    foreach ($candidate in $Candidates) {
      if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $exe = $candidate
        break
      }
    }
  }
  return $exe
}

function Test-UvToolListText {
  <#
  .SYNOPSIS
    True when `uv tool list` output names the tool.

  .DESCRIPTION
    uv prints one "<name> <version>" line per installed tool (the version
    often carries a leading v). The comparison is on the first word, so
    'subagent' does not match 'subagent-mcp'. Used by localagent.ps1 status.

  .PARAMETER Text
    Output of `uv tool list`.

  .PARAMETER Name
    Tool (package) name, e.g. 'subagent'.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    Test-UvToolListText -Text (& uv tool list 2>&1 | Out-String) -Name 'subagent'
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory)][string]$Name
  )

  foreach ($line in ($Text -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -ieq $Name) {
      return $true
    }
    if ($t.Length -gt $Name.Length -and $t.Substring(0, $Name.Length) -ieq $Name -and $t.Substring($Name.Length, 1) -in @(' ', "`t")) {
      return $true
    }
  }
  return $false
}

# ---------------------------------------------------------------------------
# User PATH (HKCU:\Environment)
# ---------------------------------------------------------------------------

function Add-UserPath {
  <#
  .SYNOPSIS
    Adds a directory to the user PATH idempotently.

  .DESCRIPTION
    Edits HKCU:\Environment Path (kept as REG_EXPAND_SZ, existing
    %VAR% references are read unexpanded so nothing is destroyed) and
    appends the directory to $env:PATH for the current session. Broadcasts
    WM_SETTINGCHANGE so new processes pick it up, unless -NoBroadcast (the
    installer broadcasts once after all its PATH edits). No admin rights
    needed.

  .PARAMETER Dir
    Directory to add.

  .PARAMETER NoBroadcast
    Skip the WM_SETTINGCHANGE broadcast; call Send-PathSettingChange later.

  .OUTPUTS
    System.String: 'added' or 'present'.

  .EXAMPLE
    Add-UserPath -Dir (Get-LocalAgentPaths).Bin
  #>
  param(
    [Parameter(Mandatory)][string]$Dir,
    [switch]$NoBroadcast
  )

  $dir = $Dir.TrimEnd('\')
  if ($dir.Length -eq 2 -and $dir.Substring(1, 1) -eq ':') {
    $dir = $dir + '\'  # keep drive roots such as C:\ intact
  }

  $entries = Get-UserPathEntries
  $action = 'present'
  if (-not (Test-PathEntry -Entries $entries -Dir $dir)) {
    $entries = @($entries) + @($dir)
    $action = 'added'
  }

  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  if (-not $key) {
    throw 'Cannot open HKCU\Environment for writing.'
  }
  try {
    $key.SetValue('Path', ($entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
  }
  finally {
    $key.Close()
  }

  if (-not (($env:PATH -split ';') -icontains $Dir -or ($env:PATH -split ';') -icontains $dir)) {
    $env:PATH = "$env:PATH;$dir"
  }
  if (-not $NoBroadcast) {
    Send-PathSettingChange
  }
  return $action
}

function Remove-UserPath {
  <#
  .SYNOPSIS
    Removes a directory from the user PATH idempotently (uninstall).

  .DESCRIPTION
    Counterpart of Add-UserPath. Also drops the directory from $env:PATH
    for the current session.

  .PARAMETER Dir
    Directory to remove.

  .OUTPUTS
    System.String: 'removed' or 'absent'.

  .EXAMPLE
    Remove-UserPath -Dir (Get-LocalAgentPaths).Bin
  #>
  param([Parameter(Mandatory)][string]$Dir)

  $dir = $Dir.TrimEnd('\')
  if ($dir.Length -eq 2 -and $dir.Substring(1, 1) -eq ':') {
    $dir = $dir + '\'
  }

  $entries = Get-UserPathEntries
  $kept = @()
  $removed = $false
  foreach ($entry in $entries) {
    if ($entry -ieq $dir -or $entry -ieq $Dir) {
      $removed = $true
    }
    else {
      $kept = @($kept) + @($entry)
    }
  }
  if (-not $removed) {
    return 'absent'
  }

  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  if (-not $key) {
    throw 'Cannot open HKCU\Environment for writing.'
  }
  try {
    $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
  }
  finally {
    $key.Close()
  }

  $sessionKept = @()
  foreach ($piece in ($env:PATH -split ';')) {
    $t = $piece.Trim()
    if ($t -ne '' -and -not ($t -ieq $dir -or $t -ieq $Dir)) {
      $sessionKept = @($sessionKept) + @($t)
    }
  }
  $env:PATH = ($sessionKept -join ';')
  Send-PathSettingChange
  return 'removed'
}

function Get-UserPathEntries {
  # Internal: the raw (unexpanded) semicolon-separated user PATH entries.
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
  if (-not $key) {
    return @()
  }
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  }
  finally {
    $key.Close()
  }
  $entries = @()
  foreach ($piece in ($raw -split ';')) {
    $t = $piece.Trim()
    if ($t -ne '') {
      $entries = @($entries) + @($t)
    }
  }
  return $entries
}

function Test-PathEntry {
  # Internal: case-insensitive membership test over PATH entries.
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Entries,
    [Parameter(Mandatory)][string]$Dir
  )
  foreach ($entry in $Entries) {
    if ($entry -ieq $Dir) {
      return $true
    }
  }
  return $false
}

function Send-PathSettingChange {
  # Broadcast WM_SETTINGCHANGE so newly started processes (Explorer, new
  # terminals) see the updated user PATH without a re-login.
  $signature = @'
using System;
using System.Runtime.InteropServices;
public static class LocalAgentNative {
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
  try {
    Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue
    $result = [UIntPtr]::Zero
    [LocalAgentNative]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
  }
  catch {
    # Broadcasting is best effort; the registry value is already correct.
  }
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

function Invoke-CurlDownload {
  <#
  .SYNOPSIS
    Internal: the only place curl.exe is invoked.

  .DESCRIPTION
    Not exported. Separate from Invoke-Download so tests can Mock it and
    feed a fake exit code.

  .PARAMETER Url
    Source URL (kept for readable mock parameter filters).

  .PARAMETER OutFile
    Destination file path.

  .PARAMETER Arguments
    Full curl.exe argument vector.

  .OUTPUTS
    System.Int32 (curl.exe exit code)
  #>
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  & curl.exe @Arguments
  return $LASTEXITCODE
}

function Invoke-Download {
  <#
  .SYNOPSIS
    Downloads a file with curl.exe and verifies size and SHA256.

  .DESCRIPTION
    curl.exe -L -C - --retry 5 --retry-all-errors -o <file> <url>, so an
    interrupted download resumes on re-run (-Silent adds curl's
    --silent --show-error for non-interactive runs). Verifies the byte size
    and Get-FileHash SHA256 afterwards; returns $true on success and
    throws a clear message on any mismatch.

  .PARAMETER Url
    Source URL.

  .PARAMETER OutFile
    Destination file path. Parent folders are created when missing.

  .PARAMETER ExpectedSize
    Expected byte size; 0 skips the size check.

  .PARAMETER ExpectedSha256
    Expected SHA256 (any case); empty skips the hash check.

  .PARAMETER Silent
    Adds --silent --show-error (use in -NonInteractive installs).

  .PARAMETER Header
    Extra request headers passed as curl -H, e.g. an Authorization line.

  .OUTPUTS
    System.Boolean ($true)

  .EXAMPLE
    Invoke-Download -Url $c.ModelUrl -OutFile $tmp -ExpectedSize $c.ModelSize -ExpectedSha256 $c.ModelSha256
  #>
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [long]$ExpectedSize = 0,
    [string]$ExpectedSha256 = '',
    [switch]$Silent,
    [string[]]$Header = @()
  )

  $fsOut = ConvertTo-FsPath -Path $OutFile
  $parent = Split-Path -Path $fsOut -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
  }

  $curlArgs = [System.Collections.Generic.List[string]]::new()
  $curlArgs.Add('-L')
  $curlArgs.Add('-C')
  $curlArgs.Add('-')
  $curlArgs.Add('--retry'); $curlArgs.Add('5')
  $curlArgs.Add('--retry-all-errors')
  if ($Silent) {
    $curlArgs.Add('--silent'); $curlArgs.Add('--show-error')
  }
  foreach ($h in @($Header)) {
    if ("$h" -ne '') {
      $curlArgs.Add('-H'); $curlArgs.Add([string]$h)
    }
  }
  $curlArgs.Add('-o'); $curlArgs.Add($fsOut)
  $curlArgs.Add($Url)

  $exitCode = Invoke-CurlDownload -Url $Url -OutFile $fsOut -Arguments $curlArgs.ToArray()
  if ($exitCode -ne 0) {
    throw ("Download failed: curl.exe exit code {0} for {1}" -f $exitCode, $Url)
  }
  if (-not (Test-Path -LiteralPath $fsOut)) {
    throw "Download produced no file: $fsOut"
  }

  if ($ExpectedSize -gt 0) {
    $actualSize = (Get-Item -LiteralPath $fsOut).Length
    if ($actualSize -ne $ExpectedSize) {
      throw ("Size mismatch for {0}: got {1} bytes, expected {2}. Delete the file and re-run to resume." -f $fsOut, $actualSize, $ExpectedSize)
    }
  }

  if ("$ExpectedSha256" -ne '') {
    $actualHash = (Get-FileHash -LiteralPath $fsOut -Algorithm SHA256).Hash
    if (-not [string]::Equals($actualHash, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw ("SHA256 mismatch for {0}: got {1}, expected {2}. Delete the file and re-run." -f $fsOut, $actualHash, $ExpectedSha256)
    }
  }

  return $true
}

# ---------------------------------------------------------------------------
# Install helpers: task XML fill, llama binary discovery, smoke-test parsing
# ---------------------------------------------------------------------------

function Get-JsonProperty {
  # Internal: strict-mode-safe property read off a ConvertFrom-Json result.
  # Returns $null when the object or the property is missing.
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory)][string]$Name
  )
  if ($null -eq $Object) {
    return $null
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -ne $prop) {
    return $prop.Value
  }
  return $null
}

function ConvertTo-TaskArguments {
  <#
  .SYNOPSIS
    Joins an argv into one Windows command line, XML-escaped by default.

  .DESCRIPTION
    Quotes each argument the way CommandLineToArgvW / the MSVC runtime
    parse it back: arguments that are empty or contain a space, tab or
    double quote are wrapped in double quotes, an embedded quote becomes
    \", and backslashes are doubled only where they precede a quote
    (including the closing one). Everything else passes through as is, so
    C:\path\file.gguf stays readable. The joined line is then XML-escaped
    (& < > " ') for the <Arguments> element of templates/task.xml; -Raw
    skips that step for Start-Process and schtasks.

  .PARAMETER Argv
    Arguments, without the executable.

  .PARAMETER Raw
    Return the plain command line (no XML escaping).

  .OUTPUTS
    System.String

  .EXAMPLE
    $args = ConvertTo-TaskArguments -Argv (ConvertTo-ServerArgs -Config $cfg -ModelPath $p.ModelFile -LogFile $p.ServerLog)
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Argv,
    [switch]$Raw
  )

  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($arg in $Argv) {
    $a = [string]$arg
    if ($a -ne '' -and $a -notmatch '[\s"]') {
      $parts.Add($a)
      continue
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $a.ToCharArray()) {
      if ($ch -eq [char]'\') {
        $backslashes++
        continue
      }
      if ($ch -eq [char]'"') {
        [void]$sb.Append([char]'\', ($backslashes * 2) + 1)
        [void]$sb.Append('"')
      }
      else {
        if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes) }
        [void]$sb.Append($ch)
      }
      $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes * 2) }
    [void]$sb.Append('"')
    $parts.Add($sb.ToString())
  }
  $line = ($parts.ToArray() -join ' ')
  if ($Raw) {
    return $line
  }
  return [System.Security.SecurityElement]::Escape($line)
}

function Get-TaskActionArguments {
  <#
  .SYNOPSIS
    The Arguments text of the logon task: cmd.exe starts llama-server minimized.

  .DESCRIPTION
    The task's Command is %SystemRoot%\System32\cmd.exe and its Arguments are
      /c start "LocalAgent Server" /min "<exe>" <server argv>
    so the server window starts minimized in the taskbar and cmd.exe exits
    at once. The quoted window title must be the first quoted token after
    `start`, otherwise start takes the exe path as the title. The server
    argv is joined with ConvertTo-TaskArguments. Returns the plain line;
    -Xml escapes it for the task XML.

  .PARAMETER ServerExe
    Full path of llama-server.exe.

  .PARAMETER Argv
    llama-server arguments (ConvertTo-ServerArgs).

  .PARAMETER Xml
    XML-escape the result for templates/task.xml.

  .OUTPUTS
    System.String

  .EXAMPLE
    Get-TaskActionArguments -ServerExe $exe -Argv $argv -Xml
  #>
  param(
    [Parameter(Mandatory)][string]$ServerExe,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
    [switch]$Xml
  )
  $title = [string](Get-LocalAgentConstants).TaskName
  $line = '/c start "{0}" /min "{1}"' -f $title, $ServerExe
  $rest = ConvertTo-TaskArguments -Argv $Argv -Raw
  if ("$rest" -ne '') {
    $line = $line + ' ' + $rest
  }
  if ($Xml) {
    return [System.Security.SecurityElement]::Escape($line)
  }
  return $line
}

function ConvertTo-TaskXml {
  <#
  .SYNOPSIS
    Fills the placeholders of templates/task.xml.

  .DESCRIPTION
    Replaces {{USER}} (LogonTrigger/Principal user, e.g. 'DESKTOP\gary'),
    {{INSTALLDIR}} (the working directory) and {{ARGS}} (the <Arguments> text, already XML-escaped by
    Get-TaskActionArguments -Xml), then fails if any {{...}} placeholder is
    left, so a renamed placeholder cannot slip through silently. User and
    InstallDir are XML-escaped here.

  .PARAMETER Path
    Path to templates/task.xml.

  .PARAMETER User
    Account the task runs as, e.g. "$env:USERDOMAIN\$env:USERNAME".

  .PARAMETER InstallDir
    Package root; the action's working directory is <InstallDir>\llama.

  .PARAMETER Arguments
    XML-escaped task argument line (Get-TaskActionArguments -Xml).

  .OUTPUTS
    System.String (the filled task XML, ready for Register-ScheduledTask -Xml)

  .EXAMPLE
    $xml = ConvertTo-TaskXml -Path 'templates\task.xml' -User "$env:USERDOMAIN\$env:USERNAME" -InstallDir $p.InstallDir -Arguments $args
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$InstallDir,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    throw "Task template not found: $Path"
  }
  $xml = Get-Content -LiteralPath $fsPath -Raw
  $xml = $xml.Replace('{{USER}}', [System.Security.SecurityElement]::Escape($User))
  $xml = $xml.Replace('{{INSTALLDIR}}', [System.Security.SecurityElement]::Escape($InstallDir.TrimEnd('\')))
  $xml = $xml.Replace('{{ARGS}}', $Arguments)
  if ($xml.Contains('{{')) {
    throw "Task template still contains placeholders after filling: $Path"
  }
  return $xml
}

function Invoke-LogRotation {
  <#
  .SYNOPSIS
    Rotates a log file once it passes a size limit (server.log -> server.1.log).

  .DESCRIPTION
    llama-server truncates its --log-file when it opens it, so the CLI and
    the installer call this with -MaxBytes 1 before each start to keep the
    previous run's log: when the file is at least MaxBytes,
    server.(Keep-1).log moves to server.Keep.log (the oldest is dropped),
    and so on down to server.log -> server.1.log. Below the limit, or when the file is
    still held open by a running server, nothing happens.

  .PARAMETER Path
    The live log file.

  .PARAMETER MaxBytes
    Rotation threshold. Default 50 MB.

  .PARAMETER Keep
    Rotated copies to keep. Default 3.

  .OUTPUTS
    System.Boolean ($true when a rotation happened)

  .EXAMPLE
    Invoke-LogRotation -Path $p.ServerLog
  #>
  param(
    [Parameter(Mandatory)][string]$Path,
    [long]$MaxBytes = 50MB,
    [ValidateRange(1, 99)][int]$Keep = 3
  )

  $fsPath = ConvertTo-FsPath -Path $Path
  if (-not (Test-Path -LiteralPath $fsPath)) {
    return $false
  }
  if ((Get-Item -LiteralPath $fsPath).Length -lt $MaxBytes) {
    return $false
  }
  $dir = Split-Path -Path $fsPath -Parent
  $base = [System.IO.Path]::GetFileNameWithoutExtension($fsPath)
  $ext = [System.IO.Path]::GetExtension($fsPath)
  try {
    # The live file first: a running llama-server keeps it open and the
    # rename fails, in which case nothing else is shifted either.
    $staged = Join-Path -Path $dir -ChildPath ('{0}.rotating{1}' -f $base, $ext)
    Move-Item -LiteralPath $fsPath -Destination $staged -Force -ErrorAction Stop
  }
  catch {
    return $false
  }
  $oldest = Join-Path -Path $dir -ChildPath ('{0}.{1}{2}' -f $base, $Keep, $ext)
  if (Test-Path -LiteralPath $oldest) {
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue
  }
  for ($i = $Keep - 1; $i -ge 1; $i--) {
    $from = Join-Path -Path $dir -ChildPath ('{0}.{1}{2}' -f $base, $i, $ext)
    if (Test-Path -LiteralPath $from) {
      Move-Item -LiteralPath $from -Destination (Join-Path -Path $dir -ChildPath ('{0}.{1}{2}' -f $base, ($i + 1), $ext)) -Force
    }
  }
  Move-Item -LiteralPath $staged -Destination (Join-Path -Path $dir -ChildPath ('{0}.1{1}' -f $base, $ext)) -Force
  return $true
}

function Register-LocalAgentTask {
  <#
  .SYNOPSIS
    (Re-)registers the per-user logon task from the current config.json.

  .DESCRIPTION
    Builds the llama-server argv from config.json (ConvertTo-ServerArgs
    with --log-file <InstallDir>\logs\server.log), fills the task template
    and registers it with Register-ScheduledTask -Force. When that fails,
    the same XML goes through `schtasks /Create /XML` (a /TR command line
    is capped at 261 characters, too short for this argv). The task runs
    cmd.exe /c start /min <InstallDir>\llama\llama-server.exe under the
    current user (Get-TaskActionArguments), so the server window starts
    minimized.
    Used by install.ps1 and by `localagent restart|config|bench|model`.

  .PARAMETER InstallDir
    Package root.

  .PARAMETER ConfigPath
    config.json to build the arguments from.

  .PARAMETER TemplatePath
    Task XML template. Default <InstallDir>\templates\task.xml.

  .OUTPUTS
    PSCustomObject with Method ('Register-ScheduledTask' or 'schtasks'),
    User, Execute (the exe path) and Arguments (plain command line).

  .EXAMPLE
    Register-LocalAgentTask -InstallDir $p.InstallDir -ConfigPath $p.Config
  #>
  param(
    [Parameter(Mandatory)][string]$InstallDir,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$TemplatePath = ''
  )

  $paths = Get-LocalAgentPaths -InstallDir $InstallDir
  if ("$TemplatePath" -eq '') {
    $TemplatePath = $paths.TaskTemplate
  }
  $taskName = [string](Get-LocalAgentConstants).TaskName
  $config = Read-LocalAgentConfig -Path $ConfigPath
  $argv = ConvertTo-ServerArgs -Config $config -ModelPath $paths.ModelFile -LogFile $paths.ServerLog
  $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $exe = Join-Path -Path $paths.Llama -ChildPath 'llama-server.exe'
  $xml = ConvertTo-TaskXml -Path $TemplatePath -User $user -InstallDir $paths.InstallDir -Arguments (Get-TaskActionArguments -ServerExe $exe -Argv $argv -Xml)

  $method = 'Register-ScheduledTask'
  try {
    Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
  }
  catch {
    $method = 'schtasks'
    $firstError = ($_.Exception.Message -replace "`r?`n", ' ')
    $xmlFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('localagent-task-' + [System.Guid]::NewGuid().ToString('N') + '.xml')
    try {
      [System.IO.File]::WriteAllText($xmlFile, $xml, [System.Text.Encoding]::Unicode)
      $probe = Invoke-NativeProbe -FilePath 'schtasks.exe' -Arguments ('/Create /F /TN "{0}" /XML "{1}"' -f $taskName, $xmlFile) -TimeoutSeconds 60
    }
    finally {
      Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue
    }
    if ($probe.ExitCode -ne 0) {
      throw ('could not register the scheduled task "{0}": Register-ScheduledTask said "{1}"; schtasks /Create /XML exited {2}: {3}' -f $taskName, $firstError, $probe.ExitCode, ($probe.Output.Trim() -replace "`r?`n", ' '))
    }
  }
  return [pscustomobject]@{
    Method    = $method
    User      = $user
    Execute   = '%SystemRoot%\System32\cmd.exe'
    Arguments = (Get-TaskActionArguments -ServerExe $exe -Argv $argv)
  }
}

function Find-LlamaServerPath {
  <#
  .SYNOPSIS
    Locates llama-server.exe (or llama-cli.exe) under a directory.

  .DESCRIPTION
    Checks the directory root first, then scans recursively, preferring
    llama-server.exe over llama-cli.exe. Returns $null when neither exists.
    Used after Expand-Archive because the release zip may nest the binaries
    in a subfolder.

  .PARAMETER Dir
    Directory to search (the install's llama\ folder).

  .OUTPUTS
    System.String or $null

  .EXAMPLE
    $exe = Find-LlamaServerPath -Dir $p.Llama
  #>
  param([Parameter(Mandatory)][string]$Dir)

  $fsDir = ConvertTo-FsPath -Path $Dir
  if (-not (Test-Path -LiteralPath $fsDir)) {
    return $null
  }
  foreach ($name in @('llama-server.exe', 'llama-cli.exe')) {
    $direct = Join-Path -Path $fsDir -ChildPath $name
    if (Test-Path -LiteralPath $direct) {
      return $direct
    }
  }
  foreach ($name in @('llama-server.exe', 'llama-cli.exe')) {
    $hits = @(Get-ChildItem -LiteralPath $fsDir -Recurse -Filter $name -File -ErrorAction SilentlyContinue)
    if ($hits.Count -gt 0) {
      return [string]$hits[0].FullName
    }
  }
  return $null
}

function Read-TextFileShared {
  # Internal: reads a whole text file with FileShare ReadWrite so a file
  # another process keeps open for writing (a live server.log, a redirected
  # stream) can still be read.
  param([Parameter(Mandatory)][string]$Path)
  $fsPath = ConvertTo-FsPath -Path $Path
  $stream = [System.IO.FileStream]::new($fsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $reader = [System.IO.StreamReader]::new($stream)
    try {
      return $reader.ReadToEnd()
    }
    finally {
      $reader.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Get-CpuInfoFromServerLog {
  <#
  .SYNOPSIS
    Pulls the CPU feature line and the CPU backend line out of server.log.

  .DESCRIPTION
    llama-server prints system_info only after the model is loaded, so the
    installer checks CPU features once the server is healthy by reading
    the tail of logs\server.log. Finds the last line containing
    "system_info:" (e.g. "system_info: n_threads = 16 (n_threads_batch =
    64) / 64 | CPU : SSE3 = 1 | AVX2 = 1 | ... |") and the last
    "load_backend: loaded CPU backend from ...ggml-cpu-<name>.dll" line,
    which tells which kernel set was picked.

  .PARAMETER Lines
    Log lines (typically the last 400 of server.log).

  .OUTPUTS
    PSCustomObject with SystemInfo (string or ''), Backend (string or ''),
    Flags (hashtable from Get-SystemInfoFlags, empty when no line) and
    HasAvx2 ($true / $false / $null when there is no system_info line).

  .EXAMPLE
    $cpu = Get-CpuInfoFromServerLog -Lines (Get-Content $p.ServerLog -Tail 400)
  #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

  $systemInfo = ''
  $backend = ''
  foreach ($line in $Lines) {
    $s = [string]$line
    if ($s -match 'system_info:') { $systemInfo = $s.Trim() }
    if ($s -match 'load_backend:.*CPU backend') { $backend = $s.Trim() }
  }
  $flags = @{}
  $hasAvx2 = $null
  if ($systemInfo -ne '') {
    $flags = Get-SystemInfoFlags -Text ($systemInfo -replace '^.*system_info:', '')
    $hasAvx2 = Test-Avx2 -Flags $flags
  }
  return [pscustomobject]@{
    SystemInfo = $systemInfo
    Backend    = $backend
    Flags      = $flags
    HasAvx2    = $hasAvx2
  }
}

function Invoke-NativeProbe {
  <#
  .SYNOPSIS
    Runs a native executable, capturing stdout+stderr and the exit code.

  .DESCRIPTION
    Start-Process with both streams redirected to temp files, so PowerShell
    5.1 never wraps stderr lines in NativeCommandError records (which
    "2>&1 | Out-String" does under -ErrorAction Stop) and the loader exit
    code (e.g. STATUS_DLL_NOT_FOUND) is reported as-is. The process is
    killed when it outlives TimeoutSeconds.

  .PARAMETER FilePath
    Executable path.

  .PARAMETER Arguments
    Argument string; quote paths with spaces yourself.

  .PARAMETER TimeoutSeconds
    Kill after this many seconds. Default 120.

  .PARAMETER EmptyStdin
    Give the process an empty stdin (EOF at once). omp -p waits for piped
    input to end, so an inherited stdin that never closes hangs it.

  .OUTPUTS
    PSCustomObject with ExitCode (int), Output (string, both streams,
    stdout first) and TimedOut (bool; ExitCode is -1 then).

  .EXAMPLE
    $r = Invoke-NativeProbe -FilePath $exe -Arguments '--version'; if ($r.ExitCode -ne 0) { throw $r.Output }
  #>
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$Arguments = '',
    [int]$TimeoutSeconds = 120,
    [switch]$EmptyStdin
  )

  $stamp = [System.Guid]::NewGuid().ToString('N')
  $outFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('localagent-probe-' + $stamp + '.out')
  $errFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('localagent-probe-' + $stamp + '.err')
  $inFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('localagent-probe-' + $stamp + '.in')
  $timedOut = $false
  $exitCode = -1
  try {
    $startArgs = @{
      FilePath               = $FilePath
      RedirectStandardOutput = $outFile
      RedirectStandardError  = $errFile
      NoNewWindow            = $true
      PassThru               = $true
    }
    if ("$Arguments" -ne '') {
      $startArgs['ArgumentList'] = $Arguments
    }
    if ($EmptyStdin) {
      [System.IO.File]::WriteAllText($inFile, '')
      $startArgs['RedirectStandardInput'] = $inFile
    }
    $proc = Start-Process @startArgs
    $null = $proc.Handle  # cache the handle so ExitCode is readable after exit
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
      $exitCode = [int]$proc.ExitCode
    }
    else {
      $timedOut = $true
      # Kill the whole tree: a child (e.g. cmd.exe's grandchild) would keep
      # the redirected files open otherwise.
      try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch { }
      try { $proc.Kill() } catch { }
      $proc.WaitForExit(5000) | Out-Null
    }
    $text = ''
    foreach ($f in @($outFile, $errFile)) {
      if (Test-Path -LiteralPath $f) {
        # Shared read: a lingering child may still hold the handle.
        $text += Read-TextFileShared -Path $f
      }
    }
  }
  finally {
    Remove-Item -LiteralPath $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $text
    TimedOut = $timedOut
  }
}

function Get-SmokeToolCallName {
  <#
  .SYNOPSIS
    Extracts the first tool-call function name from a chat completion JSON.

  .DESCRIPTION
    Parses the /v1/chat/completions response and returns
    choices[0].message.tool_calls[0].function.name, or $null when the
    response is not valid JSON or any level of that path is missing.
    Used by install.ps1's smoke test, which requires 'get_weather'.

  .PARAMETER ResponseText
    Raw HTTP response body.

  .OUTPUTS
    System.String or $null

  .EXAMPLE
    if ((Get-SmokeToolCallName -ResponseText $resp.Content) -ne 'get_weather') { throw 'no tool call' }
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$ResponseText)

  if ([string]::IsNullOrWhiteSpace($ResponseText)) {
    return $null
  }
  try {
    $parsed = ConvertFrom-Json -InputObject $ResponseText
  }
  catch {
    return $null
  }
  if ($null -eq $parsed) {
    return $null
  }
  $choices = Get-JsonProperty -Object $parsed -Name 'choices'
  $first = @($choices)[0]
  $message = Get-JsonProperty -Object $first -Name 'message'
  $toolCalls = Get-JsonProperty -Object $message -Name 'tool_calls'
  if ($null -eq $toolCalls) {
    return $null
  }
  $firstCall = @($toolCalls)[0]
  $function = Get-JsonProperty -Object $firstCall -Name 'function'
  $name = Get-JsonProperty -Object $function -Name 'name'
  if ($null -eq $name) {
    return $null
  }
  return [string]$name
}

function Get-SmokeTimingsPerSecond {
  <#
  .SYNOPSIS
    Extracts the generation speed from a llama.cpp chat completion JSON.

  .DESCRIPTION
    Returns the response's timings.predicted_per_second (tokens per second,
    invariant culture) or $null when absent or unparsable. Used to report
    the measured generation speed in the smoke-test step.

  .PARAMETER ResponseText
    Raw HTTP response body.

  .OUTPUTS
    System.Double or $null

  .EXAMPLE
    $tps = Get-SmokeTimingsPerSecond -ResponseText $resp.Content
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$ResponseText)

  if ([string]::IsNullOrWhiteSpace($ResponseText)) {
    return $null
  }
  try {
    $parsed = ConvertFrom-Json -InputObject $ResponseText
  }
  catch {
    return $null
  }
  if ($null -eq $parsed) {
    return $null
  }
  $timings = Get-JsonProperty -Object $parsed -Name 'timings'
  $value = Get-JsonProperty -Object $timings -Name 'predicted_per_second'
  if ($null -eq $value) {
    return $null
  }
  $out = 0.0
  $ok = [double]::TryParse(
    [string]$value,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$out)
  if ($ok) {
    return $out
  }
  return $null
}

# ---------------------------------------------------------------------------
# `localagent model`: model spec parsing, Hugging Face file selection
# ---------------------------------------------------------------------------

function Resolve-ModelSpec {
  <#
  .SYNOPSIS
    Classifies the argument of `localagent model`.

  .DESCRIPTION
    Kinds: 'list' (--list / -list / list), 'default', 'url' (http(s)://),
    'local' (ends in .gguf, or starts like a Windows path), 'hf'
    ("owner/name" or "owner/name:QUANT", as the Hugging Face page shows
    it). Anything else is 'invalid'.

  .PARAMETER Spec
    The argument as typed.

  .OUTPUTS
    PSCustomObject with Kind, Value (path, URL or repo), Repo, Quant.

  .EXAMPLE
    Resolve-ModelSpec -Spec 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL'
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Spec)

  $t = "$Spec".Trim().Trim('"')
  $result = [pscustomobject]@{ Kind = 'invalid'; Value = $t; Repo = ''; Quant = '' }
  if ($t -eq '') {
    return $result
  }
  if ($t -in @('--list', '-list', 'list', '-l')) {
    $result.Kind = 'list'
    return $result
  }
  if ($t -ieq 'default') {
    $result.Kind = 'default'
    return $result
  }
  if ($t -match '^(?i)https?://') {
    $result.Kind = 'url'
    return $result
  }
  if ($t -match '(?i)\.gguf$' -or $t -match '^[A-Za-z]:[\\/]' -or $t -match '^\\\\' -or $t -match '^\.{1,2}[\\/]') {
    $result.Kind = 'local'
    return $result
  }
  $m = [regex]::Match($t, '^([A-Za-z0-9][A-Za-z0-9._-]*)/([A-Za-z0-9][A-Za-z0-9._-]*)(:([A-Za-z0-9._-]+))?$')
  if ($m.Success) {
    $result.Kind = 'hf'
    $result.Repo = '{0}/{1}' -f $m.Groups[1].Value, $m.Groups[2].Value
    $result.Value = $result.Repo
    $result.Quant = $m.Groups[4].Value
  }
  return $result
}

function Get-GgufSetKey {
  # Internal: "dir/name-00001-of-00003.gguf" -> "dir/name-of-00003" (one
  # key per split set); any other path is its own key.
  param([Parameter(Mandatory)][string]$Path)
  $m = [regex]::Match($Path, '^(.*)-(\d{5})-of-(\d{5})\.gguf$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) {
    return ('{0}-of-{1}' -f $m.Groups[1].Value, $m.Groups[3].Value).ToLowerInvariant()
  }
  return $Path.ToLowerInvariant()
}

function Get-GgufStem {
  # Internal: file name without directory, split suffix and .gguf.
  param([Parameter(Mandatory)][string]$Path)
  $leaf = ($Path -split '/')[-1]
  $leaf = [regex]::Replace($leaf, '-\d{5}-of-\d{5}\.gguf$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  return [regex]::Replace($leaf, '\.gguf$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-HfGgufSets {
  <#
  .SYNOPSIS
    Groups the .gguf files of a Hugging Face tree listing into model sets.

  .DESCRIPTION
    Keeps entries of type 'file' whose path ends in .gguf and whose file
    name does not start with "mmproj" (vision projectors are not models).
    Split files (-00001-of-0000N.gguf) of one set become one group. Each
    file carries Path, Size (lfs.size, else size) and Sha256 (lfs.oid).

  .PARAMETER Tree
    Objects from GET /api/models/<repo>/tree/main?recursive=true.

  .OUTPUTS
    PSCustomObject[] with Key, Stem, Files (sorted by path), TotalBytes.

  .EXAMPLE
    Get-HfGgufSets -Tree $tree | ForEach-Object { $_.Stem }
  #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tree)

  $groups = [ordered]@{}
  foreach ($entry in $Tree) {
    $type = [string](Get-JsonProperty -Object $entry -Name 'type')
    $path = [string](Get-JsonProperty -Object $entry -Name 'path')
    if ($type -ne 'file' -or $path -notmatch '(?i)\.gguf$') {
      continue
    }
    $leaf = ($path -split '/')[-1]
    if ($leaf -match '^(?i)mmproj') {
      continue
    }
    $lfs = Get-JsonProperty -Object $entry -Name 'lfs'
    $size = Get-JsonProperty -Object $lfs -Name 'size'
    if ($null -eq $size) {
      $size = Get-JsonProperty -Object $entry -Name 'size'
    }
    $sha = [string](Get-JsonProperty -Object $lfs -Name 'oid')
    $file = [pscustomobject]@{ Path = $path; Size = [long]$size; Sha256 = $sha }
    $key = Get-GgufSetKey -Path $path
    if (-not $groups.Contains($key)) {
      $groups[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $groups[$key].Add($file)
  }
  $sets = @()
  foreach ($key in $groups.Keys) {
    $files = @($groups[$key] | Sort-Object -Property Path)
    $total = [long]0
    foreach ($f in $files) { $total += [long]$f.Size }
    $sets = @($sets) + @([pscustomobject]@{
        Key        = $key
        Stem       = (Get-GgufStem -Path $files[0].Path)
        Files      = $files
        TotalBytes = $total
      })
  }
  return $sets
}

function Select-HfGgufFiles {
  <#
  .SYNOPSIS
    Picks the .gguf file(s) of one quant from a Hugging Face tree listing.

  .DESCRIPTION
    Candidate sets (Get-HfGgufSets: .gguf, no mmproj, split sets grouped)
    whose path contains the quant tag, case-insensitively. More than one
    set: those whose name (without split suffix and .gguf) ends with the
    tag win, so Q4_0 picks model-Q4_0.gguf over model-Q4_0_4_4.gguf. Still
    more than one, or none: Status is 'ambiguous' or 'none' and Candidates
    lists what was found so the caller can print it.

  .PARAMETER Tree
    Objects from GET /api/models/<repo>/tree/main?recursive=true.

  .PARAMETER Quant
    Quant tag as on the Hugging Face page, e.g. 'UD-Q3_K_XL'.

  .OUTPUTS
    PSCustomObject with Status ('ok' | 'none' | 'ambiguous'), Files (the
    chosen set: Path, Size, Sha256, first shard first), TotalBytes and
    Candidates (the matching sets, or all sets when none matched).

  .EXAMPLE
    $pick = Select-HfGgufFiles -Tree $tree -Quant 'UD-Q2_K_XL'
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tree,
    [Parameter(Mandatory)][string]$Quant
  )

  $all = @(Get-HfGgufSets -Tree $Tree)
  $needle = $Quant.ToLowerInvariant()
  $matched = @($all | Where-Object { $_.Files[0].Path.ToLowerInvariant().Contains($needle) })
  if ($matched.Count -gt 1) {
    $suffix = @($matched | Where-Object { $_.Stem.ToLowerInvariant().EndsWith($needle) })
    if ($suffix.Count -ge 1) {
      $matched = $suffix
    }
  }
  $status = 'ok'
  $files = @()
  $total = [long]0
  $candidates = $matched
  if ($matched.Count -eq 0) {
    $status = 'none'
    $candidates = $all
  }
  elseif ($matched.Count -gt 1) {
    $status = 'ambiguous'
  }
  else {
    $files = @($matched[0].Files)
    $total = [long]$matched[0].TotalBytes
  }
  return [pscustomobject]@{
    Status     = $status
    Files      = $files
    TotalBytes = $total
    Candidates = @($candidates)
  }
}

function Get-HfModelDirName {
  <#
  .SYNOPSIS
    models\ subfolder for a Hugging Face repo: owner/name -> owner__name.

  .PARAMETER Repo
    'owner/name'.

  .OUTPUTS
    System.String

  .EXAMPLE
    Get-HfModelDirName -Repo 'unsloth/Qwen3.6-35B-A3B-GGUF'
  #>
  param([Parameter(Mandatory)][string]$Repo)
  return ($Repo -replace '/', '__')
}

function Test-ModelFitsRam {
  <#
  .SYNOPSIS
    True when the model weights leave at least ReserveBytes of RAM free.

  .DESCRIPTION
    The rule from the README: weights must be no larger than total RAM
    minus 8 GB (the KV cache, the OS and the editor need the rest), so a
    32 GB PC takes weights up to about 24 GB.

  .PARAMETER ModelBytes
    Total size of the model file(s).

  .PARAMETER TotalRamBytes
    Physical RAM.

  .PARAMETER ReserveBytes
    Headroom. Default 8 GB.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    Test-ModelFitsRam -ModelBytes 13GB -TotalRamBytes 32GB
  #>
  param(
    [Parameter(Mandatory)][long]$ModelBytes,
    [Parameter(Mandatory)][long]$TotalRamBytes,
    [long]$ReserveBytes = 8GB
  )
  return ($ModelBytes -le ($TotalRamBytes - $ReserveBytes))
}

function Get-ModelLoadTimeout {
  <#
  .SYNOPSIS
    Health-wait budget for a model: 60 s plus 30 s per GB of weights.

  .PARAMETER ModelBytes
    Total size of the model file(s).

  .OUTPUTS
    System.Int32 (seconds)

  .EXAMPLE
    Get-ModelLoadTimeout -ModelBytes 12GB
  #>
  param([Parameter(Mandatory)][long]$ModelBytes)
  return [int](60 + [math]::Ceiling(30.0 * $ModelBytes / 1GB))
}

function Test-MtpLoadError {
  <#
  .SYNOPSIS
    True when server log lines show that MTP / draft decoding broke the load.

  .DESCRIPTION
    Looks for a line that names MTP, a draft model or a nextn layer (the
    MTP head) together with an error word (error, failed, missing, not
    found, unable, invalid, unsupported, abort).

  .PARAMETER Lines
    server.log lines written since the start.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    Test-MtpLoadError -Lines (Get-Content $p.ServerLog -Tail 200)
  #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
  foreach ($line in $Lines) {
    $s = [string]$line
    if ($s -match '(?i)(mtp|draft|nextn)' -and $s -match '(?i)(error|fail|missing|not found|unable|invalid|unsupported|abort)') {
      return $true
    }
  }
  return $false
}

function Get-TotalRamBytes {
  # Physical RAM in bytes (Win32_ComputerSystem), 0 when unreadable.
  try {
    return [long](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
  }
  catch {
    return [long]0
  }
}

# ---------------------------------------------------------------------------
# CLI helpers: health, server process, llama-bench parsing
# ---------------------------------------------------------------------------

function Test-LocalAgentHealth {
  <#
  .SYNOPSIS
    True when the local server answers /health with 200.

  .DESCRIPTION
    Loopback-only call (no firewall prompt possible). Any exception, HTTP
    status other than 200, or timeout means "not healthy".

  .PARAMETER Port
    Server port from config.json. Default 8080.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (Test-LocalAgentHealth -Port $cfg.port) { 'up' }
  #>
  param([int]$Port = 8080)
  try {
    $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/health' -f $Port) -UseBasicParsing -TimeoutSec 3
    return ($resp.StatusCode -eq 200)
  }
  catch {
    return $false
  }
}

function Wait-LocalAgentHealth {
  <#
  .SYNOPSIS
    Polls /health until it answers 200 or the timeout elapses.

  .DESCRIPTION
    Polls every IntervalSeconds (default 5). The first model load reads
    ~23 GB from disk through mmap, so give it a generous timeout (the
    installer and `localagent start` use 600 s).

  .PARAMETER Port
    Server port. Default 8080.

  .PARAMETER TimeoutSeconds
    Total budget. Default 600.

  .PARAMETER IntervalSeconds
    Seconds between polls. Default 5.

  .OUTPUTS
    System.Boolean

  .EXAMPLE
    if (-not (Wait-LocalAgentHealth -Port 8080 -TimeoutSeconds 600)) { throw 'server not healthy' }
  #>
  param(
    [int]$Port = 8080,
    [int]$TimeoutSeconds = 600,
    [int]$IntervalSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-LocalAgentHealth -Port $Port) {
      return $true
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
  return $false
}

function Get-ServerProcess {
  <#
  .SYNOPSIS
    Finds running llama-server.exe processes started from this install.

  .DESCRIPTION
    Queries Win32_Process for llama-server.exe and keeps only processes
    whose ExecutablePath lives under <InstallDir>\llama\, so other installs
    are never touched. Returns normalized rows (ProcessId, WorkingSetMB,
    ExecutablePath, CommandLine); an empty array when nothing is running.

  .PARAMETER InstallDir
    Package root. Defaults to the standard install dir.

  .OUTPUTS
    System.Object[]

  .EXAMPLE
    Get-ServerProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  #>
  param([string]$InstallDir)

  if (-not $InstallDir) {
    $InstallDir = (Get-LocalAgentPaths).InstallDir
  }
  $llamaDir = Join-Path -Path $InstallDir -ChildPath 'llama'

  $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue)
  $result = @()
  foreach ($proc in $procs) {
    $exe = [string]$proc.ExecutablePath
    if ($exe -and $exe.StartsWith($llamaDir, [System.StringComparison]::OrdinalIgnoreCase)) {
      $workingSet = 0
      if ($null -ne $proc.WorkingSetSize) {
        $workingSet = [math]::Round($proc.WorkingSetSize / 1MB, 1)
      }
      $result = @($result) + @([pscustomobject]@{
        ProcessId      = [int]$proc.ProcessId
        WorkingSetMB   = $workingSet
        ExecutablePath = $exe
        CommandLine    = [string]$proc.CommandLine
      })
    }
  }
  return $result
}

function ConvertFrom-LlamaBenchJson {
  <#
  .SYNOPSIS
    Parses llama-bench -o json output into normalized rows.

  .DESCRIPTION
    Returns one object per benchmark row with Test (e.g. 'tg128'), NThreads,
    AvgTs (tokens per second) and the Raw row object. Returns an empty array
    when the text is empty or not valid JSON.

  .PARAMETER Text
    Raw stdout of `llama-bench ... -o json`.

  .OUTPUTS
    System.Object[]

  .EXAMPLE
    $rows = ConvertFrom-LlamaBenchJson -Text $stdout; $rows | Format-Table
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }
  try {
    $parsed = ConvertFrom-Json -InputObject $Text
  }
  catch {
    return @()
  }
  if ($null -eq $parsed) {
    return @()
  }

  $rows = @()
  foreach ($item in @($parsed)) {
    if ($null -eq $item) {
      continue
    }
    $test = Get-JsonProperty -Object $item -Name 'test'
    $threads = Get-JsonProperty -Object $item -Name 'n_threads'
    $avg = Get-JsonProperty -Object $item -Name 'avg_ts'
    $threadsInt = 0
    if ($null -ne $threads) {
      [void][int]::TryParse([string]$threads, [ref]$threadsInt)
    }
    $avgDouble = 0.0
    if ($null -ne $avg) {
      [void][double]::TryParse([string]$avg, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$avgDouble)
    }
    $rows = @($rows) + @([pscustomobject]@{
      Test     = [string]$test
      NThreads = $threadsInt
      AvgTs    = $avgDouble
      Raw      = $item
    })
  }
  return $rows
}

function Select-FastestThreads {
  <#
  .SYNOPSIS
    Picks the thread count with the highest tokens/sec for one test type.

  .DESCRIPTION
    Filters benchmark rows (ConvertFrom-LlamaBenchJson) to Test (default
    'tg128', the generation speed that matters for chat) and returns the
    NThreads of the fastest row, or $null when no row matches.

  .PARAMETER Rows
    Rows from ConvertFrom-LlamaBenchJson.

  .PARAMETER Test
    Test type to optimize. Default 'tg128'.

  .OUTPUTS
    System.Int32 or $null

  .EXAMPLE
    $best = Select-FastestThreads -Rows $rows; if ($null -ne $best) { $config.threads = $best }
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
    [string]$Test = 'tg128'
  )

  $best = $null
  $bestTs = [double]::NegativeInfinity
  foreach ($row in $Rows) {
    if ($null -eq $row) {
      continue
    }
    if ("$($row.Test)" -ne $Test) {
      continue
    }
    $ts = 0.0
    if ($null -ne $row.AvgTs) {
      [void][double]::TryParse([string]$row.AvgTs, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ts)
    }
    if ($ts -gt $bestTs) {
      $bestTs = $ts
      $best = [int]$row.NThreads
    }
  }
  return $best
}

# ---------------------------------------------------------------------------
# Exports (Get-SystemFacts, Invoke-CurlDownload and the other small helpers
# above stay internal so tests can Mock them in the module scope)
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
  'Get-LocalAgentPaths',
  'Get-LocalAgentConstants',
  'New-LocalAgentConfig',
  'ConvertTo-ServerArgs',
  'Read-LocalAgentConfig',
  'Write-LocalAgentConfig',
  'Test-Preflight',
  'Test-VcRuntime',
  'Test-VcRedistExitCode',
  'Test-RealPythonPath',
  'Get-PythonVersionFromText',
  'Test-PythonAvailable',
  'Test-GitAvailable',
  'Update-SessionPath',
  'Join-PathList',
  'Get-NativeExitCodeHint',
  'Get-SystemInfoFlags',
  'Test-Avx2',
  'Merge-JsonArrayEntry',
  'Remove-JsonArrayEntry',
  'Get-JsonProperty',
  'Set-JsonObjectKey',
  'Remove-JsonObjectKey',
  'Set-ManagedBlock',
  'Remove-ManagedBlock',
  'Set-YamlTopLevelMap',
  'Remove-YamlTopLevelMapKeys',
  'Set-YamlScalar',
  'Remove-YamlScalar',
  'Get-OmpModelRoles',
  'Get-VsCodeModelEntry',
  'ConvertTo-SubagentToml',
  'Set-SubagentToml',
  'Test-TomlTablePresent',
  'Get-SubagentBinaryFromToml',
  'Get-OmpBinaryCandidates',
  'Find-OmpBinary',
  'Test-UvToolListText',
  'Add-UserPath',
  'Send-PathSettingChange',
  'Remove-UserPath',
  'Invoke-Download',
  'ConvertTo-TaskXml',
  'ConvertTo-TaskArguments',
  'Get-TaskActionArguments',
  'Invoke-LogRotation',
  'Register-LocalAgentTask',
  'Resolve-ModelSpec',
  'Get-HfGgufSets',
  'Select-HfGgufFiles',
  'Get-HfModelDirName',
  'Test-ModelFitsRam',
  'Get-ModelLoadTimeout',
  'Test-MtpLoadError',
  'Get-TotalRamBytes',
  'Find-LlamaServerPath',
  'Invoke-NativeProbe',
  'Get-CpuInfoFromServerLog',
  'Get-SmokeToolCallName',
  'Get-SmokeTimingsPerSecond',
  'Test-LocalAgentHealth',
  'Wait-LocalAgentHealth',
  'Get-ServerProcess',
  'ConvertFrom-LlamaBenchJson',
  'Select-FastestThreads'
)
