# localagent -- a local Qwen3.6 coding model on your Windows PC

This package turns a Windows 11 x64 PC into a private coding-assistant box.
It downloads a CPU build of [llama.cpp](https://github.com/ggml-org/llama.cpp)
(the program that runs the model) and the **Qwen3.6-35B-A3B** model (23 GB).
It then starts a small server on `127.0.0.1:8080` at every logon and connects
it to the **omp** coding agent and **VS Code Copilot Chat**. Everything runs
as your user and nothing leaves the machine.

The installer also installs Python 3.10+ and git when they are missing, and
the Microsoft Visual C++ runtime when your PC does not have it. The runtime
is the only system-wide step, and it can ask for administrator approval once.

## Install

Unpack the package, then either:

1. **Double-click `install.cmd`** in the unpacked folder. A console window
   shows the progress and waits for a key press at the end.
2. Or run these three lines in PowerShell:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   cd C:\path\to\localagent-win
   .\install.ps1
   ```

   `-Scope Process` lasts only for that window.

Both routes take the same switches, for example `install.cmd -NonInteractive`:

| Switch | Effect |
|---|---|
| `-NonInteractive` | no prompts, no pauses |
| `-Editor continue` or `-Editor none` | editor integration (default `copilot`) |
| `-SkipOmp` | do not install or configure omp |
| `-SkipTools` | do not install Python and git |
| `-SkipEditor` | same as `-Editor none` |
| `-WithSubagent` | also install the subagent MCP server (see below) |
| `-Threads N` | generation threads (default 16) |
| `-ModelSource <path or URL>` | copy the model from a local or UNC file, or another URL |

After the install, run `localagent bench` once (see below) to set the fastest
thread count for your CPU.

## What "ready" looks like

The installer ends with a `localagent is ready` block. By then it has
downloaded and verified everything and started the server. The first start
reads 23 GB from disk, so the health wait can take a few minutes. It has also
run a tool-call smoke test and a one-line omp prompt, and printed the
measured generation speed.

The PATH changes reach new terminals. In a PowerShell window that was
already open, paste the line the ready block prints:

```powershell
$env:PATH = "$env:LOCALAPPDATA\omp;$env:LOCALAPPDATA\localagent\bin;$env:PATH"
```

## What this installs and touches

This section is for the IT department reviewing the package.

**Scope.** The package itself is per-user, under `%LOCALAPPDATA%` and
`%USERPROFILE%`. No Windows service is created, and the only registry value
the package writes is the user `Path` (`HKCU\Environment`). Two
prerequisites can land system-wide:

- The Microsoft Visual C++ 2015-2022 x64 runtime is installed only when it
  is missing, and Windows may ask for administrator approval.
- git, when missing, is installed by the Git for Windows installer. That
  installer goes to `C:\Program Files\Git` when the account is an
  administrator (even with `--scope user`) and to the user profile
  otherwise. Python goes to `%LOCALAPPDATA%\Programs\Python` either way.

**Network.** The model server listens on `127.0.0.1:8080` only, so no
inbound firewall rule is created or needed. The package sends no telemetry.
After the install, the only outbound connections the package makes are the
downloads you start yourself with `localagent model`. omp is configured to
use the local server as its model provider.

**Startup.** A Scheduled Task named **"LocalAgent Server"** runs at logon
under the user's own account with limited rights (no elevation). Its action
is `%SystemRoot%\System32\cmd.exe /c start "LocalAgent Server" /min
"%LOCALAPPDATA%\localagent\llama\llama-server.exe" <arguments>`: cmd.exe
starts the server and exits. There is no PowerShell and no hidden script.
The server starts minimized in the taskbar as "LocalAgent Server". Closing
that window stops the server; `localagent start` brings it back.

**Unsigned executables.** `llama-server.exe` (llama.cpp) and `omp.exe` are
not code-signed. SmartScreen or AppLocker may need an exception for:

- `%LOCALAPPDATA%\localagent\llama\*.exe`
- `%LOCALAPPDATA%\omp\omp.exe`

The installer checks every download that has a pinned hash against its
exact byte size and SHA256 before using it.

**Downloads.**

| What | From | Size | Hash-pinned |
|---|---|---|---|
| llama.cpp b10757, CPU build | `https://github.com/ggml-org/llama.cpp/releases/download/b10757/llama-b10757-bin-win-cpu-x64.zip` | 18,373,860 bytes | yes (SHA256) |
| Qwen3.6-35B-A3B model (GGUF) | `https://huggingface.co/havenoammo/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf` | 23,257,919,904 bytes | yes (SHA256) |
| omp v18.2.8 coding agent | `https://github.com/can1357/oh-my-pi/releases/download/v18.2.8/omp-windows-x64.exe` | 218,729,472 bytes | yes (SHA256) |
| Visual C++ 2015-2022 x64 runtime, only when missing | `https://aka.ms/vs/17/release/vc_redist.x64.exe` | varies (Microsoft's current release) | no; Microsoft-signed installer |
| Python 3.12, only when no Python 3.10+ is present | `winget install --id Python.Python.3.12 --scope user` | varies | winget checks its manifest hash |
| Python 3.12.10, fallback when winget is missing or fails | `https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe` | 26,964,224 bytes | yes |
| git, only when missing | `winget install --id Git.Git --scope user` | varies | winget checks its manifest hash |
| Git for Windows 2.55.0.5, fallback when winget is missing or fails | `https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe` | 65,343,712 bytes | yes (SHA256) |
| uv 0.12.18, only with `-WithSubagent` | `https://github.com/astral-sh/uv/releases/download/0.12.18/uv-x86_64-pc-windows-msvc.zip` | 17,891,221 bytes | yes (SHA256) |
| Python 3.12 for the subagent tool, only with `-WithSubagent` | fetched by `uv tool install --python 3.12` | varies | checked by uv |
| Continue extension, only with `-Editor continue` | VS Code Marketplace, via `code --install-extension` | varies | no |

**Files and settings.**

```
%LOCALAPPDATA%\localagent\
  llama\        llama.cpp binaries (llama-server.exe, llama-bench.exe, ...)
  models\       Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf (23 GB), and any model
                added with `localagent model`
  bin\          localagent.ps1 + localagent.cmd (on the user PATH)
  lib\          localagent.psm1 (helper module)
  templates\    task.xml (the CLI re-registers the task from it)
  logs\         server.log, server.1.log .. server.3.log
  config.json   server settings (model, port, threads, context, sampling)
  install.log   installer log
  bench.json    result of `localagent bench`
%LOCALAPPDATA%\omp\omp.exe   the omp coding agent (on the user PATH)
```

Outside these folders the installer touches:

- `%USERPROFILE%\.omp\agent\config.yml`: the `modelRoles` block and
  `setupVersion: 2` (the second one keeps omp's first-run wizard from showing),
- `%APPDATA%\Code\User\chatLanguageModels.json`: one VS Code Copilot Chat model entry,
- `%USERPROFILE%\.continue\config.yaml`, only with `-Editor continue`,
- the user PATH: `%LOCALAPPDATA%\localagent\bin` and `%LOCALAPPDATA%\omp`,
- Python (`%LOCALAPPDATA%\Programs\Python\Python312`, on the user PATH) and
  git (see Scope above), when they were missing,
- with `-WithSubagent`: `%USERPROFILE%\.local\bin` (uv, uvx and the
  `subagent` tool, added to the user PATH),
  `%USERPROFILE%\.config\subagent\config.toml`, and one `local-subagent`
  entry in `%APPDATA%\Code\User\mcp.json`.

`uninstall.ps1` removes all of this except omp.exe and its PATH entry,
Python, git, uv and the Visual C++ runtime, which other programs may use.

## Minimum machine

- Windows 10/11, **64-bit**, CPU only (no GPU needed)
- CPU with **AVX2** (the installer checks this and stops without it; AVX-512 is used if present)
- **32 GB RAM** (the installer warns below 30 GB and stops below 24 GB)
- **35 GB free disk** on the install drive (23 GB model + binaries + logs)
- Reference machine: AMD EPYC 7763 (64 cores). Anything with enough RAM and AVX2 works, only slower.

## How long the download takes

The model is a single 23.3 GB file: 3 to 5 minutes on a gigabit line, about
35 minutes on a 100 Mbit line. The download is resumable. If it is
interrupted, run the installer again and it continues where it stopped.

## Using omp

Open a **new** terminal and run:

```
omp
```

omp finds the local server by itself (its built-in `llama.cpp` provider) and
uses the model `llama.cpp/qwen3.6-35b-a3b` with no flags. A one-shot prompt:

```
omp -p "Reply with exactly: OK"
```

## Using the model in VS Code Copilot Chat

1. (Re)start VS Code.
2. Open the Copilot Chat **model picker**.
3. Pick **"Local Qwen3.6"**.
4. Chat and agent mode work as usual; the model runs on your machine.

If it does not appear, check that `%APPDATA%\Code\User\chatLanguageModels.json`
contains the entry and reload the window.

## Let Copilot delegate to the local model (`-WithSubagent`)

Copilot's paid credits reset every month. When they run out mid-month, the
local model can do the work: Copilot's **agent mode hands the whole task to
a subagent** that runs on your machine. `install.ps1 -WithSubagent` sets
this up:

```powershell
.\install.ps1 -WithSubagent
```

On top of the normal install it adds, per user:

- **uv**, the Python tool manager, from its pinned release zip into
  `%USERPROFILE%\.local\bin` (only when uv is missing; no install script runs),
- the **`subagent` MCP server**, from the wheel shipped in `dist\`, with
  `uv tool install --python 3.12`,
- **`%USERPROFILE%\.config\subagent\config.toml`**, which points the subagent
  at the local omp, which talks to the local server on 127.0.0.1:8080,
- a **`local-subagent` entry** in VS Code's `mcp.json` (your other MCP
  servers are kept).

Then (re)start VS Code. **MCP servers** lists **local-subagent**, and Copilot
agent mode gets a **`delegate`** tool. Asking Copilot to "delegate X" starts
a run on the local model and reports back what it did. No Copilot credits are
spent while the subagent works.

Check the wiring by hand while the server is up:

```
subagent doctor --json
```

The installer is re-runnable and skips what is already present, so
`.\install.ps1 -WithSubagent` also adds the subagent to an existing install.
Without the switch none of this is installed or changed.

## The `localagent` command

A new terminal understands `localagent`:

```
localagent status    task state, server health, alias, model file, pid, memory,
                     config, whether the subagent MCP server is installed
localagent start     start the server now (waits for /health, up to 10 min)
localagent stop      stop the server
localagent restart   stop, re-register the task from config.json, start
localagent logs      last 50 lines of the server log (-Tail N for more)
localagent bench     find the fastest thread count (see below)
localagent config    open config.json in notepad; after you close it the
                     task is re-registered (then run localagent restart)
localagent model X   switch to another model (see below)
localagent serve     run the server in this console (for troubleshooting)
```

## `localagent bench`

Runs `llama-bench` over a thread ladder (`-t 8,16,32,<physical cores>`),
prints a table, writes `bench.json`, writes the **fastest thread count into
`config.json`**, re-registers the task and starts the server. The default of
16 threads is a guess; the benchmark measures your CPU. It takes a few
minutes.

## Try another model

Copy a model name from Hugging Face and switch with one command:

```powershell
localagent model unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_XL   # repo:quant, as on the Hugging Face page
localagent model unsloth/Qwen3.6-35B-A3B-GGUF              # no quant: list the .gguf files with sizes
localagent model C:\path\to\file.gguf                      # a local file, used in place
localagent model https://huggingface.co/.../resolve/main/x.gguf
localagent model --list                                    # what is in models\, * marks the active one
localagent model default                                   # back to the shipped model
```

The command downloads the file into `models\<owner>__<repo>\` (resumable,
checked against the size and SHA256 that Hugging Face publishes), points
`config.json` at it, restarts the server and prints the measured tokens per
second. A URL download is not hash-pinned. A split model (`-00001-of-00003`)
downloads all parts. For a gated repo, set `$env:HF_TOKEN` first.

Rules:

- **RAM**: the weights must fit in total RAM minus 8 GB. On a 32 GB PC that
  means files up to about 24 GB. `-Force` skips the check.
- **Architecture**: only models that llama.cpp b10757 supports load.
- **MTP**: the shipped model has an MTP head (a built-in draft for faster
  generation). If a model has none and the server fails to load, the
  command turns MTP off and says so. `localagent model default` turns it
  back on.
- **Alias**: the server keeps the name `qwen3.6-35b-a3b`, so omp and VS Code
  keep working without changes. `-Alias <name>` renames it and updates the
  VS Code entry and omp's model roles.

## Expected speed

The installer's smoke test prints the measured speed. On an EPYC 7763 expect
**10 to 30 tokens per second**. Prompt processing is faster than generation.
Single-digit numbers: run `localagent bench` and check that nothing else is
using the CPU.

## Troubleshooting

- **Install went wrong**: read `%LOCALAPPDATA%\localagent\install.log`. Every
  step is timestamped and a failure names the step.
- **Server misbehaving**: `localagent status`, then `localagent logs -Tail 200`.
- **The "LocalAgent Server" window in the taskbar**: that window is the
  server, started minimized. Closing it stops the server; `localagent start`
  brings it back.
- **Model missing or wrong size**: run the installer again; the download resumes.
- **"Visual C++ runtime missing"**: step 2 could not install it (approval
  declined, or no admin account available). Install "Microsoft Visual C++
  2015-2022 Redistributable (x64)" from
  <https://aka.ms/vs/17/release/vc_redist.x64.exe>, then run the installer again.
- **Python or git install failed**: install Python 3.10+ from
  <https://www.python.org/downloads/> or git from <https://git-scm.com/download/win>,
  or re-run with `-SkipTools`.
- **`omp` or `localagent` not found**: open a new terminal, or paste the
  `$env:PATH` line from "What ready looks like".
- **VS Code model missing**: reload the window; check `chatLanguageModels.json`.
- **No `delegate` tool / local-subagent not in MCP servers**: reload the
  window, check `mcp.json` for the `local-subagent` entry, and run
  `subagent doctor --json`.
- **Port taken**: change `"port"` in `config.json` (`localagent config`), then
  `localagent restart`. The omp and VS Code entries assume 8080.

## Uninstall

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\path\to\localagent-win
.\uninstall.ps1            # add -RemoveModel to also delete the models
```

It stops and removes the task, stops the server, removes our entries from the
omp and VS Code configs and the PATH, removes the subagent pieces (the uv
tool, the `local-subagent` entry, and the config file when it is exactly the
one the installer wrote), and empties the install folder. `models\` stays
unless you pass `-RemoveModel`. omp.exe, VS Code, Python, git, uv and the
Visual C++ runtime stay installed.
