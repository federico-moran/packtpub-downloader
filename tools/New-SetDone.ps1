<#
.SYNOPSIS
    Rebuilds the downloader's "done" record from the files actually in your download folder.

.DESCRIPTION
    The browser script remembers which files it has started in localStorage. If that record drifts
    from reality (e.g. downloads were blocked by a human check), run this, then paste the generated
    browser/set-done.js into the Console on subscription.packtpub.com before re-running the downloader.
    Only files named <ISBN>.pdf / .epub / .mobi (optionally with " (1)" etc.) are counted.

.EXAMPLE
    .\tools\New-SetDone.ps1

.EXAMPLE
    .\tools\New-SetDone.ps1 -Folder "E:\Backup\PacktPub"
#>
param(
    [string]$Folder = (Join-Path $env:USERPROFILE 'OneDrive\Documents\PacktPub'),
    [string]$OutFile = (Join-Path $PSScriptRoot '..\browser\set-done.js')
)

$keys = Get-ChildItem -LiteralPath $Folder -File |
    Where-Object Name -match '^(97[89]\d{10})(?: \(\d+\))?\.(pdf|epub|mobi)$' |
    ForEach-Object { '"{0}:{1}"' -f $Matches[1], $Matches[2] } |
    Sort-Object -Unique

$line = "localStorage.setItem('packtDownloaderDone', JSON.stringify([$($keys -join ',')]));"
Set-Content -LiteralPath $OutFile -Value $line -Encoding utf8
Write-Host "$($keys.Count) files recorded in $OutFile"
