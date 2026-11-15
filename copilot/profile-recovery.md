# Copilot profile migration recovery

The intended profile is `E:\copilot`, selected by the persistent Windows user
`COPILOT_HOME` setting. The old `$HOME\.copilot` should become a compatibility
junction. Global instructions still come from the canonical dotfiles file on C:.

## First agent after a reboot

Read `$env:LOCALAPPDATA\Copilot\ProfileMigration\status.json` before changing
profile data. This file and `migration.log` stay on C: independently of the
migration. `plan.json` records the task and worker locations; it contains no
authentication credentials. The complete worker journal, copy log, and verified
file manifest are under `E:\copilot-migration`.

| Status | Meaning and safe action |
| --- | --- |
| `armed` / `waiting-for-reboot` | No migration yet. The task runs at the first sign-in after a different boot, not merely a logoff/logon. |
| `running` | Copy/verification or cutover is in progress. Do not change either profile; leave the task alone. |
| `waiting-for-quiet` | A Copilot client or helper is still active. No forced shutdown occurs. Let jobs finish and close clients; Windows retries once per minute, up to 60 retries. |
| `waiting-for-storage` | E: is unavailable. C: was not switched. Restore access to E:; the same bounded retries apply. |
| `needs-review` | Automatic retries are disabled. Preserve every copy and diagnose the worker journal and log before doing anything else. |
| `complete` | Copy and hashes passed, the user setting and legacy junction were verified, and the verified C: backup was removed. |
| `complete-with-retained-backup` | Cutover succeeded, but changed/locked backup entries remain. Inspect them before considering cleanup. |

If retries are exhausted, the status may still say `waiting-for-quiet` or
`waiting-for-storage`. Inspect the scheduled task's last result and state. Do not
claim that relocation happened until the worker journal and filesystem agree.
If the worker never starts, inspect the task action's executable and its adjacent
`launcher.log`, as well as the task's last result.

```powershell
$control = Join-Path $env:LOCALAPPDATA 'Copilot\ProfileMigration'
Get-Content -LiteralPath (Join-Path $control 'status.json') -Raw
Get-ScheduledTask -TaskName 'Copilot-Profile-Migration-Next-Reboot'
Get-ScheduledTaskInfo -TaskName 'Copilot-Profile-Migration-Next-Reboot'
[Environment]::GetEnvironmentVariable('COPILOT_HOME', 'User')
Get-Item -LiteralPath "$HOME\.copilot", 'E:\copilot' -Force |
    Select-Object FullName, Attributes, LinkType, Target
```

## Failure boundaries

- `copying`: C: remains authoritative. An owned staging copy can be retried only
  while its journal still says `copying`; never recopy through installed
  instruction symlinks. Extra or type-conflicting staging entries are preserved
  under `E:\copilot-migration\retained-staging-*`, not deleted; the journal records
  those directories. Review them before cleanup.
- `binding`: instruction links may have been installed. Never blindly rerun the
  copy. If a crash left the C: source absent but its intact
  `.copilot.before-e-copilot` backup present, the worker can restore C: while
  quiescent and mark `rolled-back`. If a new directory appeared at the old path,
  preserve it as well as the original backup and E: copy.
- `rolled-back`: the ordinary failure path restored C: and its original user
  setting. Review the E: stage before rearming.
- `cutover-complete`: E: is selected, but backup cleanup may have been interrupted.
  Verify E:, the legacy junction, canonical instructions, and the full verified
  manifest before deciding what to retain. Do not delete the backup just because
  E: exists.

The worker refuses running Copilot clients and command-line profile references.
It never kills processes. Rename/registry failures attempt rollback; unexpected
directories, changed backup files, and locked files are preserved for review.

Before repairing or rearming a failed migration, disable its scheduled task from
an elevated PowerShell:

```powershell
Disable-ScheduledTask -TaskName 'Copilot-Profile-Migration-Next-Reboot'
```

Do not reset authentication, delete session history, replace junctions, or modify
the persistent `COPILOT_HOME` speculatively. Diagnose the paths and journal first.
Do not paste credentials or full private configuration into issues or commits.

## If Copilot itself cannot start

This launcher remains on C: even if E: is unavailable:

```powershell
& 'C:\code\dotfiles\windows\Start-CopilotRecovery.ps1'
```

It uses a small, separate profile at
`$env:LOCALAPPDATA\Copilot\ProfileRecovery`, loads the canonical global instructions,
and changes `COPILOT_HOME` only for the child CLI process. It does not alter the
Windows user setting or overwrite the original profile. Login may be required;
this is a diagnostic workspace, not a replacement for the real session history.

Ask that agent to read this guide and the C: migration status/log. Once access is
restored, resume the ordinary profile in a fresh terminal and verify history,
authentication, settings, MCP configuration, and the canonical instruction binding.
