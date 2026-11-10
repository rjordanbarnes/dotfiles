Describe 'Windowless background process host' {
    $cachedHost = & (Join-Path $PSScriptRoot 'Get-BackgroundProcessHost.ps1')
    $script:testHost = Join-Path $TestDrive 'BackgroundProcess.exe'
    Copy-Item -LiteralPath $cachedHost -Destination $script:testHost
    $script:powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Invoke-BackgroundHostProbe {
        param([string]$Arguments)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:testHost
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            if (-not $process.WaitForExit(15000)) {
                Stop-Process -Id $process.Id
                throw 'The background host probe timed out.'
            }
            return $process.ExitCode
        }
        finally {
            $process.Dispose()
        }
    }

    It 'creates no child console and preserves arguments and the exit code' {
        $probePath = Join-Path $TestDrive 'probe with spaces.ps1'
        $resultPath = Join-Path $TestDrive 'probe result.json'
        @'
param([string]$ResultPath, [string]$Payload, [string]$Empty)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
[pscustomobject]@{
    ConsoleHandle = [ConsoleProbe]::GetConsoleWindow().ToInt64()
    Payload = $Payload
    Empty = $Empty
} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
exit 23
'@ | Set-Content -LiteralPath $probePath
        $arguments = '"{0}" -NoProfile -NonInteractive -File "{1}" -ResultPath "{2}" -Payload "spaces and \"quotes\" and trailing\\" -Empty ""' -f
            $script:powerShell, $probePath, $resultPath

        Invoke-BackgroundHostProbe -Arguments $arguments | Should Be 23
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $result.ConsoleHandle | Should Be 0
        $result.Payload | Should Be 'spaces and "quotes" and trailing\'
        $result.Empty | Should Be ''
    }

    It 'reports launch failures without an interactive error dialog' {
        $missingProgram = Join-Path $TestDrive 'missing.exe'

        Invoke-BackgroundHostProbe -Arguments "`"$missingProgram`"" | Should Be 1
        Test-Path -LiteralPath (Join-Path $TestDrive 'launcher.log') | Should Be $true
    }

    It 'rejects a missing command instead of opening a shell' {
        Invoke-BackgroundHostProbe -Arguments '' | Should Be 64
    }
}
