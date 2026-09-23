# Pester 5 tests for lib/localagent.psm1.
# Run with: Invoke-Pester tests/  (PowerShell 5.1 compatible)

BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1') -Force
}

Describe 'Get-LocalAgentConstants' {
  It 'returns the published hashes, sizes and names' {
    $c = Get-LocalAgentConstants
    $c.LlamaZipUrl     | Should -Be 'https://github.com/ggml-org/llama.cpp/releases/download/b10757/llama-b10757-bin-win-cpu-x64.zip'
    $c.LlamaZipSha256  | Should -Be '35692755857b0fed103b648d792e74ea8022dbe9519a0c1e5bf0b4ce51412bed'
    $c.LlamaZipSize    | Should -Be 18373860
    $c.ModelUrl        | Should -Be 'https://huggingface.co/havenoammo/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf'
    $c.ModelSha256     | Should -Be 'ab94e2da12d2bdc22777ba1b7422bbf8d5d9d0bee1164ca7343a0cee3310038a'
    $c.ModelSize       | Should -Be 23257919904
    $c.ModelFileName   | Should -Be 'Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf'
    $c.OmpRef          | Should -Be 'v18.2.8'
    $c.OmpUrl          | Should -Be 'https://github.com/can1357/oh-my-pi/releases/download/v18.2.8/omp-windows-x64.exe'
    $c.OmpSha256       | Should -Be 'b95431cb63b073c36c3664f6d9e2611de8d28d6e6e21ede657c8f83f0e7034b3'
    $c.OmpSize         | Should -Be 218729472
    $c.Alias           | Should -Be 'qwen3.6-35b-a3b'
    $c.Port            | Should -Be 8080
    $c.TaskName        | Should -Be 'LocalAgent Server'
    $c.VsCodeEntryName | Should -Be 'Local Qwen3.6'
  }
}

