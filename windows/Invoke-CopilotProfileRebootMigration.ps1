[CmdletBinding()]
param(
    [string]$ControlDirectory = (Join-Path $env:LOCALAPPDATA 'Copilot\ProfileMigration')
)

$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $ControlDirectory 'status.json'
$logPath = Join-Path $ControlDirectory 'migration.log'
$status = @{
    state = 'starting'
    updated_at = [DateTimeOffset]::UtcNow.ToString('o')
}
$plan = $null

function Save-MigrationStatus {
    $status.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    $temporary = $statusPath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($status | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $statusPath, $true)
}

function Disable-MigrationTask {
    if ($plan -and $plan.task_name) {
        Disable-ScheduledTask -TaskName $plan.task_name -ErrorAction SilentlyContinue | Out-Null
    }
}

try {
    $plan = Get-Content -LiteralPath (Join-Path $ControlDirectory 'plan.json') -Raw | ConvertFrom-Json
    $status.source = $plan.source
    $status.destination = $plan.destination
    $status.task_name = $plan.task_name
    $status.recovery_guide = $plan.recovery_guide
    $status.migration_log = $logPath
    $status.worker_state = Join-Path $plan.work_directory 'state.json'
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $plan.owner_sid) {
        throw 'The task is not running as the Windows user who owns the profile.'
    }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
    if ($boot -eq [long]$plan.armed_boot_ticks) {
        $status.state = 'waiting-for-reboot'
        Save-MigrationStatus
        exit 0
    }
    if (-not (Test-Path -LiteralPath $plan.worker -PathType Leaf)) {
        $status.state = 'waiting-for-storage'
        $status.message = 'The E: migration worker is unavailable. No profile data has been changed.'
        Save-MigrationStatus
        exit 75
    }
    $status.state = 'running'
    $status.started_at = [DateTimeOffset]::UtcNow.ToString('o')
    Save-MigrationStatus
    "`n--- $($status.started_at) ---" | Add-Content -LiteralPath $logPath
    & $plan.python -u $plan.worker *>> $logPath
    $workerExit = $LASTEXITCODE
    $status.worker_exit_code = $workerExit
    if ($workerExit -eq 75) {
        $status.state = 'waiting-for-quiet'
        $status.message = 'A client or profile helper is still running. The task will retry; do not interrupt active jobs.'
        Save-MigrationStatus
        exit 75
    }
    if ($workerExit -ne 0) {
        throw "The migration worker returned $workerExit. Preserve both drives and inspect the migration log."
    }
    $journal = Get-Content -LiteralPath $status.worker_state -Raw | ConvertFrom-Json
    if ($journal.state -notin @('complete', 'complete-with-retained-backup')) {
        throw "The worker journal requires review: $($journal.state)."
    }
    $status.state = $journal.state
    $status.retained_backup = $journal.backup
    $status.retained_staging = $journal.retained_staging
    $status.verified_files = $journal.hashed_files
    Save-MigrationStatus
    Disable-MigrationTask
    exit 0
}
catch {
    $status.state = 'needs-review'
    $status.error = $_.Exception.Message
    Save-MigrationStatus
    $status.error | Add-Content -LiteralPath $logPath
    Disable-MigrationTask
    exit 1
}
