BeforeAll {
    . (Join-Path $PSScriptRoot 'Library.Helpers.ps1')
    $script:tool = Join-Path $PSScriptRoot '..\tools\Update-Manifest.ps1'

    # Valid ISBN-13s (the check digit is right), and one with a wrong check digit.
    $script:isbnA = '9781803231679'
    $script:isbnB = '9781785888564'
    $script:isbnC = '9781839212345'
    $script:badIsbn = '9781803231670'

    # Runs the tool on the test folder and returns what it wrote.
    function Invoke-Tool {
        & $script:tool -Folder $script:folder -SetDoneFile $script:setDone
        [pscustomobject]@{
            Rows    = @(Import-Csv -LiteralPath (Join-Path $script:folder 'manifest.csv'))
            SetDone = Get-Content -LiteralPath $script:setDone -Raw
        }
    }
    function Get-Row($Result, [string]$File) { $Result.Rows | Where-Object file -eq $File }
}

Describe 'Update-Manifest.ps1' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $script:folder
        $script:setDone = Join-Path $script:folder 'set-done.js'
        # The tool reports to the screen; keep the test output quiet.
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Write-Progress { }
        Mock Out-Host { }
    }

    Context 'recording files' {
        It 'records a complete PDF and EPUB as valid, with size and SHA-256' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            New-TestEpub (Join-Path $folder "$isbnA.epub")

            $result = Invoke-Tool

            $result.Rows.Count | Should -Be 2
            $pdf = Get-Row $result "$isbnA.pdf"
            $pdf.isbn | Should -Be $isbnA
            $pdf.format | Should -Be 'pdf'
            $pdf.valid | Should -Be 'true'
            $pdf.status | Should -Be 'present'
            $pdf.bytes | Should -Be (Get-Item (Join-Path $folder "$isbnA.pdf")).Length
            $pdf.sha256 | Should -Be (Get-FileHash (Join-Path $folder "$isbnA.pdf") -Algorithm SHA256).Hash.ToLower()
            (Get-Row $result "$isbnA.epub").valid | Should -Be 'true'
        }

        It 'records a MOBI as valid' {
            New-TestMobi (Join-Path $folder "$isbnA.mobi")

            (Get-Row (Invoke-Tool) "$isbnA.mobi").valid | Should -Be 'true'
        }

        It 'ignores files that are not named by ISBN' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            New-TestPdf (Join-Path $folder 'Some Other Book.pdf')
            Set-Content -LiteralPath (Join-Path $folder 'notes.txt') -Value 'not a book'

            (Invoke-Tool).Rows.file | Should -Be "$isbnA.pdf"
        }

        It 'records a second copy named "(1)" under the same ISBN' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            New-TestPdf (Join-Path $folder "$isbnA (1).pdf")

            $result = Invoke-Tool

            $result.Rows.Count | Should -Be 2
            $result.Rows.isbn | Select-Object -Unique | Should -Be $isbnA
        }
    }

    Context 'catching bad files' {
        It 'marks a cut-off PDF as not valid' {
            New-CutOffPdf (Join-Path $folder "$isbnA.pdf")

            $row = Get-Row (Invoke-Tool) "$isbnA.pdf"

            $row.valid | Should -Be 'false'
            $row.problem | Should -BeLike '*no end marker*'
        }

        It 'marks a web page saved under a PDF name as not valid' {
            Set-Content -LiteralPath (Join-Path $folder "$isbnA.pdf") -Value '<html><title>Just a moment...</title></html>'

            $row = Get-Row (Invoke-Tool) "$isbnA.pdf"

            $row.valid | Should -Be 'false'
            $row.problem | Should -Be 'not a PDF'
        }

        It 'marks a web page saved under an EPUB name as not valid' {
            Set-Content -LiteralPath (Join-Path $folder "$isbnA.epub") -Value '<html><title>Just a moment...</title></html>'

            $row = Get-Row (Invoke-Tool) "$isbnA.epub"

            $row.valid | Should -Be 'false'
            $row.problem | Should -Be 'not a zip file'
        }

        It 'marks a zip that is not an EPUB as not valid' {
            New-TestZip (Join-Path $folder "$isbnA.epub") ([ordered]@{ 'readme.txt' = 'code samples' })

            (Get-Row (Invoke-Tool) "$isbnA.epub").problem | Should -BeLike 'not an EPUB*'
        }

        It 'marks an EPUB without a package file as not valid' {
            New-TestZip (Join-Path $folder "$isbnA.epub") ([ordered]@{ 'mimetype' = 'application/epub+zip' })

            (Get-Row (Invoke-Tool) "$isbnA.epub").problem | Should -BeLike '*no package*'
        }

        It 'marks a file that is not a MOBI as not valid' {
            Set-Content -LiteralPath (Join-Path $folder "$isbnA.mobi") -Value 'too short to be a book'

            (Get-Row (Invoke-Tool) "$isbnA.mobi").problem | Should -Be 'not a MOBI'
        }

        It 'marks a file whose ISBN has a wrong check digit as not valid' {
            New-TestPdf (Join-Path $folder "$badIsbn.pdf")

            $row = Get-Row (Invoke-Tool) "$badIsbn.pdf"

            $row.valid | Should -Be 'false'
            $row.problem | Should -Be 'ISBN check digit is wrong'
        }
    }

    Context 'titles and details' {
        It 'takes the title from the EPUB, and gives it to the PDF of the same book' {
            New-TestEpub (Join-Path $folder "$isbnA.epub") -Title 'Learn Testing &amp; More'
            New-TestPdf (Join-Path $folder "$isbnA.pdf")

            $result = Invoke-Tool

            (Get-Row $result "$isbnA.epub").title | Should -Be 'Learn Testing & More'
            (Get-Row $result "$isbnA.pdf").title | Should -Be 'Learn Testing & More'
        }

        It 'prefers the title, publication date and category from packt-library.json' {
            New-TestEpub (Join-Path $folder "$isbnA.epub") -Title 'Title Inside the EPUB'
            New-TestLibraryList (Join-Path $folder 'packt-library.json') @(
                @{
                    isbn = $isbnA; title = 'Learn Testing - Second Edition'; files = @{ epub = "/download/$isbnA/epub" }
                    product = @{ publicationDate = '2021-03-05T00:00:00.000Z'; category = 'Programming' }
                }
            )

            $row = Get-Row (Invoke-Tool) "$isbnA.epub"

            $row.title | Should -Be 'Learn Testing - Second Edition'
            $row.published | Should -Be '2021-03-05'
            $row.category | Should -Be 'Programming'
        }
    }

    Context 'running again' {
        It 'rewrites nothing when nothing changed' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            $null = Invoke-Tool
            $manifest = Join-Path $folder 'manifest.csv'
            $before = Get-Content -LiteralPath $manifest -Raw
            (Get-Item $manifest).LastWriteTimeUtc = '2020-01-01'

            $null = Invoke-Tool

            Get-Content -LiteralPath $manifest -Raw | Should -Be $before
            (Get-Item $manifest).LastWriteTimeUtc.Year | Should -Be 2020
        }

        It 'checks a file again when it has changed, keeping when it was first added' {
            $path = Join-Path $folder "$isbnA.pdf"
            New-CutOffPdf $path
            $first = Get-Row (Invoke-Tool) "$isbnA.pdf"
            New-TestPdf $path -Text 'downloaded again, complete this time'

            $second = Get-Row (Invoke-Tool) "$isbnA.pdf"

            $first.valid | Should -Be 'false'
            $second.valid | Should -Be 'true'
            $second.sha256 | Should -Not -Be $first.sha256
            $second.added | Should -Be $first.added
        }

        It 'keeps a file that has gone from the folder, marked missing' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            New-TestPdf (Join-Path $folder "$isbnB.pdf")
            $null = Invoke-Tool
            Remove-Item -LiteralPath (Join-Path $folder "$isbnB.pdf")

            $result = Invoke-Tool

            (Get-Row $result "$isbnA.pdf").status | Should -Be 'present'
            (Get-Row $result "$isbnB.pdf").status | Should -Be 'missing'
        }
    }

    Context 'set-done.js, the record the browser script resumes from' {
        It 'lists valid files only, so bad ones are downloaded again' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            New-TestEpub (Join-Path $folder "$isbnA.epub")
            New-CutOffPdf (Join-Path $folder "$isbnB.pdf")

            $result = Invoke-Tool

            $expected = 'localStorage.setItem(''packtDownloaderDone'', JSON.stringify(["{0}:epub","{0}:pdf"]));' -f $isbnA
            $result.SetDone.Trim() | Should -Be $expected
        }

        It 'leaves out a file that has gone missing' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            $null = Invoke-Tool
            Remove-Item -LiteralPath (Join-Path $folder "$isbnA.pdf")

            (Invoke-Tool).SetDone | Should -Not -BeLike "*$isbnA*"
        }

        It 'includes files listed in skip.txt, so the downloader stops retrying them' {
            New-TestPdf (Join-Path $folder "$isbnA.pdf")
            Set-Content -LiteralPath (Join-Path $folder 'skip.txt') -Value @(
                '# files decided against'
                "${isbnA}:epub  blocked by antivirus every time"
                "${isbnC}:mobi  not wanted"
                'not a valid line'
            )

            $result = Invoke-Tool

            $result.SetDone | Should -BeLike ('*"{0}:epub"*' -f $isbnA)
            $result.SetDone | Should -BeLike ('*"{0}:mobi"*' -f $isbnC)
            $result.SetDone | Should -BeLike ('*"{0}:pdf"*' -f $isbnA)
            $result.Rows.Count | Should -Be 1  # skipped files are not rows: they are not on disk
        }
    }
}
