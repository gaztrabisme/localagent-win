# Pester 5 tests for the subagent MCP server helpers in lib/localagent.psm1
# (JSON object key merge, subagent.toml template fill, omp lookup, uv list).
# Run with: Invoke-Pester tests/Subagent.Tests.ps1

BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1') -Force
  $script:Template = Join-Path -Path $PSScriptRoot -ChildPath '..\templates\subagent.toml'
}

Describe 'Set-JsonObjectKey' {
  It 'creates the file when it does not exist' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    $entry = [pscustomobject]@{ type = 'stdio'; command = 'C:\tools\subagent-mcp.exe'; args = @() }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Should -Be 'created'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.servers.'local-subagent'.type | Should -Be 'stdio'
    $parsed.servers.'local-subagent'.command | Should -Be 'C:\tools\subagent-mcp.exe'
    @($parsed.servers.'local-subagent'.args).Count | Should -Be 0
  }

  It 'adds to an existing servers object and keeps the other servers' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '{"servers":{"other":{"type":"stdio","command":"C:\\o\\x.exe"}}}'
    $entry = [pscustomobject]@{ type = 'stdio'; command = 'C:\tools\subagent-mcp.exe'; args = @() }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Should -Be 'added'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.servers.other.command | Should -Be 'C:\o\x.exe'
    $parsed.servers.'local-subagent'.command | Should -Be 'C:\tools\subagent-mcp.exe'
  }

  It 'replaces an existing key and keeps its neighbours' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '{"servers":{"local-subagent":{"type":"stdio","command":"C:\\old\\omp.exe"},"other":{"command":"keep me"}}}'
    $entry = [pscustomobject]@{ type = 'stdio'; command = 'C:\new\subagent-mcp.exe'; args = @() }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Should -Be 'replaced'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.servers.'local-subagent'.command | Should -Be 'C:\new\subagent-mcp.exe'
    $parsed.servers.other.command | Should -Be 'keep me'
  }

  It 'keeps the order of the existing servers' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '{"servers":{"aaa":{"command":"1"},"zzz":{"command":"2"}}}'
    $entry = [pscustomobject]@{ command = 'C:\m.exe' }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Out-Null
    $text = Get-Content -LiteralPath $path -Raw
    ($text.IndexOf('"aaa"') -lt $text.IndexOf('"zzz"')) | Should -BeTrue
    ($text.IndexOf('"aaa"') -lt $text.IndexOf('"local-subagent"')) | Should -BeTrue
  }

  It 'creates the servers object in an existing object without one' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '{"otherTopLevel":true}'
    $entry = [pscustomobject]@{ command = 'C:\m.exe' }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Should -Be 'added'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.otherTopLevel | Should -BeTrue
    $parsed.servers.'local-subagent'.command | Should -Be 'C:\m.exe'
  }

  It 'treats an empty existing file as a new file' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '   '
    $entry = [pscustomobject]@{ command = 'C:\m.exe' }
    Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry | Should -Be 'created'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.servers.'local-subagent'.command | Should -Be 'C:\m.exe'
  }

  It 'throws on a file that is not valid JSON' {
    $path = Join-Path -Path $TestDrive -ChildPath 'broken.json'
    Set-Content -LiteralPath $path -Value '{ not json'
    $entry = [pscustomobject]@{ command = 'C:\m.exe' }
    { Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry } | Should -Throw
  }

  It 'throws when the file root is a JSON array' {
    $path = Join-Path -Path $TestDrive -ChildPath 'array.json'
    Set-Content -LiteralPath $path -Value '[{"servers":{}}]'
    $entry = [pscustomobject]@{ command = 'C:\m.exe' }
    { Set-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' -Value $entry } | Should -Throw
  }
}

