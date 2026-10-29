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
