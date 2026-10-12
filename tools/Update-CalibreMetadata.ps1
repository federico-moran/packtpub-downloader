<#
.SYNOPSIS
    Corrects the details of PacktPub books in a Calibre library from manifest.csv and packt-library.json.

.DESCRIPTION
    Calibre takes a book's title and authors from inside the EPUB, and Packt's EPUBs are inconsistent:
    most have no ISBN, editions are left out of titles (so first and second editions look like duplicates),
    and some titles have broken characters. This script sets, from Packt's own records:
      - title (as on the site, e.g. "Mastering OpenStack - Second Edition")
      - authors (only when the site lists them)
      - ISBN, publication date and publisher
      - the Packt category and "PacktPub" (-SourceTag) as tags
    Existing tags are kept, apart from bookstore subject codes (BISAC, e.g. "COM053000 - COMPUTERS / Security /
    General") that Calibre read from the EPUB: they are removed.

    Each Calibre book is matched to the library folder by the SHA-256 hash of its EPUB, as recorded in
    manifest.csv (run Update-Manifest.ps1 first). A book whose file has changed is matched by the ISBN
    Calibre already has for it instead. Books that match neither (for example Calibre's own Quick Start
    Guide) are left alone and listed.

    Only fields that differ are changed, so a second run changes nothing. Before changing anything,
    metadata.db is copied to metadata.db.<date>.bak in the Calibre library. Calibre must be closed.
    Use -WhatIf to see the changes without making them.

.EXAMPLE
    .\tools\Update-CalibreMetadata.ps1 -Folder "$env:USERPROFILE\OneDrive\Documents\PacktPub" -WhatIf

.EXAMPLE
    .\tools\Update-CalibreMetadata.ps1 -Folder "$env:USERPROFILE\OneDrive\Documents\PacktPub" -CalibreLibrary 'D:\Calibre'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Join-Path $env:USERPROFILE 'OneDrive\Documents\PacktPub'),
    [string]$CalibreLibrary,  # default: the library Calibre last used
    [string]$Library,         # packt-library.json; default: the newest packt-library*.json in the folder
    [string]$Publisher = 'Packt Publishing',
    [string]$SourceTag = 'PacktPub',  # where the books came from, as a tag ('' for none)
    [string]$CalibreDb = (Join-Path $env:ProgramFiles 'Calibre2\calibredb.exe')
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8  # calibredb prints UTF-8

if (-not (Test-Path -LiteralPath $CalibreDb)) { throw "calibredb not found at $CalibreDb (use -CalibreDb)." }
if (Get-Process -Name calibre -ErrorAction SilentlyContinue) { throw 'Close Calibre first: calibredb cannot change the library while it is open.' }
if (-not $CalibreLibrary) {
    $settings = Join-Path $env:APPDATA 'calibre\global.py.json'
    if (Test-Path -LiteralPath $settings) { $CalibreLibrary = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).library_path }
    if (-not $CalibreLibrary) { throw 'Could not find the Calibre library (use -CalibreLibrary).' }
}

# Calibre dates look like 2017-04-25T07:35:45+00:00; PowerShell may have turned them into dates.
function Get-DatePart($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    return ([string]$Value) -replace 'T.*$', ''
}

# Packt's title, tidied; '' when it is no better than Calibre's. Packt's records have doubled spaces,
# doubled editions ("... Second Edition - Second Edition") and "?" where a curly quote or dash was lost.
function Get-BetterTitle([string]$Packt, [string]$Current) {
    $t = ($Packt -replace '\s+', ' ').Trim() -replace '^(.*\b(\w+) Edition\)?) - \2 Edition$', '$1'
    if (-not $t -or $t.Contains('?')) { return '' }
    $key = { param($s) ($s.ToLowerInvariant() -replace '[^\p{L}\p{N}]', '') }
    if ((& $key $t) -eq (& $key $Current)) { return '' }  # only case or punctuation differs: keep Calibre's
    return $t
}

# Packt's authors when they add something: Calibre has a placeholder, a comma-joined list it read as
# one name, or fewer names. Otherwise the EPUB's own names are kept (Packt's are sometimes surname only).
function Get-BetterAuthors([string]$Packt, [string]$Current) {
    if (-not $Packt -or $Current -ceq $Packt) { return '' }
    if ($Current -match '^\s*(Unknown|Packt.*)?\s*$' -or $Current.Contains(',')) { return $Packt }
    if (@($Packt -split ' & ').Count -gt @($Current -split ' & ').Count) { return $Packt }
    return ''
}

