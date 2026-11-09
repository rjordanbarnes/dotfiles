[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 365)]
    [int]$ImageAgeDays = 30,

    [string]$StateDirectory = (Join-Path $HOME '.local\state\docker-maintenance')
)

function Test-GitHubRunnerJobActive {
    $workers = @(Get-Process -ErrorAction Stop | Where-Object {
        $_.ProcessName -eq 'Runner.Worker'
    })
    return $workers.Count -gt 0
}

function Invoke-DockerMaintenanceCli {
    param([string[]]$Arguments)

    $docker = Get-Command docker.exe -CommandType Application -ErrorAction Stop
    $output = @(& $docker.Source --context desktop-linux @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
    return ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
}

function Invoke-DockerMaintenance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(1, 365)]
        [int]$ImageAgeDays = 30,

        [string]$StateDirectory = (Join-Path $HOME '.local\state\docker-maintenance')
    )

    $ErrorActionPreference = 'Stop'
    $result = [ordered]@{
        started_at = [DateTimeOffset]::UtcNow.ToString('o')
        finished_at = $null
        status = 'skipped'
        reason = $null
        image_age_days = $ImageAgeDays
        output = $null
    }

    try {
        if (Test-GitHubRunnerJobActive) {
            $result.reason = 'runner-job-active'
            return $result
        }

        try {
            $endpoint = Invoke-DockerMaintenanceCli -Arguments @(
                'context', 'inspect', 'desktop-linux', '--format', '{{.Endpoints.docker.Host}}'
            )
        }
        catch {
            $result.reason = 'docker-context-unavailable'
            return $result
        }

        if ($endpoint.Trim() -ne 'npipe:////./pipe/dockerDesktopLinuxEngine') {
            $result.reason = 'nonlocal-docker-context'
            return $result
        }

        try {
            Invoke-DockerMaintenanceCli -Arguments @('info', '--format', '{{.ServerVersion}}') | Out-Null
        }
        catch {
            $result.reason = 'docker-not-running'
            return $result
        }

        if (Test-GitHubRunnerJobActive) {
            $result.reason = 'runner-job-started'
            return $result
        }

        if (-not $PSCmdlet.ShouldProcess(
            'Local Docker Desktop',
            "Remove untagged, unused images created more than $ImageAgeDays days ago"
        )) {
            $result.status = 'preview'
            $result.reason = 'no-images-removed'
            return $result
        }

        # Deliberately omit --all and every cache/container/volume prune command.
        $output = Invoke-DockerMaintenanceCli -Arguments @(
            'image', 'prune', '--force', '--filter', "until=$($ImageAgeDays * 24)h"
        )
        $result.output = (($output -split '\r?\n') | Select-Object -Last 100) -join [Environment]::NewLine
        $result.status = 'completed'
        $result.reason = 'old-untagged-images-pruned'
        return $result
    }
    catch {
        $result.status = 'failed'
        $result.reason = 'maintenance-error'
        $result.output = $_.Exception.Message.Substring(0, [Math]::Min(2000, $_.Exception.Message.Length))
        return $result
    }
    finally {
        $result.finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        [IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
        $name = if ($WhatIfPreference) { 'last-preview.json' } else { 'last-run.json' }
        $report = Join-Path $StateDirectory $name
        [IO.File]::WriteAllText(
            $report,
            ($result | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DockerMaintenance @PSBoundParameters
    $result | ConvertTo-Json -Depth 4
    if ($result.status -eq 'failed') {
        exit 1
    }
}
