# Pester 5 tests for the localagent CLI helpers in lib/localagent.psm1
# (llama-bench JSON parsing, fastest-thread selection, server process lookup).
# Run with: Invoke-Pester tests/Cli.Tests.ps1

BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1') -Force
}

Describe 'ConvertFrom-LlamaBenchJson' {
  BeforeAll {
    $script:benchJson = @'
[
  {"build_info":"b10757-abc","n_gpu_layers":0,"n_batch":2048,"n_ubatch":512,"n_threads":8,"cpu_info":"AMD EPYC 7763 64-Core Processor","gpu_info":"n/a","backends":["CPU"],"model_type":"qwen3","n_ctx":131072,"test":"tg128","n_prompt":0,"n_gen":128,"avg_ts":11.20,"stddev_ts":0.31},
  {"build_info":"b10757-abc","n_gpu_layers":0,"n_batch":2048,"n_ubatch":512,"n_threads":32,"cpu_info":"AMD EPYC 7763 64-Core Processor","gpu_info":"n/a","backends":["CPU"],"model_type":"qwen3","n_ctx":131072,"test":"tg128","n_prompt":0,"n_gen":128,"avg_ts":14.90,"stddev_ts":0.12},
  {"build_info":"b10757-abc","n_gpu_layers":0,"n_batch":2048,"n_ubatch":512,"n_threads":8,"cpu_info":"AMD EPYC 7763 64-Core Processor","gpu_info":"n/a","backends":["CPU"],"model_type":"qwen3","n_ctx":131072,"test":"pp512","n_prompt":512,"n_gen":0,"avg_ts":55.10,"stddev_ts":0.44}
]
'@
  }

  It 'parses llama-bench rows into normalized objects' {
    $rows = ConvertFrom-LlamaBenchJson -Text $script:benchJson
    @($rows).Count | Should -Be 3
    $rows[0].Test | Should -Be 'tg128'
    $rows[0].NThreads | Should -Be 8
    $rows[0].AvgTs | Should -Be 11.20
    $rows[2].Test | Should -Be 'pp512'
    $rows[2].AvgTs | Should -Be 55.10
    $rows[0].Raw.n_ctx | Should -Be 131072
  }

  It 'returns an empty array for empty or unparsable output' {
    @((ConvertFrom-LlamaBenchJson -Text '')).Count | Should -Be 0
    @((ConvertFrom-LlamaBenchJson -Text 'running benchmark...')).Count | Should -Be 0
    @((ConvertFrom-LlamaBenchJson -Text '{"broken":')).Count | Should -Be 0
  }

  It 'handles a single (non-wrapped) row object' {
    $rows = ConvertFrom-LlamaBenchJson -Text '{"test":"tg128","n_threads":64,"avg_ts":12.25}'
    @($rows).Count | Should -Be 1
    $rows[0].NThreads | Should -Be 64
    $rows[0].AvgTs | Should -Be 12.25
  }
}

Describe 'Select-FastestThreads' {
  BeforeAll {
    $script:rows = @(
      [pscustomobject]@{ Test = 'tg128'; NThreads = 8;  AvgTs = 11.2 }
      [pscustomobject]@{ Test = 'tg128'; NThreads = 32; AvgTs = 14.9 }
      [pscustomobject]@{ Test = 'tg128'; NThreads = 64; AvgTs = 12.3 }
      [pscustomobject]@{ Test = 'pp512'; NThreads = 64; AvgTs = 99.9 }
    )
  }

  It 'returns the tg128 row with the highest tokens/sec' {
    Select-FastestThreads -Rows $script:rows | Should -Be 32
  }

  It 'honours the -Test selector (ignoring faster rows of other tests)' {
    Select-FastestThreads -Rows $script:rows -Test 'pp512' | Should -Be 64
  }

  It 'returns null when no row matches or there are no rows' {
    $onlyPp = @([pscustomobject]@{ Test = 'pp512'; NThreads = 8; AvgTs = 55.0 })
    Select-FastestThreads -Rows $onlyPp | Should -Be $null
    Select-FastestThreads -Rows @() | Should -Be $null
  }
}

Describe 'Get-ServerProcess' {
  It 'keeps only llama-server.exe processes running from this install' {
    InModuleScope Localagent {
      Mock Get-CimInstance {
        return @(
          [pscustomobject]@{
            Name           = 'llama-server.exe'
            ProcessId      = 101
            WorkingSetSize = [uint64]8589934592
            ExecutablePath = 'C:\la\llama\llama-server.exe'
            CommandLine    = 'llama-server.exe -m C:\la\models\q.gguf --host 127.0.0.1'
          },
          [pscustomobject]@{
            Name           = 'llama-server.exe'
            ProcessId      = 202
            WorkingSetSize = [uint64]1073741824
            ExecutablePath = 'C:\other\llama\llama-server.exe'
            CommandLine    = 'llama-server.exe -m C:\other\models\q.gguf'
          }
        )
      }
    }
    $procs = Get-ServerProcess -InstallDir 'C:\la'
    @($procs).Count | Should -Be 1
    $procs[0].ProcessId | Should -Be 101
    $procs[0].WorkingSetMB | Should -Be 8192
    $procs[0].ExecutablePath | Should -Be 'C:\la\llama\llama-server.exe'
    $procs[0].CommandLine | Should -BeLike '*-m C:\la\models\q.gguf*'
  }

  It 'returns an empty array when the server is not running' {
    InModuleScope Localagent {
      Mock Get-CimInstance { return @() }
    }
    $procs = Get-ServerProcess -InstallDir 'C:\la'
    @($procs).Count | Should -Be 0
  }

  It 'queries Win32_Process for llama-server.exe' {
    InModuleScope Localagent {
      Mock Get-CimInstance { return @() }
    }
    Get-ServerProcess -InstallDir 'C:\la' | Out-Null
    InModuleScope Localagent {
      Should -Invoke Get-CimInstance -Exactly 1 -ParameterFilter {
        $ClassName -eq 'Win32_Process' -and $Filter -like "*llama-server.exe*"
      }
    }
  }
}
