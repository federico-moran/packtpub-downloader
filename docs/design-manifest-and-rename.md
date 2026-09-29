# Design: library manifest and human-readable file names

**Status:** Part 1 is built as [`tools/Update-Manifest.ps1`](../tools/Update-Manifest.ps1), with the ISBN check-digit test, and the dry run now saves each title's book-list details (`product`, `acquired`, `source`) in `packt-library.json`. The manifest also has `problem`, `status` (present or missing), `modified`, `published` and `category` columns. Parts 2 and 3 are proposed.

## Background

Today the downloader tracks progress in Edge's `localStorage` (key `packtDownloaderDone`), recording each file when its download *starts*. That record is:

- tied to one browser profile,
- lost if site data is cleared,
- wrong whenever a download is blocked (for example the 3½-hour Cloudflare gap described in [how-we-got-here.md](how-we-got-here.md)).

In practice the real record became the download folder itself: files are named `<isbn>.pdf` / `<isbn>.epub`, and [`tools/New-SetDone.ps1`](../tools/New-SetDone.ps1) rebuilds the browser record from those names.

Separately, ISBN file names are hard to browse on an e-reader or in a backup.

## Goals

1. A **persistent, portable record** of what has been downloaded, stored with the files and trusted over `localStorage`.
2. **Detect bad files:** error pages saved under a book name, truncated downloads, duplicates, and later corruption in backups or device copies.
3. **Readable file names,** produced deterministically (same inputs give the same names) and reversibly.
4. Optionally, **richer metadata** per book (subtitle, publication date, category).

## Non-goals

- Changing how the browser script downloads files.
- Fetching metadata from third-party services (the rename step must work offline).
- Editing metadata *inside* the EPUB or PDF files.

## Part 1: the manifest

A file kept **inside the library folder** (e.g. `Downloads\PacktPub\manifest.csv`), so it travels with every copy and backup.

| Column | Meaning |
| --- | --- |
| `isbn` | 13-digit ISBN (PacktPub product ID) |
| `format` | `pdf` or `epub` |
| `file` | Current file name (changes if renamed) |
| `bytes` | File size |
| `sha256` | Content hash |
| `valid` | Result of the format check (see below) |
| `added` | When the file was first recorded |
| `title` | From `packt-library.json`, if available |

**Tool:** `tools/Update-Manifest.ps1 -Folder <library>`

- Scans the folder, adds new files, updates changed ones, and flags missing ones. Running it twice with no changes does nothing.
- Hashes with `Get-FileHash -Algorithm SHA256`.
- Generates `browser/set-done.js` from the manifest. This replaces the file-name parsing in `New-SetDone.ps1`, so names no longer need to contain only the ISBN.

**Format check.** PacktPub publishes no reference hashes, so a hash can't prove a first download is correct. Check the file content instead:

- **PDF:** the first bytes are `%PDF`.
- **EPUB:** a zip file (starts with `PK`) whose first entry is `mimetype` containing `application/epub+zip`.
- Anything else, especially HTML, is marked `valid = false` and left out of the done list, so the next run downloads it again.

**What the hash is for:**

- Removing duplicates: `… (1).pdf` with the same hash as the original can be deleted.
- Verifying backups and e-reader copies against the manifest.
- Noticing when PacktPub updates a book (a new hash on re-download).

## Part 2: rename to titles

**Tool:** `tools/Rename-Library.ps1 -Folder <library> -Library packt-library.json [-Apply]`

- **Input:** `packt-library.json` from the dry run (ISBN → title). No network access, so the result is deterministic.
- **Name format:** `<Title> [<isbn>].<ext>`, e.g. `Learn Wireshark - Second Edition [9781803231679].pdf`.
  - The ISBN stays in the name because titles aren't unique (multiple editions, and "Learning Python" as both a book and a video course). It also keeps files traceable if the manifest is lost.
