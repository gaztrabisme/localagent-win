# Pester 5 tests for the install-oriented helpers in lib/localagent.psm1
# (task XML fill, llama binary discovery, smoke-response parsing).
# Run with: Invoke-Pester tests/Install.Tests.ps1

BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1') -Force
}

Describe 'ConvertTo-TaskXml' {
  BeforeAll {
    $script:template = Join-Path -Path $PSScriptRoot -ChildPath '..\templates\task.xml'
  }

  It 'fills all placeholders and leaves none behind' {
    $xml = ConvertTo-TaskXml -Path $script:template -User 'DESKTOP-ABC\gary' -InstallDir 'C:\Users\gary\AppData\Local\localagent' -Arguments '-m x'
    $xml.Contains('{{') | Should -BeFalse
  }

  It 'runs cmd.exe with the given arguments in the llama working directory' {
    $xml = ConvertTo-TaskXml -Path $script:template -User 'DESKTOP-ABC\gary' -InstallDir 'C:\la\' -Arguments '/c start &quot;LocalAgent Server&quot; /min &quot;C:\la\llama\llama-server.exe&quot; --port 8080'
    $xml | Should -BeLike '*<UserId>DESKTOP-ABC\gary</UserId>*'
    $xml | Should -BeLike '*<Command>%SystemRoot%\System32\cmd.exe</Command>*'
    $xml | Should -BeLike '*<Arguments>/c start &quot;LocalAgent Server&quot; /min &quot;C:\la\llama\llama-server.exe&quot; --port 8080</Arguments>*'
    $xml | Should -BeLike '*<WorkingDirectory>C:\la\llama</WorkingDirectory>*'
    $xml | Should -Not -BeLike '*powershell*'
    $xml | Should -Not -BeLike '*WindowStyle*'
    $xml | Should -Not -BeLike '*ExecutionPolicy*'
  }

  It 'XML-escapes the user and install dir' {
    $xml = ConvertTo-TaskXml -Path $script:template -User 'PC\a&b' -InstallDir 'C:\R&D' -Arguments ''
    $xml | Should -BeLike '*<UserId>PC\a&amp;b</UserId>*'
    $xml | Should -BeLike '*<WorkingDirectory>C:\R&amp;D\llama</WorkingDirectory>*'
    ([xml]$xml).Task.Actions.Exec.WorkingDirectory | Should -Be 'C:\R&D\llama'
  }

  It 'keeps the required task settings from the template' {
    $xml = ConvertTo-TaskXml -Path $script:template -User 'u' -InstallDir 'C:\la' -Arguments ''
    $xml | Should -BeLike '*<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>*'
    $xml | Should -BeLike '*<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>*'
    $xml | Should -BeLike '*<LogonTrigger>*'
  }

  It 'throws when the template is missing' {
    { ConvertTo-TaskXml -Path (Join-Path -Path $TestDrive -ChildPath 'nope.xml') -User 'u' -InstallDir 'C:\la' -Arguments '' } | Should -Throw
  }
}

