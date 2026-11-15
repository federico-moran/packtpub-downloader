# Run log: my own library

Notes from running the tool on my own PacktPub library, oldest first. For the steps themselves, see the [playbook](playbook.md); for how the tool came to be, see [how-we-got-here.md](how-we-got-here.md).

## 2026-09-30: downloading finished

Downloading is finished apart from one title: **1,091 files (20.4 GB), all valid**, in `Downloads\PacktPub`, with `manifest.csv` and the dry run's `packt-library.json` (907 titles). Every manifest row has a title, publication date and category. Edge's settings are back to normal.

**Not on disk:**

- One book, PDF and EPUB: the links are broken on Packt's side (an error page every time, by script and by hand); only the **MOBI** works. Both are in `skip.txt`. `Update-Manifest.ps1` checks and records `.mobi` files too.
- Two security books, EPUB only: **Microsoft Defender blocks them** on every download (`Trojan:Win32/Bluteal!rfn` and `HackTool:Python/LaZagne.A!MTB`), matching attack code printed in one chapter of each. Almost certainly false positives, but allowing them would allow those detections machine-wide, so we **kept the PDFs instead**. Both are listed in `skip.txt` in the library folder, so `Update-Manifest.ps1` reports them as skipped and the downloader no longer retries them.

**Learned on this run:**

- The Retry/Skip pause worked against a real human check (2026-09-29).
- Edge asks once to allow "multiple automatic downloads" for the site: allow it.
- The browser record marks files when they *start*, so always rebuild it from disk (`Update-Manifest.ps1` or `New-SetDone.ps1`) before resuming.
- A download that "Couldn't download - Virus detected" in **Ctrl+J** is Defender, not the site: retrying won't help; check `Get-MpThreatDetection` for the detection name.
- For script retries, **`DELAY_MS = 20000`** worked where 5 s didn't: at 5 s the server throttled and about 70 downloads stalled; at 20 s every file arrived.

## 2026-10-09: moved to OneDrive, and into Calibre

The library folder has moved to `OneDrive\Documents\PacktPub`. The 546 EPUBs are in the Calibre library, and `Update-CalibreMetadata.ps1` has corrected their details: ISBN, date, publisher, category tag, and titles and authors where Packt's records are better. Not in Calibre: three titles that are PDF only on disk (the two security books above, and one Packt offers only as PDF). Still open: sending books to the Kindle.

## 2026-10-10: both libraries in Calibre

Calibre now also holds the 585 Humble Bundle EPUBs (1,132 books; see the [humblebundle-downloader](https://github.com/federico-moran/humblebundle-downloader) repo). Every Packt book has a `PacktPub` tag. No book is in both libraries.

The book with broken links was dropped rather than chased further. It stays in `skip.txt`.

## 2026-10-11: tool defaults and tag cleanup

All three tools now default to `OneDrive\Documents\PacktPub`, so `-Folder` is only needed for another copy (a backup, say). `skip.txt` also accepts `<isbn>:mobi` lines, and `New-SetDone.ps1` counts `.mobi` files, as `Update-Manifest.ps1` already did.

`Update-CalibreMetadata.ps1` now removes the bookstore subject codes (BISAC, e.g. `COM053000 - COMPUTERS / Security / General`) that Calibre read from the EPUBs as tags: 125 different tags on 226 Packt books, and none on Humble books. Each Packt book keeps its Packt category and `PacktPub`. The codes stay inside the EPUB files.