Describe 'Remove-JsonObjectKey' {
  It 'removes the key and keeps the other servers' {
    $path = Join-Path -Path $TestDrive -ChildPath 'mcp.json'
    Set-Content -LiteralPath $path -Value '{"servers":{"local-subagent":{"command":"C:\\m.exe"},"other":{"command":"keep me"}}}'
    Remove-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' | Should -Be 'removed'
    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    $parsed.servers.other.command | Should -Be 'keep me'
    $parsed.servers.PSObject.Properties['local-subagent'] | Should -Be $null
  }

  It 'reports absent for a missing file, empty file, missing object or missing key' {
    $missing = Join-Path -Path $TestDrive -ChildPath 'gone.json'
    Remove-JsonObjectKey -Path $missing -ObjectKey 'servers' -Name 'local-subagent' | Should -Be 'absent'

    $empty = Join-Path -Path $TestDrive -ChildPath 'empty.json'
    Set-Content -LiteralPath $empty -Value ''
    Remove-JsonObjectKey -Path $empty -ObjectKey 'servers' -Name 'local-subagent' | Should -Be 'absent'

    $noServers = Join-Path -Path $TestDrive -ChildPath 'noservers.json'
    Set-Content -LiteralPath $noServers -Value '{"otherTopLevel":1}'
    Remove-JsonObjectKey -Path $noServers -ObjectKey 'servers' -Name 'local-subagent' | Should -Be 'absent'

    $noKey = Join-Path -Path $TestDrive -ChildPath 'nokey.json'
    Set-Content -LiteralPath $noKey -Value '{"servers":{"other":{}}}'
    Remove-JsonObjectKey -Path $noKey -ObjectKey 'servers' -Name 'local-subagent' | Should -Be 'absent'
    (Get-Content -LiteralPath $noKey -Raw) | Should -Match 'other'
  }

  It 'throws on a file that is not valid JSON' {
    $path = Join-Path -Path $TestDrive -ChildPath 'broken.json'
    Set-Content -LiteralPath $path -Value 'nope{'
    { Remove-JsonObjectKey -Path $path -ObjectKey 'servers' -Name 'local-subagent' } | Should -Throw
  }
}

Describe 'ConvertTo-SubagentToml' {
  It 'fills both placeholders and leaves none behind' {
    $toml = ConvertTo-SubagentToml -Path $script:Template -OmpBinary 'C:\Users\g\AppData\Local\omp\omp.exe' -Port 8080
    $toml.Contains('{{') | Should -BeFalse
    $toml.Contains("binary = 'C:\Users\g\AppData\Local\omp\omp.exe'") | Should -BeTrue
    # -BeLike reads [...] as a character class, so the TOML array is checked with Contains.
    $toml.Contains('candidates = ["http://127.0.0.1:8080"]') | Should -BeTrue
  }

  It 'defaults the port to the package constant' {
    $toml = ConvertTo-SubagentToml -Path $script:Template -OmpBinary 'C:\omp.exe'
    $toml.Contains(('candidates = ["http://127.0.0.1:{0}"]' -f (Get-LocalAgentConstants).Port)) | Should -BeTrue
  }

  It 'uses the given port for the health candidates' {
    $toml = ConvertTo-SubagentToml -Path $script:Template -OmpBinary 'C:\omp.exe' -Port 8081
    $toml.Contains('candidates = ["http://127.0.0.1:8081"]') | Should -BeTrue
    $toml | Should -Not -BeLike '*8080*'
  }

  It 'keeps every key the subagent config reader expects' {
    $toml = ConvertTo-SubagentToml -Path $script:Template -OmpBinary 'C:\omp.exe'
    $toml | Should -BeLike '*default_provider = "local"*'
    $toml | Should -BeLike '*driver = "omp"*'
    $toml | Should -BeLike '*model = "qwen3.6-35b-a3b"*'
    $toml | Should -BeLike '*local = true*'
    $toml | Should -BeLike '*max_agents = 1*'
    $toml | Should -BeLike '*max_steps = 80*'
    $toml | Should -BeLike '*run_timeout = 3600*'
    $toml | Should -BeLike '*idle_timeout = 900*'
    $toml | Should -BeLike '*kind = "llamacpp"*'
    $toml | Should -BeLike '*warm = true*'
    $toml | Should -BeLike '*cold_load_seconds = 600*'
    $toml | Should -BeLike '*kind = "local"*'
    $toml | Should -BeLike '*usd = 0*'
    $toml | Should -BeLike '*allow_unguarded = true*'
  }

  It 'throws when the template is missing' {
    { ConvertTo-SubagentToml -Path (Join-Path -Path $TestDrive -ChildPath 'nope.toml') -OmpBinary 'C:\omp.exe' } | Should -Throw
  }
}