Describe 'ConvertTo-TaskArguments' {
  It 'leaves plain arguments unquoted' {
    ConvertTo-TaskArguments -Argv @('-m', 'C:\m\model.gguf', '--port', '8080') -Raw | Should -Be '-m C:\m\model.gguf --port 8080'
  }

  It 'quotes arguments with spaces and empty arguments' {
    ConvertTo-TaskArguments -Argv @('-m', 'C:\Users\Jane Doe\m.gguf', '') -Raw | Should -Be '-m "C:\Users\Jane Doe\m.gguf" ""'
  }

  It 'escapes embedded quotes and doubles backslashes before a quote or the closing quote' {
    ConvertTo-TaskArguments -Argv @('say "hi"') -Raw | Should -Be '"say \"hi\""'
    ConvertTo-TaskArguments -Argv @('C:\dir with space\') -Raw | Should -Be '"C:\dir with space\\"'
    ConvertTo-TaskArguments -Argv @('a\"b') -Raw | Should -Be '"a\\\"b"'
  }

  It 'XML-escapes the joined line by default' {
    ConvertTo-TaskArguments -Argv @('-m', 'C:\R&D dir\m.gguf', '<x>') | Should -Be '-m &quot;C:\R&amp;D dir\m.gguf&quot; &lt;x&gt;'
  }

  It 'round-trips through the task XML' {
    $template = Join-Path -Path $PSScriptRoot -ChildPath '..\templates\task.xml'
    $argv = @('-m', 'C:\R&D dir\m.gguf', '--alias', 'q')
    $xml = ConvertTo-TaskXml -Path $template -User 'u' -InstallDir 'C:\la' -Arguments (ConvertTo-TaskArguments -Argv $argv)
    ([xml]$xml).Task.Actions.Exec.Arguments | Should -Be (ConvertTo-TaskArguments -Argv $argv -Raw)
  }
}

Describe 'Get-TaskActionArguments' {
  It 'starts llama-server minimized with the window title as the first quoted token' {
    $line = Get-TaskActionArguments -ServerExe 'C:\Users\Jane Doe\la\llama\llama-server.exe' -Argv @('-m', 'C:\m.gguf', '--port', '8080')
    $line | Should -Be '/c start "LocalAgent Server" /min "C:\Users\Jane Doe\la\llama\llama-server.exe" -m C:\m.gguf --port 8080'
  }

  It 'XML-escapes with -Xml and round-trips through the task XML' {
    $template = Join-Path -Path $PSScriptRoot -ChildPath '..\templates\task.xml'
    $argv = @('-m', 'C:\R&D dir\m.gguf')
    $escaped = Get-TaskActionArguments -ServerExe 'C:\la\llama\llama-server.exe' -Argv $argv -Xml
    $escaped | Should -BeLike '/c start &quot;LocalAgent Server&quot; /min*&amp;*'
    $xml = ConvertTo-TaskXml -Path $template -User 'u' -InstallDir 'C:\la' -Arguments $escaped
    ([xml]$xml).Task.Actions.Exec.Arguments | Should -Be (Get-TaskActionArguments -ServerExe 'C:\la\llama\llama-server.exe' -Argv $argv)
  }
}

Describe 'Invoke-LogRotation' {
  It 'does nothing below the limit or without a file' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'rot-small'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $log = Join-Path -Path $dir -ChildPath 'server.log'
    Invoke-LogRotation -Path $log -MaxBytes 10 | Should -BeFalse
    Set-Content -Path $log -Value 'abc' -NoNewline
    Invoke-LogRotation -Path $log -MaxBytes 10 | Should -BeFalse
    Test-Path $log | Should -BeTrue
  }

  It 'shifts server.log to server.1.log and keeps at most Keep copies' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'rot-big'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $log = Join-Path -Path $dir -ChildPath 'server.log'
    foreach ($n in 1..4) {
      Set-Content -Path $log -Value ('run{0}-xxxxxxxxxx' -f $n) -NoNewline
      Invoke-LogRotation -Path $log -MaxBytes 10 -Keep 3 | Should -BeTrue
    }
    Test-Path $log | Should -BeFalse
    Get-Content -Path (Join-Path -Path $dir -ChildPath 'server.1.log') -Raw | Should -Be 'run4-xxxxxxxxxx'
    Get-Content -Path (Join-Path -Path $dir -ChildPath 'server.2.log') -Raw | Should -Be 'run3-xxxxxxxxxx'
    Get-Content -Path (Join-Path -Path $dir -ChildPath 'server.3.log') -Raw | Should -Be 'run2-xxxxxxxxxx'
    Test-Path (Join-Path -Path $dir -ChildPath 'server.4.log') | Should -BeFalse
  }
}

