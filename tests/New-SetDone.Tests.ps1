BeforeAll {
    . (Join-Path $PSScriptRoot 'Library.Helpers.ps1')
    $script:tool = Join-Path $PSScriptRoot '..\tools\New-SetDone.ps1'
    $script:isbnA = '9781803231679'
    $script:isbnB = '9781785888564'
}

Describe 'New-SetDone.ps1' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $script:folder
        $script:outFile = Join-Path $script:folder 'set-done.js'
        Mock Write-Host { }
    }

    It 'records every file named by ISBN, as "isbn:format"' {
        New-TestPdf (Join-Path $folder "$isbnA.pdf")
        New-TestEpub (Join-Path $folder "$isbnA.epub")
        New-TestMobi (Join-Path $folder "$isbnB.mobi")

        & $tool -Folder $folder -OutFile $outFile

        $expected = 'localStorage.setItem(''packtDownloaderDone'', JSON.stringify(["{1}:mobi","{0}:epub","{0}:pdf"]));' -f $isbnA, $isbnB
        (Get-Content -LiteralPath $outFile -Raw).Trim() | Should -Be $expected
    }

    It 'counts a second copy named "(1)" once' {
        New-TestPdf (Join-Path $folder "$isbnA.pdf")
        New-TestPdf (Join-Path $folder "$isbnA (1).pdf")

        & $tool -Folder $folder -OutFile $outFile

        ([regex]::Matches((Get-Content -LiteralPath $outFile -Raw), "${isbnA}:pdf")).Count | Should -Be 1
    }

    It 'ignores unfinished downloads and files not named by ISBN' {
        New-TestPdf (Join-Path $folder "$isbnA.pdf")
        Set-Content -LiteralPath (Join-Path $folder "$isbnB.pdf.crdownload") -Value 'half a file'
        New-TestPdf (Join-Path $folder 'Some Other Book.pdf')

        & $tool -Folder $folder -OutFile $outFile

        $written = Get-Content -LiteralPath $outFile -Raw
        $written | Should -BeLike "*${isbnA}:pdf*"
        $written | Should -Not -BeLike "*$isbnB*"
        $written | Should -Not -BeLike '*Other*'
    }
}