Describe 'Get-LocalAgentPaths' {
  It 'derives every package path from InstallDir and the user profile' {
    $p = Get-LocalAgentPaths -InstallDir 'C:\la'
    $p.InstallDir     | Should -Be 'C:\la'
    $p.Llama          | Should -Be 'C:\la\llama'
    $p.Models         | Should -Be 'C:\la\models'
    $p.ModelFile      | Should -Be ('C:\la\models\' + (Get-LocalAgentConstants).ModelFileName)
    $p.Config         | Should -Be 'C:\la\config.json'
    $p.Bin            | Should -Be 'C:\la\bin'
    $p.Logs           | Should -Be 'C:\la\logs'
    $p.ServerLog      | Should -Be 'C:\la\logs\server.log'
    $p.BenchJson      | Should -Be 'C:\la\bench.json'
    $p.OmpAgentDir    | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.omp\agent')
    $p.OmpModelsYml   | Should -Be (Join-Path -Path $p.OmpAgentDir -ChildPath 'models.yml')
    $p.OmpConfigYml   | Should -Be (Join-Path -Path $p.OmpAgentDir -ChildPath 'config.yml')
    $p.VsCodeUserDir  | Should -Be (Join-Path -Path $env:APPDATA -ChildPath 'Code\User')
    $p.ChatModelsJson | Should -Be (Join-Path -Path $p.VsCodeUserDir -ChildPath 'chatLanguageModels.json')
    $p.ContinueConfig | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.continue\config.yaml')
  }

  It 'defaults InstallDir to LOCALAPPDATA\localagent' {
    (Get-LocalAgentPaths).InstallDir | Should -Be (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'localagent')
  }
}

Describe 'New-LocalAgentConfig' {
  It 'builds the default config (spec step 4) for 64 physical cores' {
    $cfg = New-LocalAgentConfig -PhysicalCores 64
    $cfg.port          | Should -Be 8080
    $cfg.host          | Should -Be '127.0.0.1'
    $cfg.threads       | Should -Be 16
    $cfg.threads_batch | Should -Be 64
    $cfg.ctx           | Should -Be 131072
    $cfg.parallel      | Should -Be 1
    $cfg.mtp           | Should -BeTrue
    $cfg.mtp_draft_max | Should -Be 3
    $cfg.alias         | Should -Be 'qwen3.6-35b-a3b'
    $cfg.n_predict     | Should -Be 16384
    $cfg.sampling.temp             | Should -Be 0.6
    $cfg.sampling.top_p            | Should -Be 0.95
    $cfg.sampling.top_k            | Should -Be 20
    $cfg.sampling.min_p            | Should -Be 0
    $cfg.sampling.presence_penalty | Should -Be 0
    @($cfg.extra_args)             | Should -HaveCount 0
  }

  It 'honours -Threads' {
    (New-LocalAgentConfig -PhysicalCores 32 -Threads 8).threads | Should -Be 8
  }
}

Describe 'ConvertTo-ServerArgs' {
  It 'builds the exact default argv including MTP flags' {
    $cfg = New-LocalAgentConfig -PhysicalCores 64
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf'
    $expected = @(
      '-m', 'C:\m\model.gguf',
      '--host', '127.0.0.1', '--port', '8080',
      '-t', '16', '-tb', '64',
      '-c', '131072', '-np', '1',
      '--jinja', '-fa', 'on', '--cache-reuse', '256', '-ctk', 'q8_0', '-ctv', 'q8_0',
      '--temp', '0.6', '--top-p', '0.95', '--top-k', '20', '--min-p', '0', '--presence-penalty', '0',
      '-n', '16384', '--alias', 'qwen3.6-35b-a3b',
      '--spec-type', 'draft-mtp', '--spec-draft-n-max', '3'
    )
    $argv | Should -Be $expected
  }

  It 'omits the MTP flags when mtp is false' {
    $cfg = New-LocalAgentConfig -PhysicalCores 64
    $cfg.mtp = $false
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf'
    $argv -contains '--spec-type' | Should -BeFalse
    $argv -contains '--spec-draft-n-max' | Should -BeFalse
    $argv | Should -Not -Be $null
  }

  It 'appends extra_args after the built-in flags' {
    $cfg = New-LocalAgentConfig -PhysicalCores 16
    $cfg.extra_args = @('--no-warmup', '--threads-http', '4')
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf'
    $argv | Should -Not -Be $null
    ($argv -join ' ') | Should -BeLike '*--alias qwen3.6-35b-a3b --spec-type draft-mtp --spec-draft-n-max 3 --no-warmup --threads-http 4'
    $argv[-1] | Should -Be '4'
  }

  It 'adds --log-file, --log-timestamps and --log-colors off before extra_args with -LogFile' {
    $cfg = New-LocalAgentConfig -PhysicalCores 16
    $cfg.extra_args = @('--no-warmup')
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf' -LogFile 'C:\la\logs\server.log'
    ($argv -join ' ') | Should -BeLike '*--spec-draft-n-max 3 --log-file C:\la\logs\server.log --log-timestamps --log-colors off --no-warmup'
    $plain = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf'
    $plain -contains '--log-file' | Should -BeFalse
  }

  It 'uses config.model instead of ModelPath when it is set' {
    $cfg = New-LocalAgentConfig -PhysicalCores 16
    $cfg | Add-Member -NotePropertyName model -NotePropertyValue 'D:\other\x.gguf'
    $argv = ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf'
    $argv[1] | Should -Be 'D:\other\x.gguf'
    $cfg.model = ''
    (ConvertTo-ServerArgs -Config $cfg -ModelPath 'C:\m\model.gguf')[1] | Should -Be 'C:\m\model.gguf'
  }

  It 'reads a JSON round-tripped config without crashing on an empty extra_args' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rt-extra.json'
    Write-LocalAgentConfig -Config (New-LocalAgentConfig -PhysicalCores 8) -Path $path
    $rt = Read-LocalAgentConfig -Path $path
    { ConvertTo-ServerArgs -Config $rt -ModelPath 'C:\m\model.gguf' } | Should -Not -Throw
  }
}

