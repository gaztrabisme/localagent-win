# Pester 5 tests for the `localagent model` helpers in lib/localagent.psm1
# (model spec parsing, Hugging Face file selection, RAM rule, MTP errors).
# Run with: Invoke-Pester tests/Model.Tests.ps1

BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\localagent.psm1') -Force

  function New-TreeFile {
    param([string]$Path, [long]$Size, [string]$Oid)
    return [pscustomobject]@{
      type = 'file'
      path = $Path
      size = $Size
      lfs  = [pscustomobject]@{ oid = $Oid; size = $Size; pointerSize = 134 }
    }
  }
}

Describe 'Select-HfGgufFiles' {
  BeforeAll {
    $script:tree = @(
      [pscustomobject]@{ type = 'file'; path = 'README.md'; size = 100 },
      [pscustomobject]@{ type = 'directory'; path = 'UD-Q8_K_XL'; size = 0 },
      (New-TreeFile -Path 'Qwen-UD-Q2_K_XL.gguf' -Size 12300000000 -Oid 'aa'),
      (New-TreeFile -Path 'Qwen-Q4_K_M.gguf' -Size 21000000000 -Oid 'bb'),
      (New-TreeFile -Path 'Qwen-Q4_K_S.gguf' -Size 20000000000 -Oid 'cc'),
      (New-TreeFile -Path 'Qwen-Q4_0.gguf' -Size 19000000000 -Oid 'dd'),
      (New-TreeFile -Path 'Qwen-Q4_0_4_4.gguf' -Size 19100000000 -Oid 'ee'),
      (New-TreeFile -Path 'UD-Q8_K_XL/Qwen-UD-Q8_K_XL-00002-of-00002.gguf' -Size 10000000000 -Oid 'f2'),
      (New-TreeFile -Path 'UD-Q8_K_XL/Qwen-UD-Q8_K_XL-00001-of-00002.gguf' -Size 30000000000 -Oid 'f1'),
      (New-TreeFile -Path 'mmproj-F16.gguf' -Size 900000000 -Oid '11'),
      (New-TreeFile -Path 'mmproj-Q8_0.gguf' -Size 600000000 -Oid '12'),
      (New-TreeFile -Path 'Qwen-Q8_0.gguf' -Size 37000000000 -Oid '13')
    )
  }

  It 'picks a single file, case-insensitively, with size and sha256 from lfs' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'ud-q2_k_xl'
    $pick.Status | Should -Be 'ok'
    @($pick.Files).Count | Should -Be 1
    $pick.Files[0].Path | Should -Be 'Qwen-UD-Q2_K_XL.gguf'
    $pick.Files[0].Size | Should -Be 12300000000
    $pick.Files[0].Sha256 | Should -Be 'aa'
    $pick.TotalBytes | Should -Be 12300000000
  }

  It 'takes every part of a split set, first shard first' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'UD-Q8_K_XL'
    $pick.Status | Should -Be 'ok'
    @($pick.Files | ForEach-Object { $_.Path }) | Should -Be @(
      'UD-Q8_K_XL/Qwen-UD-Q8_K_XL-00001-of-00002.gguf',
      'UD-Q8_K_XL/Qwen-UD-Q8_K_XL-00002-of-00002.gguf')
    $pick.TotalBytes | Should -Be 40000000000
  }

  It 'reports none and lists every set when nothing matches' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'IQ1_S'
    $pick.Status | Should -Be 'none'
    @($pick.Files).Count | Should -Be 0
    @($pick.Candidates).Count | Should -Be 7
  }

  It 'reports ambiguous when two different files match' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'Q4_K'
    $pick.Status | Should -Be 'ambiguous'
    @($pick.Candidates | ForEach-Object { $_.Stem }) | Should -Be @('Qwen-Q4_K_M', 'Qwen-Q4_K_S')
  }

  It 'prefers the file whose name ends with the tag' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'Q4_0'
    $pick.Status | Should -Be 'ok'
    $pick.Files[0].Path | Should -Be 'Qwen-Q4_0.gguf'
  }

  It 'excludes mmproj files' {
    $pick = Select-HfGgufFiles -Tree $script:tree -Quant 'Q8_0'
    $pick.Status | Should -Be 'ok'
    $pick.Files[0].Path | Should -Be 'Qwen-Q8_0.gguf'
    @(Get-HfGgufSets -Tree $script:tree | Where-Object { $_.Stem -like 'mmproj*' }).Count | Should -Be 0
  }
}

Describe 'Resolve-ModelSpec' {
  It 'recognizes repo:quant and a bare repo' {
    $r = Resolve-ModelSpec -Spec 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL'
    $r.Kind | Should -Be 'hf'
    $r.Repo | Should -Be 'unsloth/Qwen3.6-35B-A3B-GGUF'
    $r.Quant | Should -Be 'UD-Q3_K_XL'
    $bare = Resolve-ModelSpec -Spec 'unsloth/Qwen3.6-35B-A3B-GGUF'
    $bare.Kind | Should -Be 'hf'
    $bare.Quant | Should -Be ''
  }

  It 'recognizes local paths, URLs, --list and default' {
    (Resolve-ModelSpec -Spec 'C:\models\x.gguf').Kind | Should -Be 'local'
    (Resolve-ModelSpec -Spec '.\x.gguf').Kind | Should -Be 'local'
    (Resolve-ModelSpec -Spec 'https://huggingface.co/a/b/resolve/main/x.gguf').Kind | Should -Be 'url'
    (Resolve-ModelSpec -Spec '--list').Kind | Should -Be 'list'
    (Resolve-ModelSpec -Spec 'default').Kind | Should -Be 'default'
    (Resolve-ModelSpec -Spec 'not a model').Kind | Should -Be 'invalid'
  }
}

Describe 'Get-HfModelDirName / Test-ModelFitsRam / Get-ModelLoadTimeout' {
  It 'maps owner/name to owner__name' {
    Get-HfModelDirName -Repo 'unsloth/Qwen3.6-35B-A3B-GGUF' | Should -Be 'unsloth__Qwen3.6-35B-A3B-GGUF'
  }

  It 'fits weights up to total RAM minus 8 GB' {
    Test-ModelFitsRam -ModelBytes 24GB -TotalRamBytes 32GB | Should -BeTrue
    Test-ModelFitsRam -ModelBytes (24GB + 1) -TotalRamBytes 32GB | Should -BeFalse
  }

  It 'budgets 60 s plus 30 s per GB' {
    Get-ModelLoadTimeout -ModelBytes 0 | Should -Be 60
    Get-ModelLoadTimeout -ModelBytes 12GB | Should -Be 420
  }
}

Describe 'Test-MtpLoadError' {
  It 'flags MTP / draft / nextn errors' {
    Test-MtpLoadError -Lines @('srv load: loading model', 'common_speculative_init: failed to create MTP context') | Should -BeTrue
    Test-MtpLoadError -Lines @('llama_model_load: error: model has no nextn layers') | Should -BeTrue
  }

  It 'ignores normal log lines' {
    Test-MtpLoadError -Lines @('srv llama_server: model loaded', 'draft acceptance rate = 0.8', '') | Should -BeFalse
  }
}