Describe 'Set-SubagentToml' {
  It 'creates the file and its parent folders' {
    $target = Join-Path -Path $TestDrive -ChildPath 'subagent\config.toml'
    Set-SubagentToml -Path $target -TemplatePath $script:Template -OmpBinary 'C:\omp.exe' -Port 8080 | Should -Be 'created'
    $raw = Get-Content -LiteralPath $target -Raw
    $raw | Should -BeLike '*driver = "omp"*'
    $raw.Contains('{{') | Should -BeFalse
  }

  It 'keeps an existing config that already has a [providers.local] table' {
    $target = Join-Path -Path $TestDrive -ChildPath 'config.toml'
    Set-Content -LiteralPath $target -Value "[providers.local]`ndriver = `"omp`"`n"
    Set-SubagentToml -Path $target -TemplatePath $script:Template -OmpBinary 'C:\omp.exe' | Should -Be 'kept'
    (Get-Content -LiteralPath $target -Raw) | Should -Not -BeLike '*max_steps = 80*'
  }

  It 'replaces an existing config without a [providers.local] table' {
    $target = Join-Path -Path $TestDrive -ChildPath 'config2.toml'
    Set-Content -LiteralPath $target -Value "[core]`ndefault_provider = `"glm`"`n"
    Set-SubagentToml -Path $target -TemplatePath $script:Template -OmpBinary 'C:\omp.exe' | Should -Be 'replaced'
    (Get-Content -LiteralPath $target -Raw).Contains('[providers.local]') | Should -BeTrue
  }
}

Describe 'Test-TomlTablePresent' {
  It 'finds the exact table' {
    Test-TomlTablePresent -Text "[core]`n[providers.local]`ndriver = `"omp`"`n" -Name 'providers.local' | Should -BeTrue
  }

  It 'does not confuse the table with its sub-tables' {
    Test-TomlTablePresent -Text "[providers.local.health]`nkind = `"llamacpp`"`n" -Name 'providers.local' | Should -BeFalse
  }

  It 'tolerates whitespace and trailing comments, and reports absent tables' {
    Test-TomlTablePresent -Text "  [providers.local]   # ours" -Name 'providers.local' | Should -BeTrue
    Test-TomlTablePresent -Text "[providers.glm]`ndriver = `"claude`"" -Name 'providers.local' | Should -BeFalse
    Test-TomlTablePresent -Text '' -Name 'providers.local' | Should -BeFalse
  }
}

Describe 'Get-SubagentBinaryFromToml' {
  It 'reads the binary of the providers.local table' {
    $toml = ConvertTo-SubagentToml -Path $script:Template -OmpBinary 'C:\Users\g\AppData\Local\omp\omp.exe'
    Get-SubagentBinaryFromToml -Text $toml | Should -Be 'C:\Users\g\AppData\Local\omp\omp.exe'
  }

  It 'returns null when there is no binary line or no providers.local table' {
    $noBinary = @'
[providers.local]
model = "x"
'@
    Get-SubagentBinaryFromToml -Text $noBinary | Should -Be $null

    $otherTable = @'
[providers.glm]
binary = "C:\elsewhere\omp.exe"
'@
    Get-SubagentBinaryFromToml -Text $otherTable | Should -Be $null
    Get-SubagentBinaryFromToml -Text '' | Should -Be $null
  }
}

Describe 'Get-OmpBinaryCandidates' {
  It 'lists the known omp install paths under the user profile' {
    $candidates = Get-OmpBinaryCandidates
    $candidates | Should -Contain (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'omp\omp.exe')
    $candidates | Should -Contain (Join-Path -Path $env:USERPROFILE -ChildPath '.omp\bin\omp.exe')
    $candidates | Should -Contain (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin\omp.exe')
  }
}

Describe 'Find-OmpBinary' {
  It 'resolves omp from the candidate list' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'omp-bin'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $exe = Join-Path -Path $dir -ChildPath 'omp.exe'
    Set-Content -LiteralPath $exe -Value 'x'
    Find-OmpBinary -CommandName '' -Candidates @($exe) | Should -Be $exe
  }

  It 'returns the first candidate that exists' {
    $exe = Join-Path -Path $TestDrive -ChildPath 'omp.exe'
    Set-Content -LiteralPath $exe -Value 'x'
    $first = Find-OmpBinary -CommandName '' -Candidates @((Join-Path -Path $TestDrive -ChildPath 'gone.exe'), $exe)
    $first | Should -Be $exe
  }

  It 'returns null when no candidate exists' {
    Find-OmpBinary -CommandName '' -Candidates @((Join-Path -Path $TestDrive -ChildPath 'gone.exe')) | Should -Be $null
  }
}

Describe 'Test-UvToolListText' {
  It 'matches the tool line with and without a version' {
    Test-UvToolListText -Text "subagent v0.1.0`n- subagent`n- subagent-mcp`n" -Name 'subagent' | Should -BeTrue
    Test-UvToolListText -Text 'subagent' -Name 'subagent' | Should -BeTrue
  }

  It 'does not match a different tool whose name starts the same' {
    Test-UvToolListText -Text "subagent-mcp v0.1.0`n- subagent-mcp`n" -Name 'subagent' | Should -BeFalse
  }

  It 'returns false on empty or unrelated output' {
    Test-UvToolListText -Text '' -Name 'subagent' | Should -BeFalse
    Test-UvToolListText -Text "black v24.3.0`n- black`n" -Name 'subagent' | Should -BeFalse
  }
}