Describe 'Read-LocalAgentConfig / Write-LocalAgentConfig' {
  It 'round-trips every field' {
    $path = Join-Path -Path $TestDrive -ChildPath 'roundtrip.json'
    $cfg = New-LocalAgentConfig -PhysicalCores 8 -Threads 4
    $cfg.extra_args = @('--no-mmap')

    Write-LocalAgentConfig -Config $cfg -Path $path
    $rt = Read-LocalAgentConfig -Path $path

    $rt.port          | Should -Be 8080
    $rt.host          | Should -Be '127.0.0.1'
    $rt.threads       | Should -Be 4
    $rt.threads_batch | Should -Be 8
    $rt.ctx           | Should -Be 131072
    $rt.parallel      | Should -Be 1
    $rt.mtp           | Should -BeTrue
    $rt.mtp_draft_max | Should -Be 3
    $rt.alias         | Should -Be 'qwen3.6-35b-a3b'
    $rt.n_predict     | Should -Be 16384
    $rt.sampling.temp             | Should -Be 0.6
    $rt.sampling.top_p            | Should -Be 0.95
    $rt.sampling.top_k            | Should -Be 20
    $rt.sampling.min_p            | Should -Be 0
    $rt.sampling.presence_penalty | Should -Be 0
    @($rt.extra_args) | Should -HaveCount 1
    $rt.extra_args[0] | Should -Be '--no-mmap'
  }

  It 'throws on a missing or empty config' {
    { Read-LocalAgentConfig -Path (Join-Path -Path $TestDrive -ChildPath 'nope.json') } | Should -Throw
    $empty = Join-Path -Path $TestDrive -ChildPath 'empty.json'
    Set-Content -Path $empty -Value ''
    { Read-LocalAgentConfig -Path $empty } | Should -Throw
  }
}

Describe 'Get-SystemInfoFlags / Test-Avx2' {
  It 'parses a real-looking system_info line' {
    $line = 'system_info: n_threads = 16 / 64 | AVX = 1 | AVX_VNNI = 0 | AVX2 = 1 | AVX512 = 0 | ' +
            'AVX512_VBMI = 0 | AVX512_BF16 = 0 | FMA = 1 | NEON = 0 | ARM = 0 | SSE3 = 1 | ' +
            'SSSE3 = 1 | VSX = 0 | CUDA = 0 | ROCM = 0 | REPACK = 0 | memory size = 32727.94 MiB'
    $flags = Get-SystemInfoFlags -Text $line
    $flags['AVX2']       | Should -Be '1'
    $flags['AVX512']     | Should -Be '0'
    $flags['AVX_VNNI']   | Should -Be '0'
    $flags['AVX512_BF16']| Should -Be '0'
    $flags['FMA']        | Should -Be '1'
    $flags['CUDA']       | Should -Be '0'
    $flags['ROCM']       | Should -Be '0'
  }

  It 'detects AVX2 present and absent' {
    $on = Get-SystemInfoFlags -Text 'system_info: | AVX = 1 | AVX2 = 1 | AVX512 = 0 |'
    $off = Get-SystemInfoFlags -Text 'system_info: | AVX = 1 | AVX2 = 0 | AVX512 = 0 |'
    Test-Avx2 -Flags $on | Should -BeTrue
    Test-Avx2 -Flags $off | Should -BeFalse
  }

  It 'returns false when AVX2 is not reported at all' {
    $bare = Get-SystemInfoFlags -Text 'system_info: n_threads = 4 | FMA = 1 |'
    Test-Avx2 -Flags $bare | Should -BeFalse
  }
}

