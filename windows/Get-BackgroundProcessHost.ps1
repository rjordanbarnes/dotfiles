$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'BackgroundProcess.cs'
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$cachePath = Join-Path $env:LOCALAPPDATA "Copilot\BackgroundProcess\$sourceHash"
$hostPath = Join-Path $cachePath 'BackgroundProcess.exe'

if (-not (Test-Path -LiteralPath $hostPath)) {
    $compilerPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compilerPath)) {
        $compilerPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compilerPath)) {
        throw 'The Windows .NET Framework C# compiler was not found.'
    }

    [System.IO.Directory]::CreateDirectory($cachePath) | Out-Null
    $buildPath = Join-Path $cachePath ("build-$([guid]::NewGuid().ToString('N')).exe")
    try {
        $compilerOutput = & $compilerPath /nologo /target:winexe /optimize+ "/out:$buildPath" $sourcePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not compile the windowless host: $($compilerOutput -join [Environment]::NewLine)"
        }

        try {
            [System.IO.File]::Move($buildPath, $hostPath)
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $hostPath)) {
                throw
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $buildPath) {
            Remove-Item -LiteralPath $buildPath
        }
    }
}

$hostPath
