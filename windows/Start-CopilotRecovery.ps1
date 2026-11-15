[CmdletBinding()]
param(
    [switch]$PrepareOnly,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArguments
)

$ErrorActionPreference = 'Stop'
$profile = Join-Path $env:LOCALAPPDATA 'Copilot\ProfileRecovery'
$canonical = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\copilot\copilot-instructions.md'))
$instructions = Join-Path $profile 'copilot-instructions.md'
if (-not (Test-Path -LiteralPath $profile)) {
    [IO.Directory]::CreateDirectory($profile) | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        ))
    }
    Set-Acl -LiteralPath $profile -AclObject $acl
}
if ((Get-Item -LiteralPath $profile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'The recovery profile is redirected. Preserve it and inspect the recovery guide.'
}
if (-not (Test-Path -LiteralPath $instructions)) {
    New-Item -ItemType HardLink -Path $instructions -Target $canonical | Out-Null
}
if ((Get-FileHash -LiteralPath $instructions).Hash -ne (Get-FileHash -LiteralPath $canonical).Hash) {
    throw 'The recovery instructions differ from the canonical file. Inspect them before starting.'
}
if ($PrepareOnly) {
    $profile
    return
}

$previousHome = $env:COPILOT_HOME
try {
    $env:COPILOT_HOME = $profile
    Write-Host 'Starting a separate C:-based recovery profile. The Windows setting and original profile are unchanged.'
    Write-Host "Recovery guide: $(Join-Path $PSScriptRoot '..\copilot\profile-recovery.md')"
    & copilot @CopilotArguments
}
finally {
    $env:COPILOT_HOME = $previousHome
}