Describe 'Merge-JsonArrayEntry' {
  It 'creates the file when missing' {
    $path = Join-Path -Path $TestDrive -ChildPath 'chatLanguageModels.json'
    $entry = [pscustomobject]@{ name = 'Local Qwen3.6'; vendor = 'customendpoint' }
    Merge-JsonArrayEntry -Path $path -Entry $entry | Should -Be 'created'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -Path $path -Raw)
    @($parsed) | Should -HaveCount 1
    $parsed[0].name | Should -Be 'Local Qwen3.6'
  }

  It 'replaces the entry with the same name and keeps the others' {
    $path = Join-Path -Path $TestDrive -ChildPath 'merge.json'
    Merge-JsonArrayEntry -Path $path -Entry ([pscustomobject]@{ name = 'Other'; vendor = 'x' }) | Should -Be 'created'
    Merge-JsonArrayEntry -Path $path -Entry ([pscustomobject]@{ name = 'Local Qwen3.6'; vendor = 'customendpoint' }) | Should -Be 'appended'
    $replacement = [pscustomobject]@{ name = 'Local Qwen3.6'; vendor = 'customendpoint'; apiType = 'chat-completions' }
    Merge-JsonArrayEntry -Path $path -Entry $replacement | Should -Be 'replaced'

    $parsed = ConvertFrom-Json -InputObject (Get-Content -Path $path -Raw)
    @($parsed) | Should -HaveCount 2
    ($parsed | Where-Object { $_.name -eq 'Local Qwen3.6' }).apiType | Should -Be 'chat-completions'
    ($parsed | Where-Object { $_.name -eq 'Other' }).vendor | Should -Be 'x'
  }

  It 'appends when no entry matches' {
    $path = Join-Path -Path $TestDrive -ChildPath 'append.json'
    Set-Content -Path $path -Value '[{"name":"Other"}]'
    Merge-JsonArrayEntry -Path $path -Entry ([pscustomobject]@{ name = 'Local Qwen3.6' }) | Should -Be 'appended'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -Path $path -Raw)
    @($parsed) | Should -HaveCount 2
  }
}

Describe 'Remove-JsonArrayEntry' {
  It 'removes only our entry and reports absence cleanly' {
    $path = Join-Path -Path $TestDrive -ChildPath 'remove.json'
    Merge-JsonArrayEntry -Path $path -Entry ([pscustomobject]@{ name = 'Local Qwen3.6'; vendor = 'customendpoint' }) | Out-Null
    Merge-JsonArrayEntry -Path $path -Entry ([pscustomobject]@{ name = 'Other'; vendor = 'x' }) | Out-Null

    Remove-JsonArrayEntry -Path $path -Name 'Local Qwen3.6' | Should -Be 'removed'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -Path $path -Raw)
    @($parsed) | Should -HaveCount 1
    $parsed[0].name | Should -Be 'Other'

    Remove-JsonArrayEntry -Path $path -Name 'Local Qwen3.6' | Should -Be 'absent'
    Remove-JsonArrayEntry -Path (Join-Path -Path $TestDrive -ChildPath 'nope.json') -Name 'x' | Should -Be 'absent'
  }
}

Describe 'Set-ManagedBlock' {
  BeforeAll {
    $begin = '# >>> localagent'
    $end = '# <<< localagent'
    $blockV1 = @('providers:', '  local:', '    baseUrl: http://127.0.0.1:8080/v1')
    $blockV2 = @('providers:', '  local:', '    baseUrl: http://127.0.0.1:9999/v1')
  }

  It 'creates the file when it does not exist' {
    $path = Join-Path -Path $TestDrive -ChildPath 'new.yml'
    Set-ManagedBlock -Path $path -Begin $begin -End $end -Content $blockV1 | Should -Be 'created'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be $begin
    $lines[1] | Should -Be 'providers:'
    $lines[-1] | Should -Be $end
  }

  It 'appends the block to a file without one' {
    $path = Join-Path -Path $TestDrive -ChildPath 'no-block.yml'
    Set-Content -Path $path -Value @('# my omp notes', 'other: value')
    Set-ManagedBlock -Path $path -Begin $begin -End $end -Content $blockV1 | Should -Be 'appended'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be '# my omp notes'
    $lines[1] | Should -Be 'other: value'
    $lines[2] | Should -Be ''
    $lines[3] | Should -Be $begin
    $lines[-1] | Should -Be $end
  }

  It 'replaces an existing managed block in place, keeping the rest' {
    $path = Join-Path -Path $TestDrive -ChildPath 'with-block.yml'
    Set-Content -Path $path -Value @('# header', $begin, 'stale: yes', $end, 'tail: kept')
    Set-ManagedBlock -Path $path -Begin $begin -End $end -Content $blockV2 | Should -Be 'replaced'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be '# header'
    $lines[1] | Should -Be $begin
    $lines[2] | Should -Be 'providers:'
    $lines[4] | Should -Be '    baseUrl: http://127.0.0.1:9999/v1'
    $lines[5] | Should -Be $end
    $lines[6] | Should -Be 'tail: kept'
    ($lines -contains 'stale: yes') | Should -BeFalse
    ($lines -contains $begin) | Should -BeTrue
    @($lines | Where-Object { $_ -eq $begin }).Count | Should -Be 1
  }

  It 'skips a file with a foreign providers map and no managed block' {
    $path = Join-Path -Path $TestDrive -ChildPath 'foreign.yml'
    Set-Content -Path $path -Value @('providers:', '  other:', '    baseUrl: http://example.invalid/v1')
    Set-ManagedBlock -Path $path -Begin $begin -End $end -Content $blockV1 -ConflictPattern '^\s*providers:\s*$' | Should -Be 'skipped'
    $lines = @(Get-Content -Path $path)
    $lines.Count | Should -Be 3
    ($lines -contains $begin) | Should -BeFalse
  }
}