Describe 'Find-LlamaServerPath' {
  It 'finds llama-server.exe in the directory root' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'llama-root'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'llama-server.exe') -Value 'x'
    Find-LlamaServerPath -Dir $dir | Should -Be (Join-Path -Path $dir -ChildPath 'llama-server.exe')
  }

  It 'finds and reports a nested binary (zip subfolder layout)' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'llama-nested'
    $sub = Join-Path -Path $dir -ChildPath 'llama-b10757-bin-win-cpu-x64'
    New-Item -Path $sub -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path -Path $sub -ChildPath 'llama-server.exe') -Value 'x'
    Find-LlamaServerPath -Dir $dir | Should -Be (Join-Path -Path $sub -ChildPath 'llama-server.exe')
  }

  It 'falls back to llama-cli.exe when only the CLI is present' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'llama-cli-only'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'llama-cli.exe') -Value 'x'
    Find-LlamaServerPath -Dir $dir | Should -Be (Join-Path -Path $dir -ChildPath 'llama-cli.exe')
  }

  It 'prefers the server over the CLI when both exist' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'llama-both'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'llama-cli.exe') -Value 'x'
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'llama-server.exe') -Value 'x'
    Find-LlamaServerPath -Dir $dir | Should -Be (Join-Path -Path $dir -ChildPath 'llama-server.exe')
  }

  It 'returns null for a missing directory or a directory without binaries' {
    Find-LlamaServerPath -Dir (Join-Path -Path $TestDrive -ChildPath 'missing-dir') | Should -Be $null
    $empty = Join-Path -Path $TestDrive -ChildPath 'llama-empty'
    New-Item -Path $empty -ItemType Directory -Force | Out-Null
    Find-LlamaServerPath -Dir $empty | Should -Be $null
  }
}

Describe 'Get-SmokeToolCallName' {
  BeforeAll {
    $script:toolCallResponse = @'
{"choices":[{"finish_reason":"tool_calls","index":0,"message":{"content":null,"role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Hanoi\"}","name":"get_weather","type":"function"},"id":"call_0","index":0,"type":"function"}]}}],"created":1758500000,"model":"qwen3.6-35b-a3b","object":"chat.completion","timings":{"prompt_n":25,"prompt_per_second":11.4,"predicted_n":42,"predicted_per_second":8.75}}
'@
  }

  It 'reads choices[0].message.tool_calls[0].function.name from a real-looking response' {
    Get-SmokeToolCallName -ResponseText $script:toolCallResponse | Should -Be 'get_weather'
  }

  It 'returns the first name when several tools are called' {
    $json = '{"choices":[{"message":{"tool_calls":[{"function":{"name":"get_weather"}},{"function":{"name":"get_time"}}]}}]}'
    Get-SmokeToolCallName -ResponseText $json | Should -Be 'get_weather'
  }

  It 'handles a single (non-wrapped) message object' {
    $json = '{"choices":[{"message":{"tool_calls":{"function":{"name":"get_weather"}}}}]}'
    Get-SmokeToolCallName -ResponseText $json | Should -Be 'get_weather'
  }

  It 'returns null for a plain content answer without tool calls' {
    $json = '{"choices":[{"message":{"role":"assistant","content":"It is sunny."}}]}'
    Get-SmokeToolCallName -ResponseText $json | Should -Be $null
  }

  It 'returns null on invalid JSON, empty bodies or missing choices' {
    Get-SmokeToolCallName -ResponseText 'not json at all' | Should -Be $null
    Get-SmokeToolCallName -ResponseText '' | Should -Be $null
    Get-SmokeToolCallName -ResponseText '{"choices":[]}' | Should -Be $null
    Get-SmokeToolCallName -ResponseText '{"timings":{}}' | Should -Be $null
  }
}

Describe 'Get-SmokeTimingsPerSecond' {
  It 'reads timings.predicted_per_second (invariant culture)' {
    $json = '{"timings":{"prompt_n":25,"prompt_per_second":11.4,"predicted_n":42,"predicted_per_second":8.75}}'
    Get-SmokeTimingsPerSecond -ResponseText $json | Should -Be 8.75
  }

  It 'parses an integer-valued speed' {
    Get-SmokeTimingsPerSecond -ResponseText '{"timings":{"predicted_per_second":9}}' | Should -Be 9
  }

  It 'returns null when timings are missing, unparsable or the JSON is invalid' {
    Get-SmokeTimingsPerSecond -ResponseText '{"choices":[]}' | Should -Be $null
    Get-SmokeTimingsPerSecond -ResponseText '{"timings":{"predicted_per_second":"fast"}}' | Should -Be $null
    Get-SmokeTimingsPerSecond -ResponseText 'garbage' | Should -Be $null
    Get-SmokeTimingsPerSecond -ResponseText '' | Should -Be $null
  }
}

