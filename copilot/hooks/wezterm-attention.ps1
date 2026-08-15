# Tracked in C:\code\dotfiles; commit and push changes there.
param(
    [Parameter(Mandatory)]
    [ValidateSet('notify', 'stop', 'review', 'work', 'clear')]
    [string]$State,

    [string]$TargetPaneId = $env:WEZTERM_PANE
)

$paneId = $TargetPaneId
if (-not $paneId -or $paneId -notmatch '^\d+$') {
    exit 0
}

$directory = Join-Path $HOME '.local\state\wezterm-attention'
$marker = Join-Path $directory $paneId

if ($State -eq 'clear') {
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    exit 0
}

if ($State -eq 'work') {
    try {
        $current = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    }
    catch {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        exit 0
    }

    if ($current.type -ne 'notify') {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($State -eq 'review') {
    try {
        $current = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    }
    catch {
        exit 0
    }

    if ($current.type -ne 'stop') {
        exit 0
    }
}

[IO.Directory]::CreateDirectory($directory) | Out-Null

$payload = @{
    type = $State
    updated_at_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
} | ConvertTo-Json -Compress

$temporary = "$marker.tmp"
[IO.File]::WriteAllText($temporary, $payload, [Text.UTF8Encoding]::new($false))
[IO.File]::Move($temporary, $marker, $true)