Describe 'Remove-ManagedBlock' {
  It 'removes the block and the surrounding blank lines, keeping the rest' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rm-block.yml'
    Set-Content -Path $path -Value @('# header', '', '# >>> localagent', 'providers:', '# <<< localagent', '', 'tail: kept')
    Remove-ManagedBlock -Path $path -Begin '# >>> localagent' -End '# <<< localagent' | Should -Be 'removed'
    $lines = @(Get-Content -Path $path)
    $lines | Should -Be @('# header', 'tail: kept')
  }

  It 'reports absent when there is no block or no file' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rm-none.yml'
    Set-Content -Path $path -Value 'providers:'
    Remove-ManagedBlock -Path $path -Begin '# >>> localagent' -End '# <<< localagent' | Should -Be 'absent'
    Remove-ManagedBlock -Path (Join-Path -Path $TestDrive -ChildPath 'rm-gone.yml') -Begin '# >>> x' -End '# <<< x' | Should -Be 'absent'
  }
}

Describe 'Set-YamlTopLevelMap' {
  It 'creates the file when missing' {
    $path = Join-Path -Path $TestDrive -ChildPath 'config-created.yml'
    $result = Set-YamlTopLevelMap -Path $path -Key 'modelRoles' -Values ([ordered]@{ default = 'local/qwen3.6-35b-a3b' })
    $result | Should -Be 'created'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be 'modelRoles:'
    $lines[1] | Should -Be '  default: local/qwen3.6-35b-a3b'
  }

  It 'replaces an existing block up to the next top-level key and keeps the rest of the file' {
    $path = Join-Path -Path $TestDrive -ChildPath 'config-replace.yml'
    Set-Content -Path $path -Value @(
      '# omp agent config',
      'theme: dark',
      'modelRoles:',
      '  default: other/model',
      '  smol: other/smol',
      'notifications: true'
    )
    $values = [ordered]@{
      default = 'local/qwen3.6-35b-a3b'
      smol    = 'local/qwen3.6-35b-a3b'
      slow    = 'local/qwen3.6-35b-a3b'
      plan    = 'local/qwen3.6-35b-a3b'
    }
    Set-YamlTopLevelMap -Path $path -Key 'modelRoles' -Values $values | Should -Be 'replaced'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be '# omp agent config'
    $lines[1] | Should -Be 'theme: dark'
    $lines[2] | Should -Be 'modelRoles:'
    $lines[3] | Should -Be '  default: local/qwen3.6-35b-a3b'
    $lines[6] | Should -Be '  plan: local/qwen3.6-35b-a3b'
    $lines[7] | Should -Be 'notifications: true'
    $lines.Count | Should -Be 8
  }

  It 'appends the block to a file without the key' {
    $path = Join-Path -Path $TestDrive -ChildPath 'config-append.yml'
    Set-Content -Path $path -Value @('theme: dark', 'notifications: true')
    $values = @{ default = 'local/qwen3.6-35b-a3b' }
    Set-YamlTopLevelMap -Path $path -Key 'modelRoles' -Values $values | Should -Be 'appended'
    $lines = @(Get-Content -Path $path)
    $lines[0] | Should -Be 'theme: dark'
    $lines[1] | Should -Be 'notifications: true'
    $lines[2] | Should -Be ''
    $lines[3] | Should -Be 'modelRoles:'
    ($lines -contains '  default: local/qwen3.6-35b-a3b') | Should -BeTrue
  }
}

