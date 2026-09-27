# PacktPub Downloader

Downloads every ebook you own on [PacktPub](https://subscription.packtpub.com) (PDF and/or EPUB), from inside your own logged-in browser session.

It is also a small case study in **self-XSS**: the same technique that makes this script work is what attackers use when they talk a victim into pasting code into their browser. See [docs/self-xss.md](docs/self-xss.md).

## Why a browser script?

This project started as a fork of [lmbringas/packtpub-downloader](https://github.com/lmbringas/packtpub-downloader), a Python tool that logged in to PacktPub's REST API. That no longer works: PacktPub's API and download endpoints now sit behind a Cloudflare bot check that plain HTTP clients (and automated browsers) can't pass.

Instead of fighting the bot check, this version runs **in the page itself**, via the browser DevTools Console. It uses the same session and the same internal endpoints the PacktPub website uses:

| Purpose | Endpoint |
| --- | --- |
| List owned titles | `/api/entitlements/users/me/owned?limit=&offset=` |
| Formats for a title | `/api/product/<isbn>/files` |
| Download a file | `/download/<isbn>/<format>` (only works as a real page navigation) |

## Setup (one time, Microsoft Edge)

1. **Allow pop-ups** for the site: `edge://settings/content/popups` → Allow → Add → `https://subscription.packtpub.com`
2. **Downloads**: `edge://settings/downloads` → turn off *Ask me what to do with each download*, and set *Location* to the folder you want (e.g. `Downloads\PacktPub`).
3. The first time you paste into the Console, Edge asks you to type `allow pasting`. That warning exists because of the attack described in [docs/self-xss.md](docs/self-xss.md), so read what you paste.

Chrome works the same way (use `chrome://settings/...`).

## Usage

1. Log in and open `https://subscription.packtpub.com/owned`.
2. Press **F12** → **Console**, paste all of [`browser/packt-downloader.js`](browser/packt-downloader.js), and press Enter.
3. **Dry run** (the default): lists your titles, the formats available, and what would be downloaded, and saves `packt-library.json` (every title plus its external code-repository links).
4. Edit the settings at the top of the script and run again:
   - `DRY_RUN = false` to download
   - `MAX_DOWNLOADS = 1` for a first test, then `Infinity`
   - `FORMATS = ['pdf', 'epub']`; also available are `'mobi'`, `'video'` (large zip files) and `'code'`
5. Leave the tab open. Files are opened one at a time, 5 seconds apart, in a second tab. The server names them `<isbn>.pdf` / `<isbn>.epub`.

### Human checks

After a few hundred downloads Cloudflare may show *verify you are human* in the download tab. The script detects it and **pauses**: the library tab's title flashes and a **Continue** button appears. Complete the check in the download tab, then click Continue. The script retries that file.

### Resuming and fixing the record

The script records each file it starts in the site's `localStorage`, so running it again skips those files. If that record drifts from reality (for example, downloads were blocked while you were away), rebuild it from the files actually on disk:

```powershell
.\tools\New-SetDone.ps1 -Folder "$env:USERPROFILE\Downloads\PacktPub"
```

Then paste the generated `browser/set-done.js` into the Console before running the downloader again. That file lists your library, so it is git-ignored.

To start over completely: `localStorage.removeItem('packtDownloaderDone')`.

## Limitations

- The download request can't be inspected from the page, so a failed download only shows in the browser's downloads list (**Ctrl+J**).
- Some titles have no downloadable files; they are skipped.
- Code bundles hosted on GitHub are listed in `packt-library.json`, not downloaded.
- Only use this for content you own, and at a gentle pace.

## Credits

Original Python downloader by [lmbringas](https://github.com/lmbringas/packtpub-downloader), inspired by [ozzieperez/packtpub-library-downloader](https://github.com/ozzieperez/packtpub-library-downloader). This rewrite was built with an AI coding agent (Claude Code).
