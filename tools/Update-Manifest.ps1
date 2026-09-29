<#
.SYNOPSIS
    Records every book in the download folder in manifest.csv, checks each file, and rebuilds set-done.js.

.DESCRIPTION
    manifest.csv is kept inside the library folder, so it travels with every copy and backup
    (see docs/design-manifest-and-rename.md, Part 1). Each run adds new files, re-checks files whose
    size or date changed, and marks files that have gone as missing. A run with no changes rewrites nothing.

    Every file is hashed (SHA-256) and checked:
      - PDF: starts with %PDF- and has an end marker (%%EOF) near the end, so truncated files are caught.
      - EPUB: a zip whose first entry is "mimetype" containing application/epub+zip, with a package (.opf) file.
      - The ISBN in the file name has a correct check digit.
    Files that fail are marked valid=false and left out of set-done.js, so the next run downloads them again.

    Titles, publication dates and categories come from packt-library.json (saved by the dry run) when it is
    in the folder; otherwise the title is read from the EPUB. Only files named <ISBN>.pdf / <ISBN>.epub
    (optionally with " (1)" etc.) are counted.

.EXAMPLE
    .\tools\Update-Manifest.ps1

.EXAMPLE
    .\tools\Update-Manifest.ps1 -Folder "E:\Backup\PacktPub" -SetDoneFile "$env:TEMP\set-done.js"
