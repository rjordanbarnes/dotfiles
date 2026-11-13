# dotfiles

Windows agent policies and maintenance utilities used on this machine.

`copilot\copilot-instructions.md` is NTFS-hardlinked to:

- `~\.copilot\copilot-instructions.md` for all Copilot sessions
- `~\.claude\CLAUDE.md` for Claude-compatible agents and VS Code's Local harness
- `C:\code\AGENTS.md` for agents working from the workspace root

Browser control uses the authenticated `playwright-extension` MCP server.
Computer Use MCP is the only browser fallback and handles non-browser desktop UI.
Machine-specific MCP configuration and browser tokens are not tracked here.

Hardlinks are used because Windows symbolic links require elevation here.
Edit linked files in place; replacing them breaks the link.

## Windowless background helpers

`windows\Get-BackgroundProcessHost.ps1` builds a reusable console-free executable
with Windows' existing .NET Framework compiler and returns its path. Source is
tracked here; binaries are cached by source hash under
`%LOCALAPPDATA%\Copilot\BackgroundProcess`, outside Git.

Use the returned executable as a scheduled task's action. Its first argument is
the full path to the real console executable, followed by that program's
arguments. For example, pass `powershell.exe -NoProfile -NonInteractive -File`
and the script path, quoting paths with spaces. Keep the task's working directory,
logon identity, retry policy and duplicate-instance protection.

Unlike `-WindowStyle Hidden`, this host prevents creation of a console window.
It waits for the helper and returns its exit code. Scripts must write their own
diagnostic logs; failures to start a program are logged beside the cached host.
Normal interactive terminals and user-facing apps are not changed.

The opt-in first argument `--proxy-stdio` preserves private inherited
stdin/stdout/stderr for a console-free child while still waiting for it and
returning its exit code. The host proxies raw bytes concurrently and does not
parse or log them. Omit the flag for the original hidden-helper behavior.

Run the focused checks with Windows PowerShell:

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester .\windows\BackgroundProcess.Tests.ps1 -EnableExit"
```

## Docker maintenance

`docker\Install-DockerMaintenance.ps1` registers a daily 03:00 local-time task.
Missed runs happen when the machine is next available; the task does not wake it.
Registration may require administrator approval, but maintenance runs as the
signed-in user with limited privileges and stores no password.

The task removes only untagged images created more than 30 days ago and not
referenced by any container. It skips active GitHub runner jobs and stopped Docker
engines, and refuses remote Docker contexts. Tagged images, shared CI build cache,
containers and volumes are never pruned. Docker's existing build-cache GC settings
are left unchanged. It never starts, stops or restarts Docker or compacts its disk.

Run `docker\Invoke-DockerMaintenance.ps1 -WhatIf` for a preview. The latest status
is in `~\.local\state\docker-maintenance\last-run.json`; previews use
`last-preview.json`. These small reports are overwritten, not accumulated.
Remove the scheduled task to disable automatic cleanup:
`Unregister-ScheduledTask -TaskName Dotfiles-Docker-Maintenance -Confirm:$false`.
