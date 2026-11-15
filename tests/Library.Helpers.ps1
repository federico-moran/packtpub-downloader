# Made-up library files for the tests: small files with the structure the tools check for. No real books.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-TestPdf([string]$Path, [string]$Text = 'a made-up book') {
    [IO.File]::WriteAllText($Path, "%PDF-1.7`n$Text`n%%EOF`n")
}

# A PDF that was cut off: it starts like one but has no end marker.
function New-CutOffPdf([string]$Path) {
    [IO.File]::WriteAllText($Path, "%PDF-1.7`nthe download stopped here")
}

# A zip with the given entries, in order: an ordered dictionary of entry name -> text.
function New-TestZip([string]$Path, [Collections.IDictionary]$Entries) {
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Entries.Keys) {
            $writer = New-Object IO.StreamWriter($zip.CreateEntry($name).Open())
            try { $writer.Write($Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function New-TestEpub([string]$Path, [string]$Title = 'A Made-up Book') {
    New-TestZip $Path ([ordered]@{
        'mimetype'          = 'application/epub+zip'
        'OEBPS/content.opf' = "<package><metadata><dc:title>$Title</dc:title></metadata></package>"
    })
}

function New-TestMobi([string]$Path) {
    $bytes = New-Object byte[] 100
    [Text.Encoding]::ASCII.GetBytes('BOOKMOBI').CopyTo($bytes, 60)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

# The dry run's packt-library.json, with the given titles: objects with isbn, title, files, product.
function New-TestLibraryList([string]$Path, [object[]]$Titles) {
    @{ generated = '2026-09-27T00:00:00.000Z'; titles = $Titles; externalLinks = @() } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
}