Describe 'Test-VcRuntime' {
  It 'is true only when all three runtime DLLs are present' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'sys32-full'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    foreach ($dll in @('vcruntime140.dll', 'msvcp140.dll', 'vcruntime140_1.dll')) {
      Set-Content -Path (Join-Path -Path $dir -ChildPath $dll) -Value 'x'
    }
    Test-VcRuntime -System32 $dir | Should -BeTrue
  }

  It 'is false when vcruntime140_1.dll (or any one of them) is missing' {
    $dir = Join-Path -Path $TestDrive -ChildPath 'sys32-partial'
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'vcruntime140.dll') -Value 'x'
    Set-Content -Path (Join-Path -Path $dir -ChildPath 'msvcp140.dll') -Value 'x'
    Test-VcRuntime -System32 $dir | Should -BeFalse
  }

  It 'is false for an empty or missing directory' {
    Test-VcRuntime -System32 (Join-Path -Path $TestDrive -ChildPath 'sys32-none') | Should -BeFalse
  }
}

Describe 'Test-VcRedistExitCode' {
  It 'accepts 0, 3010 (reboot pending) and 1638 (newer version present)' {
    Test-VcRedistExitCode -ExitCode 0 | Should -BeTrue
    Test-VcRedistExitCode -ExitCode 3010 | Should -BeTrue
    Test-VcRedistExitCode -ExitCode 1638 | Should -BeTrue
  }

  It 'rejects everything else' {
    Test-VcRedistExitCode -ExitCode 1 | Should -BeFalse
    Test-VcRedistExitCode -ExitCode 1602 | Should -BeFalse
    Test-VcRedistExitCode -ExitCode 5100 | Should -BeFalse
    Test-VcRedistExitCode -ExitCode -1 | Should -BeFalse
  }
}

Describe 'Get-NativeExitCodeHint' {
  It 'names the missing Visual C++ runtime for STATUS_DLL_NOT_FOUND (signed and unsigned)' {
    Get-NativeExitCodeHint -ExitCode -1073741515 | Should -BeLike 'Visual C++ runtime missing*'
    Get-NativeExitCodeHint -ExitCode 3221225781 | Should -BeLike 'Visual C++ runtime missing*'
  }

  It 'explains STATUS_INVALID_IMAGE_FORMAT' {
    Get-NativeExitCodeHint -ExitCode -1073741701 | Should -BeLike '*wrong architecture*'
  }

  It 'returns an empty string for ordinary exit codes' {
    Get-NativeExitCodeHint -ExitCode 0 | Should -Be ''
    Get-NativeExitCodeHint -ExitCode 1 | Should -Be ''
  }
}

Describe 'Invoke-NativeProbe' {
  It 'captures stdout, stderr and the exit code of a native process' {
    $r = Invoke-NativeProbe -FilePath 'cmd.exe' -Arguments '/d /c "echo out-line & echo err-line 1>&2 & exit 3"' -TimeoutSeconds 30
    $r.TimedOut | Should -BeFalse
    $r.ExitCode | Should -Be 3
    $r.Output | Should -BeLike '*out-line*'
    $r.Output | Should -BeLike '*err-line*'
  }

  It 'reports exit code 0 and cleans up its temp files' {
    $before = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'localagent-probe-*').Count
    $r = Invoke-NativeProbe -FilePath 'cmd.exe' -Arguments '/d /c "exit 0"' -TimeoutSeconds 30
    $r.ExitCode | Should -Be 0
    @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'localagent-probe-*').Count | Should -Be $before
  }

  It 'kills a process that outlives the timeout' {
    $r = Invoke-NativeProbe -FilePath 'cmd.exe' -Arguments '/d /c "ping -n 30 127.0.0.1 > nul"' -TimeoutSeconds 2
    $r.TimedOut | Should -BeTrue
    $r.ExitCode | Should -Be -1
  }
}