Describe 'Remove-YamlTopLevelMapKeys' {
  It 'removes only the named keys, keeping foreign ones' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rm-keys.yml'
    Set-Content -Path $path -Value @(
      'modelRoles:',
      '  default: local/qwen3.6-35b-a3b',
      '  smol: local/qwen3.6-35b-a3b',
      '  custom: user/kept',
      'theme: dark'
    )
    Remove-YamlTopLevelMapKeys -Path $path -Key 'modelRoles' -Keys @('default', 'smol') | Should -Be 'removed'
    $lines = @(Get-Content -Path $path)
    $lines | Should -Be @('modelRoles:', '  custom: user/kept', 'theme: dark')
  }

  It 'drops the whole block when the last key goes away' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rm-keys-all.yml'
    Set-Content -Path $path -Value @('theme: dark', '', 'modelRoles:', '  default: local/qwen3.6-35b-a3b')
    Remove-YamlTopLevelMapKeys -Path $path -Key 'modelRoles' -Keys @('default') | Should -Be 'removed'
    @(Get-Content -Path $path) | Should -Be @('theme: dark')
  }

  It 'reports absent when the key or file is missing' {
    $path = Join-Path -Path $TestDrive -ChildPath 'rm-keys-none.yml'
    Set-Content -Path $path -Value 'theme: dark'
    Remove-YamlTopLevelMapKeys -Path $path -Key 'modelRoles' -Keys @('default') | Should -Be 'absent'
    Remove-YamlTopLevelMapKeys -Path (Join-Path -Path $TestDrive -ChildPath 'gone.yml') -Key 'modelRoles' -Keys @('default') | Should -Be 'absent'
  }
}

Describe 'Set-YamlScalar / Remove-YamlScalar' {
  It 'creates a missing file holding just the line' {
    $path = Join-Path -Path $TestDrive -ChildPath 'scalar-new.yml'
    Set-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'created'
    @(Get-Content -Path $path) | Should -Be @('setupVersion: 2')
  }

  It 'replaces an existing top-level line and keeps every other line' {
    $path = Join-Path -Path $TestDrive -ChildPath 'scalar-replace.yml'
    Set-Content -Path $path -Value @('theme: dark', 'setupVersion: 1', 'modelRoles:', '  default: x/y', '  setupVersion: 9')
    Set-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'replaced'
    @(Get-Content -Path $path) | Should -Be @('theme: dark', 'setupVersion: 2', 'modelRoles:', '  default: x/y', '  setupVersion: 9')
    Set-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'present'
  }

  It 'appends after a blank line when the key is absent (nested keys do not count)' {
    $path = Join-Path -Path $TestDrive -ChildPath 'scalar-append.yml'
    Set-Content -Path $path -Value @('modelRoles:', '  setupVersion: 1', '')
    Set-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'appended'
    @(Get-Content -Path $path) | Should -Be @('modelRoles:', '  setupVersion: 1', '', 'setupVersion: 2')
  }

  It 'removes the line only when it holds the given value' {
    $path = Join-Path -Path $TestDrive -ChildPath 'scalar-remove.yml'
    Set-Content -Path $path -Value @('theme: dark', 'setupVersion: 3')
    Remove-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'absent'
    Set-Content -Path $path -Value @('theme: dark', 'setupVersion: 2')
    Remove-YamlScalar -Path $path -Key 'setupVersion' -Value '2' | Should -Be 'removed'
    @(Get-Content -Path $path) | Should -Be @('theme: dark')
  }
}