# ---- Packt's records: manifest.csv (hashes, titles, dates, categories) and authors from the dry run ----
$manifestPath = Join-Path $Folder 'manifest.csv'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No manifest.csv in $Folder (run Update-Manifest.ps1 first)." }
$byHash = @{}; $byIsbn = @{}; $sizes = @{}
foreach ($r in Import-Csv -LiteralPath $manifestPath) {
    if ($r.format -ne 'epub' -or $r.status -ne 'present') { continue }
    $byHash[$r.sha256] = $r
    $byIsbn[$r.isbn] = $r
    $sizes[[long]$r.bytes] = $true
}

if (-not $Library) {
    $Library = Get-ChildItem -LiteralPath $Folder -Filter 'packt-library*.json' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$authors = @{}  # isbn -> "A & B"
if ($Library) {
    foreach ($t in (Get-Content -LiteralPath $Library -Raw -Encoding UTF8 | ConvertFrom-Json).titles) {
        $names = @($t.product.linkAuthors | ForEach-Object { ([string]$_.author).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($names) { $authors[[string]$t.isbn] = $names -join ' & ' }
    }
} else {
    Write-Warning 'No packt-library.json in the folder: authors will not be changed.'
}

# ---- The Calibre library -----------------------------------------------------------------------------
$json = & $CalibreDb list --library-path $CalibreLibrary --fields 'title,authors,identifiers,formats,pubdate,publisher,tags' --for-machine
if ($LASTEXITCODE) { throw "calibredb list failed (exit code $LASTEXITCODE)." }
$books = @(($json -join "`n") | ConvertFrom-Json)
Write-Host "Calibre library: $CalibreLibrary ($($books.Count) books)"

# Bookstore subject codes (BISAC) that Calibre read from the EPUBs as tags, e.g. "COM053000 - COMPUTERS /
# Security / General", also bare ("COM051260") or misspelt. Fewer than half the books have them, and 125 of
# them swamped the tag browser, so they are dropped; the codes stay inside the EPUB files.
$bisac = '^\s*[A-Z]{3}\d{6}\b|^\s*COMPUTERS\s*/'
$removedTags = 0
$changes = New-Object Collections.Generic.List[object]
$unmatched = New-Object Collections.Generic.List[object]
$seen = @{}  # isbn -> Calibre ids, to report the same book added twice
for ($i = 0; $i -lt $books.Count; $i++) {
    $b = $books[$i]
    Write-Progress -Activity 'Matching Calibre books to the library folder' -Status $b.title -PercentComplete (100 * $i / $books.Count)
    $epub = @($b.formats) | Where-Object { $_ -like '*.epub' } | Select-Object -First 1
    $m = $null
    # Only files with the size of one of the library's EPUBs are hashed: the rest of Calibre (other stores' books) can't match.
    if ($epub -and (Test-Path -LiteralPath $epub) -and $sizes[(Get-Item -LiteralPath $epub).Length]) {
        $m = $byHash[(Get-FileHash -LiteralPath $epub -Algorithm SHA256).Hash.ToLower()]
    }
    if (-not $m -and $b.identifiers.isbn) { $m = $byIsbn[[string]$b.identifiers.isbn] }
    if (-not $m) { $unmatched.Add($b); continue }
    $seen[$m.isbn] = @($seen[$m.isbn]) + $b.id | Where-Object { $_ }

    $fields = [ordered]@{}
    $t = Get-BetterTitle $m.title $b.title
    if ($t) { $fields.title = $t }
    $a = Get-BetterAuthors $authors[$m.isbn] $b.authors
    if ($a) { $fields.authors = $a }
    if ($b.identifiers.isbn -ne $m.isbn) {
        $ids = @($b.identifiers.PSObject.Properties | Where-Object Name -ne 'isbn' | ForEach-Object { "$($_.Name):$($_.Value)" })
        $fields.identifiers = (@("isbn:$($m.isbn)") + $ids) -join ','
    }
    # Calibre moves the first and last day of a month one day inwards, so time zones can't change the month.
    $stored = Get-DatePart $b.pubdate
    if ($m.published -and $stored -ne $m.published) {
        $d = [datetime]::ParseExact($m.published, 'yyyy-MM-dd', $null)
        $shifted = if ($d.Day -eq 1) { $d.AddDays(1) } elseif ($d.AddDays(1).Day -eq 1) { $d.AddDays(-1) }
        if (-not $shifted -or $stored -ne $shifted.ToString('yyyy-MM-dd')) { $fields.pubdate = $m.published }
    }
    if ($Publisher -and $b.publisher -cne $Publisher) { $fields.publisher = $Publisher }
    $tags = @($b.tags | Where-Object { $_ })
    $keep = @($tags | Where-Object { $_ -notmatch $bisac })
    $removedTags += $tags.Count - $keep.Count
    $want = @($keep) + @($SourceTag, $m.category | Where-Object { $_ -and $keep -notcontains $_ })
    if (($want -join ',') -cne ($tags -join ',')) { $fields.tags = $want -join ',' }

    if ($fields.Count) {
        $changes.Add([pscustomobject]@{ id = $b.id; isbn = $m.isbn; was = $b.title; fields = $fields })
    }
}
Write-Progress -Activity 'Matching Calibre books to the library folder' -Completed

# ---- Apply -------------------------------------------------------------------------------------------
if ($changes.Count -and -not $WhatIfPreference) {
    $backup = Join-Path $CalibreLibrary ('metadata.db.{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath (Join-Path $CalibreLibrary 'metadata.db') -Destination $backup
    Write-Host "Backed up the Calibre database to $backup"
}
$done = 0; $failed = 0
for ($i = 0; $i -lt $changes.Count; $i++) {
    $c = $changes[$i]
    $summary = ($c.fields.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
    if (-not $PSCmdlet.ShouldProcess("#$($c.id) $($c.was)", "set $summary")) { continue }
    Write-Progress -Activity 'Updating Calibre' -Status $c.was -PercentComplete (100 * $i / $changes.Count)
    $fieldArgs = $c.fields.GetEnumerator() | ForEach-Object { '--field'; "$($_.Key):$($_.Value)" }
    $null = & $CalibreDb set_metadata --library-path $CalibreLibrary $c.id @fieldArgs
    if ($LASTEXITCODE) { Write-Warning "Could not update #$($c.id) $($c.was) (exit code $LASTEXITCODE)"; $failed++ } else { $done++ }
}
Write-Progress -Activity 'Updating Calibre' -Completed

# ---- Summary -----------------------------------------------------------------------------------------
Write-Host ''
$matched = $books.Count - $unmatched.Count
if ($WhatIfPreference) {
    Write-Host "$matched of $($books.Count) books matched; $($changes.Count) would be changed (nothing changed: -WhatIf)."
} else {
    Write-Host "$matched of $($books.Count) books matched; $done changed$(if ($failed) { ", $failed failed" }), the rest already correct."
}
if ($removedTags) { Write-Host "$removedTags subject-code tags $(if ($WhatIfPreference) { 'would be removed' } else { 'removed' })." }
if ($unmatched.Count) {
    # Calibre also holds other stores' books, so only those that look like Packt's are listed.
    $packtLike = @($unmatched | Where-Object publisher -like '*Packt*')
    Write-Host "$($unmatched.Count) Calibre books are not in the library folder's manifest (left alone)$(if ($packtLike) { "; $($packtLike.Count) of them published by Packt:" } else { '.' })"
    $packtLike | ForEach-Object { '  #{0}  {1}' -f $_.id, $_.title } | Out-Host
}
$twice = @($seen.GetEnumerator() | Where-Object { @($_.Value).Count -gt 1 })
if ($twice) {
    Write-Host "$($twice.Count) books are in Calibre more than once:"
    $twice | ForEach-Object { '  {0}  {1}: #{2}' -f $_.Key, $byIsbn[$_.Key].title, (@($_.Value) -join ', #') } | Out-Host
}
$missing = @($byIsbn.Keys | Where-Object { -not $seen[$_] } | Sort-Object)
if ($missing) {
    Write-Host "$($missing.Count) EPUBs in the library folder are not in Calibre:"
    $missing | ForEach-Object { '  {0}  {1}' -f $_, $byIsbn[$_].title } | Out-Host
}