Describe 'Get-CpuInfoFromServerLog' {
  It 'finds the system_info and CPU backend lines and reports AVX2' {
    $lines = @(
      '0.00.001 I load_backend: loaded CPU backend from C:\la\llama\ggml-cpu-alderlake.dll',
      '0.00.020 I srv load_model: loading model',
      '0.00.900 I cmn common_param: system_info: n_threads = 16 (n_threads_batch = 64) / 64 | CPU : SSE3 = 1 | SSSE3 = 1 | AVX = 1 | AVX_VNNI = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1 | AVX512 = 0 | LLAMAFILE = 1 | OPENMP = 1 | REPACK = 1 | ',
      '0.01.000 I srv main: server is listening'
    )
    $cpu = Get-CpuInfoFromServerLog -Lines $lines
    $cpu.SystemInfo | Should -BeLike '*system_info: n_threads = 16*'
    $cpu.Backend | Should -BeLike '*ggml-cpu-alderlake.dll'
    $cpu.HasAvx2 | Should -BeTrue
    $cpu.Flags['AVX512'] | Should -Be '0'
    $cpu.Flags['FMA'] | Should -Be '1'
  }

  It 'reports AVX2 false when the line says AVX2 = 0' {
    $cpu = Get-CpuInfoFromServerLog -Lines @('x system_info: n_threads = 4 / 4 | CPU : AVX = 1 | AVX2 = 0 | FMA = 0 | ')
    $cpu.HasAvx2 | Should -BeFalse
  }

  It 'returns null HasAvx2 and empty strings when nothing matches' {
    $cpu = Get-CpuInfoFromServerLog -Lines @('main: server is listening', '')
    $cpu.SystemInfo | Should -Be ''
    $cpu.Backend | Should -Be ''
    $null -eq $cpu.HasAvx2 | Should -BeTrue
    $cpu = Get-CpuInfoFromServerLog -Lines @()
    $null -eq $cpu.HasAvx2 | Should -BeTrue
  }
}

Describe 'Test-RealPythonPath' {
  It 'rejects the Microsoft Store alias under WindowsApps (any case)' {
    Test-RealPythonPath -Path 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\python.exe' -WindowsAppsRoot 'C:\Users\u\AppData\Local\Microsoft\WindowsApps' | Should -BeFalse
    Test-RealPythonPath -Path 'c:\users\U\appdata\local\microsoft\windowsapps\python3.exe' -WindowsAppsRoot 'C:\Users\u\AppData\Local\Microsoft\WindowsApps' | Should -BeFalse
  }

  It 'accepts a real interpreter elsewhere' {
    Test-RealPythonPath -Path 'C:\Users\u\AppData\Local\Programs\Python\Python312\python.exe' -WindowsAppsRoot 'C:\Users\u\AppData\Local\Microsoft\WindowsApps' | Should -BeTrue
  }

  It 'does not treat a sibling folder with the same prefix as WindowsApps' {
    Test-RealPythonPath -Path 'C:\Users\u\AppData\Local\Microsoft\WindowsAppsExtra\python.exe' -WindowsAppsRoot 'C:\Users\u\AppData\Local\Microsoft\WindowsApps' | Should -BeTrue
  }

  It 'rejects an empty path' {
    Test-RealPythonPath -Path '' -WindowsAppsRoot 'C:\x' | Should -BeFalse
  }
}

Describe 'Get-PythonVersionFromText' {
  It 'parses "Python 3.12.4"' {
    Get-PythonVersionFromText -Text 'Python 3.12.4' | Should -Be ([version]'3.12.4')
  }

  It 'finds the version on a later line' {
    Get-PythonVersionFromText -Text "warning: something`r`nPython 3.10.0`r`n" | Should -Be ([version]'3.10.0')
  }

  It 'returns null for the Store stub message and for empty text' {
    Get-PythonVersionFromText -Text 'Python was not found; run without arguments to install from the Microsoft Store' | Should -BeNullOrEmpty
    Get-PythonVersionFromText -Text '' | Should -BeNullOrEmpty
  }

  It 'orders 3.9 below the 3.10 minimum' {
    (Get-PythonVersionFromText -Text 'Python 3.9.13') -lt [version](Get-LocalAgentConstants).PythonMinVersion | Should -BeTrue
  }
}

Describe 'Join-PathList' {
  It 'keeps order and drops case-insensitive duplicates and empty pieces' {
    Join-PathList -Lists @('C:\A;C:\B\', 'c:\b;;C:\C', 'C:\a;D:\session') | Should -Be 'C:\A;C:\B\;C:\C;D:\session'
  }

  It 'tolerates null and empty lists' {
    Join-PathList -Lists @($null, '', 'C:\X') | Should -Be 'C:\X'
  }
}