#>
param(
    [string]$Folder = (Join-Path $env:USERPROFILE 'Downloads\PacktPub'),
    [string]$Library,  # packt-library.json; default: the newest packt-library*.json in the folder
    [string]$SetDoneFile = (Join-Path $PSScriptRoot '..\browser\set-done.js')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$manifestPath = Join-Path $Folder 'manifest.csv'
$namePattern = '^(97[89]\d{10})(?: \(\d+\))?\.(pdf|epub)$'
$columns = 'isbn', 'format', 'title', 'file', 'bytes', 'sha256', 'valid', 'problem', 'status', 'added', 'modified', 'published', 'category'

function Test-IsbnCheckDigit([string]$Isbn) {
    $sum = 0
    for ($i = 0; $i -lt 12; $i++) { $sum += [int][string]$Isbn[$i] * (1 + 2 * ($i % 2)) }
    return (10 - $sum % 10) % 10 -eq [int][string]$Isbn[12]
}

function Read-ZipText($Entry) {
    $reader = New-Object IO.StreamReader($Entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

# Returns @{ problem = '' or a description; title = the EPUB's own title, if any }
function Test-BookFile([IO.FileInfo]$File, [string]$Format) {
    if ($Format -eq 'pdf') {
        $s = [IO.File]::OpenRead($File.FullName)
        try {
            $head = New-Object byte[] 5
            [void]$s.Read($head, 0, 5)
            if ([Text.Encoding]::ASCII.GetString($head) -ne '%PDF-') { return @{ problem = 'not a PDF' } }
            $n = [int][Math]::Min(4096, $s.Length)
            [void]$s.Seek(-$n, 'End')
            $tail = New-Object byte[] $n
            [void]$s.Read($tail, 0, $n)
            if ([Text.Encoding]::ASCII.GetString($tail) -notmatch '%%EOF') { return @{ problem = 'PDF has no end marker (truncated?)' } }
        } finally { $s.Dispose() }
        return @{ problem = '' }
    }

    try { $zip = [IO.Compression.ZipFile]::OpenRead($File.FullName) } catch { return @{ problem = 'not a zip file' } }
    try {
        $first = $zip.Entries | Select-Object -First 1
        if (-not $first -or $first.FullName -ne 'mimetype' -or (Read-ZipText $first).Trim() -ne 'application/epub+zip') {
            return @{ problem = 'not an EPUB (no mimetype entry)' }
        }
        $opf = $zip.Entries | Where-Object FullName -like '*.opf' | Select-Object -First 1
        if (-not $opf) { return @{ problem = 'EPUB has no package (.opf) file' } }
        $m = [regex]::Match((Read-ZipText $opf), '<dc:title[^>]*>([^<]*)</dc:title>')
        return @{ problem = ''; title = ([Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -replace '\s+', ' ').Trim() }
    } catch {
        return @{ problem = "damaged EPUB ($($_.Exception.Message))" }
    } finally { $zip.Dispose() }
}

# The book list's fields may be text, a date, a list, or an object with a name.
function ConvertTo-Text($Value) {
    if ($null -eq $Value) { return '' }
    # Dates are kept as yyyy-MM-dd. The site's are midnight UTC; PowerShell 7 turns them into local dates.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    if ($Value -is [string]) { return $Value -replace '^(\d{4}-\d{2}-\d{2})T[\d:.]+Z$', '$1' }
    if ($Value -is [array]) { return (@($Value | ForEach-Object { ConvertTo-Text $_ }) -join '; ') }
    foreach ($p in 'name', 'title', 'label') { if ($Value.PSObject.Properties[$p]) { return [string]$Value.$p } }
    return [string]$Value
}

# ---- Inputs: the previous manifest and the dry run's library list --------------------------------
$old = @{}
if (Test-Path -LiteralPath $manifestPath) {
    foreach ($r in Import-Csv -LiteralPath $manifestPath) { $old[$r.file] = $r }
}

if (-not $Library) {
    $Library = Get-ChildItem -LiteralPath $Folder -Filter 'packt-library*.json' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$lib = @{}       # isbn -> title record
$expected = @{}  # "isbn:format" -> title, for every PDF/EPUB the site offers
if ($Library) {
    $json = Get-Content -LiteralPath $Library -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in $json.titles) {
        $lib[[string]$t.isbn] = $t
        if ($t.files) {
            foreach ($p in $t.files.PSObject.Properties) {
                if ($p.Name -in 'pdf', 'epub' -and $p.Value) { $expected["$($t.isbn):$($p.Name)"] = $t.title }
            }
        }
    }
    Write-Host "Library list: $Library ($($lib.Count) titles)"
} else {
    Write-Host 'No packt-library.json in the folder: titles come from the EPUBs, and missing downloads cannot be listed.'
}

# ---- Scan the folder -----------------------------------------------------------------------------
$files = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object Name -match $namePattern)
$now = (Get-Date).ToString('s')
$rows = New-Object Collections.Generic.List[object]
$checkedCount = 0
for ($i = 0; $i -lt $files.Count; $i++) {
    $f = $files[$i]
    Write-Progress -Activity 'Checking library files' -Status $f.Name -PercentComplete (100 * $i / $files.Count)
    $null = $f.Name -match $namePattern
    $isbn = $Matches[1]; $format = $Matches[2]
    $modified = $f.LastWriteTimeUtc.ToString('s') + 'Z'
    $prev = $old[$f.Name]

    if ($prev -and $prev.status -eq 'present' -and $prev.bytes -eq [string]$f.Length -and $prev.modified -eq $modified) {
        $row = $prev  # unchanged since the last run: keep its hash and check result
    } else {
        $checkedCount++
        $check = Test-BookFile $f $format
        $problems = @($check.problem)
        if (-not (Test-IsbnCheckDigit $isbn)) { $problems += 'ISBN check digit is wrong' }
        $problem = ($problems | Where-Object { $_ }) -join '; '
        $row = [pscustomobject]@{
            isbn = $isbn; format = $format; title = $check.title; file = $f.Name; bytes = [string]$f.Length
            sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
            valid = ([string](-not $problem)).ToLower(); problem = $problem; status = 'present'
            added = $(if ($prev) { $prev.added } else { $now }); modified = $modified; published = ''; category = ''
        }
        if (-not $row.title -and $prev) { $row.title = $prev.title }
    }
    $rows.Add($row)
}
Write-Progress -Activity 'Checking library files' -Completed

# Files recorded before but no longer in the folder stay in the manifest, marked missing.
$present = @{}; foreach ($f in $files) { $present[$f.Name] = $true }
foreach ($r in $old.Values) {
    if (-not $present[$r.file]) { $r.status = 'missing'; $rows.Add($r) }
}

# Titles and details: the library list first, then an EPUB title shared with the PDF of the same book.
$epubTitle = @{}
foreach ($r in $rows) { if ($r.title -and -not $epubTitle[$r.isbn]) { $epubTitle[$r.isbn] = $r.title } }
foreach ($r in $rows) {
    $t = $lib[$r.isbn]
    if ($t) {
        $r.title = $t.title
        $r.published = ConvertTo-Text $t.product.publicationDate
        $r.category = ConvertTo-Text $t.product.category
    } elseif (-not $r.title) {
        $r.title = [string]$epubTitle[$r.isbn]
    }
}

# ---- Write manifest.csv (only if something changed) ----------------------------------------------
$csv = @($rows | Sort-Object isbn, format, file | Select-Object $columns | ConvertTo-Csv -NoTypeInformation)
$existing = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 } else { '' }
if (($existing -replace '\r\n', "`n").TrimEnd() -ne (($csv -join "`n") -replace '\r\n', "`n")) {
    # With a byte-order mark, so Excel reads titles with accents and dashes correctly
    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    Set-Content -LiteralPath $manifestPath -Value $csv -Encoding $encoding
    Write-Host "Updated $manifestPath"
} else {
    Write-Host "No changes: $manifestPath"
}

# ---- set-done.js: only files that are present and valid ------------------------------------------
$good = @($rows | Where-Object { $_.status -eq 'present' -and $_.valid -eq 'true' })
$doneKeys = @($good | ForEach-Object { "$($_.isbn):$($_.format)" } | Sort-Object -Unique)
$line = "localStorage.setItem('packtDownloaderDone', JSON.stringify([$(($doneKeys | ForEach-Object { '"' + $_ + '"' }) -join ',')]));"
Set-Content -LiteralPath $SetDoneFile -Value $line -Encoding utf8

# ---- Summary -------------------------------------------------------------------------------------
$bad = @($rows | Where-Object { $_.status -eq 'present' -and $_.valid -ne 'true' })
$gone = @($rows | Where-Object status -eq 'missing')
$dupes = @($rows | Where-Object status -eq 'present' | Group-Object sha256 | Where-Object Count -gt 1)
$notDownloaded = @($expected.Keys | Where-Object { $doneKeys -notcontains $_ } | Sort-Object)

Write-Host ''
Write-Host "$($files.Count) book files ($checkedCount checked this run, the rest unchanged); $($good.Count) valid."
if ($bad) {
    Write-Warning "$($bad.Count) files failed the check (left out of set-done.js, so they will be downloaded again):"
    $bad | Format-Table file, problem -AutoSize | Out-Host
}
if ($gone) {
    Write-Warning "$($gone.Count) files in the manifest are no longer in the folder:"
    $gone | Format-Table file, title -AutoSize | Out-Host
}
if ($dupes) {
    Write-Host "$($dupes.Count) sets of identical files (the extra copies are safe to delete):"
    $dupes | ForEach-Object { '  ' + (($_.Group.file | Sort-Object) -join ' = ') } | Out-Host
}
if ($Library) {
    if ($notDownloaded) {
        Write-Host "$($notDownloaded.Count) files the site offers are not downloaded yet:"
        $notDownloaded | ForEach-Object { '  {0}  {1}' -f $_, $expected[$_] } | Out-Host
    } else {
        Write-Host 'Every PDF and EPUB the site offers is downloaded.'
    }
}
Write-Host "$($doneKeys.Count) files recorded in $SetDoneFile"
