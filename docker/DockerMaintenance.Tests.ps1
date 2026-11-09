. (Join-Path $PSScriptRoot 'Invoke-DockerMaintenance.ps1')

Describe 'Runner-safe Docker maintenance' {
    BeforeEach {
        Mock Get-Process { @() }
        Mock Invoke-DockerMaintenanceCli {
            param($Arguments)
            if ($Arguments[0] -eq 'context') {
                return 'npipe:////./pipe/dockerDesktopLinuxEngine'
            }
            if ($Arguments[0] -eq 'info') {
                return '27.4.0'
            }
            return 'Total reclaimed space: 0B'
        }
    }

    It 'does not contact Docker while a runner job is active' {
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'Runner.Worker' } }
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.reason | Should Be 'runner-job-active'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It
    }

    It 'prunes only aged untagged images and preserves tagged images and CI cache' {
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.status | Should Be 'completed'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 1 -Exactly -Scope It -ParameterFilter {
            ($Arguments -join ' ') -eq 'image prune --force --filter until=720h'
        }
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It -ParameterFilter {
            $Arguments -contains '--all' -or
            $Arguments[0] -in @('builder', 'buildx', 'system', 'container', 'volume', 'desktop')
        }
    }

    It 'checks again for a runner job immediately before pruning' {
        $script:processChecks = 0
        Mock Get-Process {
            $script:processChecks++
            if ($script:processChecks -gt 1) {
                return [pscustomobject]@{ ProcessName = 'Runner.Worker' }
            }
            return @()
        }
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.reason | Should Be 'runner-job-started'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It -ParameterFilter {
            $Arguments[0] -eq 'image'
        }
    }

    It 'refuses a desktop context that points at another Docker host' {
        Mock Invoke-DockerMaintenanceCli { 'tcp://another-host:2376' }
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.reason | Should Be 'nonlocal-docker-context'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It -ParameterFilter {
            $Arguments[0] -ne 'context'
        }
    }

    It 'does not start Docker when the engine is unavailable' {
        Mock Invoke-DockerMaintenanceCli { throw 'Docker is stopped' } -ParameterFilter {
            $Arguments[0] -eq 'info'
        }
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.reason | Should Be 'docker-not-running'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It -ParameterFilter {
            $Arguments[0] -in @('image', 'desktop')
        }
    }

    It 'fails closed if runner process inspection fails' {
        Mock Get-Process { throw 'Process inspection unavailable' }
        $result = Invoke-DockerMaintenance -StateDirectory $TestDrive
        $result.status | Should Be 'failed'
        Assert-MockCalled Invoke-DockerMaintenanceCli -Times 0 -Exactly -Scope It
    }
}
