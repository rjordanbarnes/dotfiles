# dotfiles

Windows agent browser policy and terminal-attention configuration used on this machine.

Tracked files are NTFS-hardlinked to:

- `~\.wezterm.lua`
- `~\.copilot\hooks\wezterm-attention.json`
- `~\.copilot\hooks\wezterm-attention.ps1`

`copilot\copilot-instructions.md` is also hardlinked to:

- `~\.copilot\copilot-instructions.md` for all Copilot sessions
- `~\.claude\CLAUDE.md` for Claude-compatible agents and VS Code's Local harness
- `C:\code\AGENTS.md` for agents working from the workspace root

Browser control uses the authenticated `playwright-extension` MCP server.
Computer Use MCP is the only browser fallback and handles non-browser desktop UI.
Machine-specific MCP configuration and browser tokens are not tracked here.

Hardlinks are used because Windows symbolic links require elevation here.
Edit linked files in place; replacing them breaks the link.

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
