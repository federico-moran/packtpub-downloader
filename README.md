# PacktPub Downloader

> Built by a non-developer, fully agentically, after taking Matt Pocock's course: [see how](#how-this-was-built).

Downloads every ebook you own on [PacktPub](https://subscription.packtpub.com) (PDF and/or EPUB), from inside your own logged-in browser session.

It is also a small case study in **self-XSS**: the same technique that makes this script work is what attackers use when they talk a victim into pasting code into their browser. See [docs/self-xss.md](docs/self-xss.md). For the story of how it was built, dead ends included, see [docs/how-we-got-here.md](docs/how-we-got-here.md).

## Why a browser script?

This project started as a fork of [lmbringas/packtpub-downloader](https://github.com/lmbringas/packtpub-downloader), a Python tool that logged in to PacktPub's REST API. That no longer works: PacktPub's API and download endpoints now sit behind a Cloudflare bot check that plain HTTP clients (and automated browsers) can't pass.

Instead of fighting the bot check, this version runs **in the page itself**, via the browser DevTools Console. It uses the same session and the same internal endpoints the PacktPub website uses:

| Purpose | Endpoint |
| --- | --- |
| List owned titles | `/api/entitlements/users/me/owned?limit=&offset=` |
| Formats for a title | `/api/product/<isbn>/files` |
| Download a file | `/download/<isbn>/<format>` (only works as a real page navigation) |

## Setup (one time, Microsoft Edge)

For the full run checklist (folder setup, verification, moving to your reader, backup), see the **[playbook](docs/playbook.md)**.

1. **Create a dedicated folder** for the library, e.g. `Downloads\PacktPub`, so the files are easy to move to a reading device, back up, and verify.
2. **Allow pop-ups** for the site: `edge://settings/content/popups` → Allow → Add → `https://subscription.packtpub.com`
3. **Downloads**: `edge://settings/downloads` → turn off *Ask me what to do with each download*, and set *Location* to that folder. This applies to all Edge downloads, so switch it back after the run.
4. The first time you paste into the Console, Edge asks you to type `allow pasting`. That warning exists because of the attack described in [docs/self-xss.md](docs/self-xss.md), so read what you paste.

Chrome works the same way (use `chrome://settings/...`).

## Usage

1. Log in and open `https://subscription.packtpub.com/owned`.
2. Press **F12** → **Console**, paste all of [`browser/packt-downloader.js`](browser/packt-downloader.js), and press Enter.
3. **Dry run** (the default): lists your titles, the formats available, and what would be downloaded, and saves `packt-library.json` (every title with its formats, details such as category and publication date, and its external code-repository links).
4. Edit the settings at the top of the script and run again:
   - `DRY_RUN = false` to download
   - `MAX_DOWNLOADS = 1` for a first test, then `Infinity`
   - `FORMATS = ['pdf', 'epub']`; also available are `'mobi'`, `'video'` (large zip files) and `'code'`
5. Leave the tab open. Files are opened one at a time, 5 seconds apart, in a second tab. The server names them `<isbn>.pdf` / `<isbn>.epub`.

### Human checks

After a few hundred downloads Cloudflare may show *verify you are human* in the download tab. The script detects it and **pauses**: the library tab's title flashes and **Retry** / **Skip** buttons appear. Complete the check, close every tab except the library tab, then click Retry. The script retries that file.

The check page also cuts the library tab's link to the download tab, so if the script carried on, each new download would open another tab with another check. Pausing on a tab it can no longer see prevents that.

### Resuming and fixing the record

The script records each file it starts in the site's `localStorage`, so running it again skips those files. If that record drifts from reality (for example, downloads were blocked while you were away), rebuild it from the files actually on disk:

```powershell
.\tools\New-SetDone.ps1  # the library in OneDrive\Documents\PacktPub; -Folder for another
```

Then paste the generated `browser/set-done.js` into the Console before running the downloader again. That file lists your library, so it is git-ignored.

To start over completely: `localStorage.removeItem('packtDownloaderDone')`.

### Checking the library: the manifest

```powershell
.\tools\Update-Manifest.ps1  # the library in OneDrive\Documents\PacktPub; -Folder for another
```

This keeps `manifest.csv` inside the download folder, with one row per file: ISBN, format, title, size, SHA-256 hash, and whether the file passed a check (a real PDF or EPUB, not cut off, and a valid ISBN). It also reports duplicates, files that have gone missing and, when the dry run's `packt-library.json` is in the folder, files the site offers that aren't downloaded yet. Like `New-SetDone.ps1` it writes `browser/set-done.js`, but only from files that passed the check. Re-runs only re-check files that changed. Files you've decided not to get (for example, an EPUB your antivirus always blocks because the book prints attack code) go in `skip.txt` in the folder, one `<isbn>:<format>  reason` per line; they're then reported as skipped and not retried. See [docs/design-manifest-and-rename.md](docs/design-manifest-and-rename.md).

## Limitations

- The download request can't be inspected from the page, so a failed download only shows in the browser's downloads list (**Ctrl+J**).
- Some titles have no downloadable files; they are skipped.
- Code bundles hosted on GitHub are listed in `packt-library.json`, not downloaded.
- Only use this for content you own, and at a gentle pace.

## How this was built

I'm not a developer. In June 2026 I took Matt Pocock's two-week [AI Coding for Real Engineers](https://www.aihero.dev/cohorts/ai-coding-for-real-engineers-m0k0w) course, and this tool and its two siblings were my first projects afterwards. They were built fully agentically: Claude Code wrote all the code and the docs. My part was choosing the problems, finding out how each store's site works, making the decisions (each design doc records them and why), and testing everything against my own libraries. I followed the course's process, with Matt's [skills](https://github.com/mattpocock/skills) installed in Claude Code.

I built the three between 2026-09-27 and 2026-10-11. Together they've downloaded and checked about 2,550 files, and the Humble and Manning tools have 105 automated tests between them.

This was the first, and it's my favourite. It started with me looking for a way to download my own Packt library. I found a Python downloader, but it no longer worked: every one of Packt's endpoints now answered with a Cloudflare bot check. So I set out to build my own. An automated browser couldn't get past the login, so the answer was to run inside my own logged-in tab instead. Then came three different 403 errors, each teaching something about how the site tells scripts from people, and a log that said files were downloading while nothing arrived for 3½ hours. The whole story, dead ends included, is in [how-we-got-here.md](docs/how-we-got-here.md), and the security side in [self-xss.md](docs/self-xss.md). In the end it did the job: 1,091 files came down, all valid.

The siblings: [humblebundle-downloader](https://github.com/federico-moran/humblebundle-downloader) and [manning-downloader](https://github.com/federico-moran/manning-downloader), both standalone PowerShell scripts with tests.

A personal project: issues are welcome, but fixes aren't promised. Not affiliated with or endorsed by Matt Pocock, AI Hero, PacktPub, Humble Bundle or Manning.

## Credits

Original Python downloader by [lmbringas](https://github.com/lmbringas/packtpub-downloader), inspired by [ozzieperez/packtpub-library-downloader](https://github.com/ozzieperez/packtpub-library-downloader). No code from either remains.

## License

[MIT](LICENSE)