Describe 'Get-OmpModelRoles / Get-VsCodeModelEntry' {
  It 'points every model role at the provider-qualified llama.cpp model id' {
    $roles = Get-OmpModelRoles -ModelId 'llama.cpp/qwen3.6-35b-a3b'
    $roles['default'] | Should -Be 'llama.cpp/qwen3.6-35b-a3b'
    $roles['smol']    | Should -Be 'llama.cpp/qwen3.6-35b-a3b'
    $roles['slow']    | Should -Be 'llama.cpp/qwen3.6-35b-a3b'
    $roles['plan']    | Should -Be 'llama.cpp/qwen3.6-35b-a3b'
    @($roles.Keys) | Should -HaveCount 4
  }

  It 'falls back to the shipped alias with the llama.cpp provider prefix' {
    $roles = Get-OmpModelRoles -ModelId ''
    $roles['default'] | Should -Be ('llama.cpp/{0}' -f (Get-LocalAgentConstants).Alias)
  }

  It 'returns the exact spec step 8 VS Code entry' {
    $entry = Get-VsCodeModelEntry
    $entry.name | Should -Be 'Local Qwen3.6'
    $entry.vendor | Should -Be 'customendpoint'
    $entry.apiType | Should -Be 'chat-completions'
    @($entry.models).Count | Should -Be 1
    $entry.models[0].id | Should -Be 'qwen3.6-35b-a3b'
    $entry.models[0].name | Should -Be 'Local Qwen3.6 35B-A3B'
    $entry.models[0].url | Should -Be 'http://127.0.0.1:8080/v1/chat/completions'
    $entry.models[0].toolCalling | Should -BeTrue
    $entry.models[0].vision | Should -BeFalse
    $entry.models[0].maxInputTokens | Should -Be 120000
    $entry.models[0].maxOutputTokens | Should -Be 16384
  }
}

Describe 'Test-Preflight' {
  BeforeAll {
    $goodFacts = [pscustomobject]@{
      Is64Bit       = $true
      OsVersion     = '10.0.26100'
      TotalRamGB    = 31.8
      FreeDiskGB    = 512.3
      PhysicalCores = 64
      HasCurl       = $true
      HasWinget     = $false
      HasCode       = $true
      HasVcRuntime  = $false
    }
  }

  It 'passes on a spec machine (mocked Get-SystemFacts)' {
    InModuleScope Localagent {
      Mock Get-SystemFacts {
        return [pscustomobject]@{
          Is64Bit       = $true
          OsVersion     = '10.0.26100'
          TotalRamGB    = 31.8
          FreeDiskGB    = 512.3
          PhysicalCores = 64
          HasCurl       = $true
          HasWinget     = $false
          HasCode       = $true
        }
      }
    }
    $pf = Test-Preflight
    $pf.Ok | Should -BeTrue
    @($pf.Problems).Count | Should -Be 0
    $pf.Is64Bit | Should -BeTrue
    $pf.TotalRamGB | Should -Be 31.8
    $pf.FreeDiskGB | Should -Be 512.3
    $pf.PhysicalCores | Should -Be 64
    $pf.HasCurl | Should -BeTrue
    $pf.HasWinget | Should -BeFalse
    $pf.HasCode | Should -BeTrue
    $pf.OsVersion | Should -Be '10.0.26100'
  }

  It 'collects one problem per failed minimum' {
    $badFacts = [pscustomobject]@{
      Is64Bit       = $false
      OsVersion     = '6.3.9600'
      TotalRamGB    = 15.9
      FreeDiskGB    = 12.1
      PhysicalCores = 4
      HasCurl       = $false
      HasWinget     = $false
      HasCode       = $false
    }
    InModuleScope Localagent {
      Mock Get-SystemFacts {
        return [pscustomobject]@{
          Is64Bit       = $false
          OsVersion     = '6.3.9600'
          TotalRamGB    = 15.9
          FreeDiskGB    = 12.1
          PhysicalCores = 4
          HasCurl       = $false
          HasWinget     = $false
          HasCode       = $false
        }
      }
    }
    $pf = Test-Preflight
    $pf.Ok | Should -BeFalse
    @($pf.Problems).Count | Should -Be 4
  }

  It 'respects the MinRamGB / MinDiskGB thresholds' {
    $pf = Test-Preflight -MinRamGB 24 -MinDiskGB 20 -Facts $goodFacts
    $pf.Ok | Should -BeTrue
    $tight = Test-Preflight -MinRamGB 40 -MinDiskGB 600 -Facts $goodFacts
    $tight.Ok | Should -BeFalse
    @($tight.Problems).Count | Should -Be 2
  }

  It 'accepts an injected facts object and reports tool presence without requiring it' {
    $pf = Test-Preflight -Facts $goodFacts
    $pf.Ok | Should -BeTrue
    $pf.HasWinget | Should -BeFalse
  }

  It 'reports HasVcRuntime from the facts without requiring it' {
    $pf = Test-Preflight -Facts $goodFacts
    $pf.Ok | Should -BeTrue
    $pf.HasVcRuntime | Should -BeFalse
    $withRuntime = [pscustomobject]@{
      Is64Bit = $true; OsVersion = '10.0.26100'; TotalRamGB = 31.8; FreeDiskGB = 512.3
      PhysicalCores = 64; HasCurl = $true; HasWinget = $false; HasCode = $true; HasVcRuntime = $true
    }
    (Test-Preflight -Facts $withRuntime).HasVcRuntime | Should -BeTrue
  }

  It 'reports HasPython and HasGit from the facts, missing means false' {
    $withTools = [pscustomobject]@{
      Is64Bit = $true; OsVersion = '10.0.26100'; TotalRamGB = 31.8; FreeDiskGB = 512.3
      PhysicalCores = 64; HasCurl = $true; HasWinget = $true; HasCode = $true; HasVcRuntime = $true
      HasPython = $true; HasGit = $false
    }
    $pf = Test-Preflight -Facts $withTools
    $pf.Ok | Should -BeTrue
    $pf.HasPython | Should -BeTrue
    $pf.HasGit | Should -BeFalse
    $legacy = Test-Preflight -Facts $goodFacts
    $legacy.HasPython | Should -BeFalse
    $legacy.HasGit | Should -BeFalse
  }

  It 'treats a facts object without HasVcRuntime as runtime missing' {
    $legacy = [pscustomobject]@{
      Is64Bit = $true; OsVersion = '10.0.26100'; TotalRamGB = 31.8; FreeDiskGB = 512.3
      PhysicalCores = 64; HasCurl = $true; HasWinget = $false; HasCode = $true
    }
    $pf = Test-Preflight -Facts $legacy
    $pf.Ok | Should -BeTrue
    $pf.HasVcRuntime | Should -BeFalse
  }
}