- **Cleaning:**
  - Replace Windows-invalid characters `< > : " / \ | ? *`.
  - Repair PacktPub's encoding damage (`???` → `'`, `–` or `—`, as appropriate).
  - Collapse duplicated suffixes (`Second Edition - Second Edition`).
  - Trim trailing dots and spaces, and cap the length for Windows path limits.
- **Safety:**
  - Without `-Apply`, it only prints the plan (old → new).
  - With `-Apply`, it renames, updates the manifest's `file` column, and writes `rename-log.csv` for undoing.
  - Files already renamed are skipped, so it's safe to re-run.

## Part 3: metadata (optional)

The book-list API (`/api/entitlements/users/me/owned`, field `simplifiedProduct`) already returns subtitle, publication date, category, length, type, and ISBNs for related formats. The dry run could save these into `packt-library.json`, and the manifest could carry the useful ones.

Authors come back only as IDs, so names would need another endpoint. That isn't investigated yet.

## Candidate features

### ISBN check-digit validation

An ISBN-13 is made up of the prefix (`978`/`979`), a registration group (`1` = English), a publisher code (Packt holds several blocks such as `1-78…`, `1-80…`, `1-83…`, `1-84…`), a title number, and a **check digit**.

The check digit is calculated from the first 12 digits: weight them alternately 1 and 3, sum them, and the check digit is `(10 − sum mod 10) mod 10`. The manifest tool can check this for every file:

- A mismatch means the name isn't a real ISBN (damaged, mistyped, or renamed wrongly). Flag it, just like a failed format check.
- It costs nothing and needs no network access.

### Acquisition order and bundles

The book list is sorted by **when each title was acquired**, not by ISBN, and it shows clear subject runs (about 40 Raspberry Pi books together, then Splunk, Wireshark, forensics, OpenStack, 3D printing). Within a run the ISBNs are unrelated, which points to **themed bundles bought at once**.

The API already returns what's needed to record this:

| Field | Use |
| --- | --- |
| `createdAt` | When the title was added to the account; titles added within minutes of each other are likely one bundle |
| `entitlementSource` / `entitlementLink` | How it was acquired (e.g. `Vouchers`) and a reference that may group a bundle |
| `simplifiedProduct.category` | PacktPub's own subject category |
| `simplifiedProduct.publicationDate` | Publication date |

Saving these in the dry run (`packt-library.json`) and carrying them into the manifest would allow:

- **Grouping by bundle or by category,** for example folders such as `Security/`, `Raspberry Pi/` or `2019-03 bundle/` in a reading copy.
- **Sorting by publication date,** which is what nearby ISBNs roughly reflect: publishers assign title numbers in sequence as books go into production, so close ISBNs usually mean close release dates. Older `97817…`/`97818…` titles are mostly 2013–2019, while `978180…`/`978183…` are 2020 onwards.
- **Spotting what's new** since the last run, from `createdAt`.

Open question: whether `entitlementLink` actually identifies a bundle or voucher batch. That needs checking against a few known purchases.

### Adjustable download pacing

Today one setting, `DELAY_MS` (5,000 ms), does two jobs: it's the pause between downloads, *and* it's how long the script waits before checking the download tab for a human check or error page. That ties "how fast" to "how reliably failures are noticed".

Measured in the first full run: 5.1 s per file, so the pause, not the connection, set the pace. About 200 downloads in, Cloudflare started showing human checks.

Proposal:

| Setting | Meaning | Suggested default | Lower limit |
| --- | --- | --- | --- |
| `CHECK_AFTER_MS` | How long to wait after opening a link before looking at the download tab | 3,000 | ~2,500. Any shorter and a slow-loading check page can be mistaken for a successful download, which brings back silently skipped files. |
| `DELAY_MS` | Total pause between starting one download and the next (includes `CHECK_AFTER_MS`) | 5,000 | 3,000 |

Possible refinements:

- **Poll instead of a fixed wait:** look at the tab every 500 ms until a page appears or `CHECK_AFTER_MS` runs out. Failures are noticed sooner, and a successful download costs no extra time.
- **Back off after a human check:** after each check, raise `DELAY_MS` (e.g. ×1.5, up to a maximum), and ease it back down only after a long stretch with no checks. The aim is to stay under the rate that triggers checks, being gentler on the site and needing fewer manual steps. It is not about hiding from detection: the checks are still passed by a person.
- **Print an ETA** after each file, based on the measured seconds per file.

For scale: at 3 s per file, the ~1,080-file library takes about 55 minutes instead of about 90, not counting the ~5-minute reading phase at the start of each run.

### Clean stop and faster restarts

Today the only way to stop is to close or reload the library tab, and every restart re-reads all 907 titles (~5 minutes). See the playbook's *Stopping and resuming* section for the current workaround.

- **Stop / Pause button:** a small fixed panel on the library page with **Pause**, **Resume** and **Stop**. Pause and Stop take effect *after* the current file's check completes, so no file is left half-recorded. Stop prints a summary (done, failed, remaining). This reuses the overlay code already written for the human-check pause.
- **Reuse the library list:** cache the title list and file links (in `localStorage`, or the dry-run `packt-library.json` pasted back in, like `set-done.js`). A restart then skips straight to downloading. Add a `REFRESH_LIBRARY = true` setting, or refresh automatically when the cache is older than N days, so new purchases are still picked up.
- **Record only confirmed files:** once the manifest exists (Part 1), generate the done list from it on every resume instead of relying on the browser's "started" record. This removes the Edge-closed-mid-download gap entirely.

## Alternative: Calibre

[Calibre](https://calibre-ebook.com) already:

- reads the title and author embedded in EPUB and PDF files,
- can look up metadata and covers by ISBN,
- organises books as `Author/Title/`,
- syncs to most e-readers.

It can be scripted with `calibredb add` and `ebook-meta`.

Possible split: **these tools own the manifest** (what you have, and is it intact), and **Calibre owns presentation** (names, covers, device sync). If Calibre is adopted, Part 2 may be unnecessary.

## Open questions

- CSV or JSON for the manifest? CSV is easy to open in Excel; JSON handles nested metadata better.
- Rename in place, or copy into a separate "reading" folder and leave the ISBN-named originals untouched?
- Calibre, custom rename, or both?
- Should the browser script read the manifest directly (pasted like `set-done.js`), or keep the generated `set-done.js`?

## Suggested order

1. Part 1: manifest and format check. `set-done.js` is generated from it.
2. Decide on Calibre versus Part 2.
3. Part 3 only if the metadata turns out to be useful.
4. Candidate features: the ISBN check can go straight into Part 1. Acquisition and bundle grouping depend on Part 3's metadata. Adjustable pacing is independent and only touches the browser script.
