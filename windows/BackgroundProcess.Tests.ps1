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

    function Invoke-BackgroundHostStdioProbe {
        param(
            [string]$Arguments,
            [string]$InputText
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:testHost
        $startInfo.Arguments = "--proxy-stdio $Arguments"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write($InputText)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(30000)) {
                Stop-Process -Id $process.Id
                throw 'The stdio background host probe timed out.'
            }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Stdout = $stdout.Result
                Stderr = $stderr.Result
            }
        }
        finally {
            $process.Dispose()
        }
    }

    function Invoke-BackgroundHostBinaryProbe {
        param(
            [string]$Arguments,
            [byte[]]$InputBytes
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:testHost
        $startInfo.Arguments = "--proxy-stdio $Arguments"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = New-Object System.IO.MemoryStream
        try {
            $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(30000)) {
                Stop-Process -Id $process.Id
                throw 'The binary stdio background host probe timed out.'
            }
            $stdoutCopy.Wait()
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Stdout = $stdout.ToArray()
                Stderr = $stderr.Result
            }
        }
        finally {
            $stdout.Dispose()
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

    It 'proxies stdin EOF, stdout, stderr and the child exit code without a console' {
        $probePath = Join-Path $TestDrive 'stdio probe.ps1'
        @'
$inputText = [Console]::In.ReadToEnd()
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbe {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
[Console]::Out.Write("out:" + $inputText)
[Console]::Error.Write("console:" + [ConsoleProbe]::GetConsoleWindow().ToInt64())
exit 37
'@ | Set-Content -LiteralPath $probePath
        $arguments = '"{0}" -NoProfile -NonInteractive -File "{1}"' -f
            $script:powerShell, $probePath

        $result = Invoke-BackgroundHostStdioProbe -Arguments $arguments -InputText 'round trip'
        $result.ExitCode | Should Be 37
        $result.Stdout | Should Be 'out:round trip'
        $result.Stderr | Should Be 'console:0'
    }

    It 'proxies concurrent payloads larger than the pipe buffer without deadlock' {
        $probePath = Join-Path $TestDrive 'large stdio probe.ps1'
        @'
$inputText = [Console]::In.ReadToEnd()
[Console]::Out.Write($inputText)
[Console]::Error.Write(('e' * 1048576))
exit 41
'@ | Set-Content -LiteralPath $probePath
        $arguments = '"{0}" -NoProfile -NonInteractive -File "{1}"' -f
            $script:powerShell, $probePath
        $payload = 'i' * 2097152

        $result = Invoke-BackgroundHostStdioProbe -Arguments $arguments -InputText $payload
        $result.ExitCode | Should Be 41
        $result.Stdout.Length | Should Be $payload.Length
        $result.Stdout | Should Be $payload
        $result.Stderr.Length | Should Be 1048576
        $result.Stderr[0] | Should Be 'e'
        $result.Stderr[$result.Stderr.Length - 1] | Should Be 'e'
    }

    It 'proxies raw binary bytes without text encoding or newline changes' {
        $probePath = Join-Path $TestDrive 'binary stdio probe.ps1'
        @'
$inputStream = [Console]::OpenStandardInput()
$outputStream = [Console]::OpenStandardOutput()
$buffer = New-Object byte[] 4096
while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    for ($index = 0; $index -lt $count; $index++) {
        $buffer[$index] = $buffer[$index] -bxor 0xA5
    }
    $outputStream.Write($buffer, 0, $count)
}
$outputStream.Flush()
exit 43
'@ | Set-Content -LiteralPath $probePath
        $arguments = '"{0}" -NoProfile -NonInteractive -File "{1}"' -f
            $script:powerShell, $probePath
        [byte[]]$payload = 0, 1, 2, 10, 13, 127, 128, 254, 255
        [byte[]]$expected = $payload | ForEach-Object { $_ -bxor 0xA5 }

        $result = Invoke-BackgroundHostBinaryProbe -Arguments $arguments -InputBytes $payload
        $result.ExitCode | Should Be 43
        [Convert]::ToBase64String($result.Stdout) | Should Be ([Convert]::ToBase64String($expected))
        $result.Stderr | Should Be ''
    }

    It 'requires a command after the opt-in stdio flag' {
        Invoke-BackgroundHostProbe -Arguments '--proxy-stdio' | Should Be 64
    }
}