Describe 'subagent config round trip (install then uninstall comparison)' {
  It 'compares byte for byte after a line-ending-normalised fill' {
    $target = Join-Path -Path $TestDrive -ChildPath 'roundtrip\config.toml'
    $binary = 'C:\Users\g\AppData\Local\omp\omp.exe'
    Set-SubagentToml -Path $target -TemplatePath $script:Template -OmpBinary $binary -Port 8080 | Should -Be 'created'

    $text = Get-Content -LiteralPath $target -Raw
    $readBack = Get-SubagentBinaryFromToml -Text $text
    $readBack | Should -Be $binary

    $expected = ConvertTo-SubagentToml -Path $script:Template -OmpBinary $readBack -Port 8080
    $actualNorm = ($text -replace "`r?`n", "`n").TrimEnd("`n")
    $expectedNorm = ($expected -replace "`r?`n", "`n").TrimEnd("`n")
    $actualNorm | Should -Be $expectedNorm
  }

  It 'stops matching when the config was edited afterwards' {
    $target = Join-Path -Path $TestDrive -ChildPath 'edited\config.toml'
    Set-SubagentToml -Path $target -TemplatePath $script:Template -OmpBinary 'C:\omp.exe' -Port 8080
    $text = (Get-Content -LiteralPath $target -Raw) -replace 'max_steps = 80', 'max_steps = 40'
    Set-Content -LiteralPath $target -Value $text

    $edited = Get-Content -LiteralPath $target -Raw
    $expected = ConvertTo-SubagentToml -Path $script:Template -OmpBinary (Get-SubagentBinaryFromToml -Text $edited) -Port 8080
    $actualNorm = ($edited -replace "`r?`n", "`n").TrimEnd("`n")
    $expectedNorm = ($expected -replace "`r?`n", "`n").TrimEnd("`n")
    $actualNorm | Should -Not -Be $expectedNorm
  }
}

Describe 'paths and constants for the subagent' {
  It 'exposes the subagent paths' {
    $p = Get-LocalAgentPaths -InstallDir 'C:\la'
    $p.Subagent | Should -Be 'C:\la\subagent'
    $p.McpJson | Should -Be (Join-Path -Path $env:APPDATA -ChildPath 'Code\User\mcp.json')
    $p.SubagentConfig | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.config\subagent\config.toml')
    $p.SubagentMcpExe | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin\subagent-mcp.exe')
    $p.SubagentExe | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin\subagent.exe')
    $p.UvBin | Should -Be (Join-Path -Path $env:USERPROFILE -ChildPath '.local\bin')
  }

  It 'exposes the subagent constants' {
    $c = Get-LocalAgentConstants
    $c.UvZipUrl | Should -Be 'https://github.com/astral-sh/uv/releases/download/0.12.18/uv-x86_64-pc-windows-msvc.zip'
    $c.UvZipSize | Should -Be 17891221
    $c.UvZipSha256 | Should -Be 'cae6a3bc25239f83dffb467a4b180508d9da23986c04639ebfa44e43e6a84bff'
    $c.SubagentPython | Should -Be '3.12'
    $c.SubagentToolName | Should -Be 'subagent'
    $c.SubagentMcpName | Should -Be 'local-subagent'
    $c.SubagentMcpExe | Should -Be 'subagent-mcp.exe'
    $c.SubagentModel | Should -Be 'qwen3.6-35b-a3b'
  }
}