Describe 'Templates' {
  It 'ships a valid templates/config.json matching the module default (threads_batch placeholder 0)' {
    $cfg = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\templates\config.json') -Raw | ConvertFrom-Json
    $cfg.port | Should -Be 8080
    $cfg.host | Should -Be '127.0.0.1'
    $cfg.threads_batch | Should -Be 0
    $cfg.mtp | Should -BeTrue
    $cfg.alias | Should -Be 'qwen3.6-35b-a3b'
    @($cfg.extra_args).Count | Should -Be 0
  }

  It 'ships templates/chatLanguageModels.json parseable as our single VS Code entry' {
    $parsed = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\templates\chatLanguageModels.json') -Raw | ConvertFrom-Json
    @($parsed) | Should -HaveCount 1
    @($parsed)[0].name | Should -Be (Get-VsCodeModelEntry).name
  }

  It 'ships templates/task.xml with the required placeholders and settings' {
    $xml = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\templates\task.xml') -Raw
    $xml | Should -BeLike '*{{USER}}*'
    $xml | Should -BeLike '*{{INSTALLDIR}}*'
    $xml | Should -BeLike '*<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>*'
    $xml | Should -BeLike '*<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>*'
    $xml | Should -BeLike '*<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>*'
    $xml | Should -BeLike '*<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>*'
    $xml | Should -BeLike '*<LogonTrigger>*'
    $xml | Should -BeLike '*<Hidden>true</Hidden>*'
    $xml | Should -BeLike '*<Interval>PT1M</Interval>*'
    $xml | Should -BeLike '*<Count>3</Count>*'
    $xml | Should -BeLike '*{{ARGS}}*'
    $xml | Should -BeLike '*<Command>%SystemRoot%\System32\cmd.exe</Command>*'
    $xml | Should -Not -BeLike '*powershell*'
  }
}
