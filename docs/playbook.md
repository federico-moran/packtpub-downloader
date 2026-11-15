# Playbook: downloading your PacktPub library

A step-by-step checklist for each run. For what the tool is and how it works, see the [README](../README.md).

**Time needed:** about 10 minutes of setup, then about 90 minutes of mostly unattended running for a library of ~1,000 files. Stay within earshot for the occasional human check.

For how the run on my own library went, problems included, see the [run log](run-log.md).

## 1. Prepare a dedicated folder

Create a folder used only for PacktPub files. The tools look here unless told otherwise:

```text
C:\Users\<you>\OneDrive\Documents\PacktPub
```

If you use another folder, pass it to each tool with `-Folder`.

Keeping the library in its own folder means:

- **Easy to move:** copy one folder to your e-reader or tablet.
- **Easy to back up:** archive one folder, with nothing else mixed in.
- **Easy to check:** the resume tool ([`tools/New-SetDone.ps1`](../tools/New-SetDone.ps1)) and the file counts in step 6 assume every file in that folder came from PacktPub.

## 2. Set up Edge (before each run)

1. **Download location:** `edge://settings/downloads` → *Location* → **Change** → pick the PacktPub folder.
2. Turn **off** *Ask me what to do with each download*.
3. **Pop-ups:** `edge://settings/content/popups` → *Allow* → **Add** → `https://subscription.packtpub.com` (one time only).
4. Make sure the PC won't sleep during the run, and that there's enough disk space (roughly 10–20 GB for ~1,000 PDFs and EPUBs).

> These download settings apply to **everything** you download in Edge, not just PacktPub. Step 7 switches them back.

## 3. Dry run

1. Log in and open `https://subscription.packtpub.com/owned`.
2. Press **F12** → **Console**. (The first time, type `allow pasting` when Edge asks.)
3. Paste all of [`browser/packt-downloader.js`](../browser/packt-downloader.js) with `DRY_RUN = true` (the default) and press Enter.
4. Note the line `Planned: N files in pdf, epub.` **N is your target count for step 6.**
5. `packt-library.json` is saved to the PacktPub folder. It lists every title with its formats, details and external code links. **Leave it there:** `Update-Manifest.ps1` (step 6) takes titles from it and uses it to list anything not downloaded yet.

## 4. One-file test

1. In the script, set `DRY_RUN = false` and `MAX_DOWNLOADS = 1`, then paste and run it again.
2. Check **Ctrl+J**: the file should be named like `9781803231679.pdf`, be at least a few hundred KB, and open.

## 5. Full run

1. Set `MAX_DOWNLOADS = Infinity`, then paste and run it again.
2. Leave both tabs open: the library tab running the script, and the download tab it opens. Edge asks once to allow "multiple automatic downloads" for the site: allow it.
3. **If a human check appears,** the library tab's title flashes *⚠ Verify you are human* and **Retry** / **Skip** buttons appear. Complete the check in the download tab, **close every other tab except the library tab**, then click **Retry**.
4. The run is finished when the Console prints `Finished: ...`. Any files listed as *failed* weren't marked done, so running the script again retries them.

### Stopping and resuming

**To stop** (e.g. before shutting down):

1. Close the library tab (the one with the Console). The script stops at once.
2. Press **Ctrl+J** and wait until nothing is still downloading, usually a few seconds. (If you don't wait, the resume steps catch unfinished files anyway.)
3. Close Edge and shut down. Leave Edge's download folder and pop-up settings as they are until the whole library is done.

**To resume** (minutes or days later):

1. **Rebuild the record from disk.** Open a PowerShell terminal in the project folder (VS Code's terminal works) and run:

   ```powershell
   .\tools\New-SetDone.ps1
   ```

   Note the number it prints: `N files recorded`. If Windows says running scripts is disabled, use `powershell -ExecutionPolicy Bypass -File .\tools\New-SetDone.ps1` instead.
2. **Open Edge**, log in, go to `https://subscription.packtpub.com/owned`, and press **F12 → Console**.
3. **Paste all of `browser/set-done.js`** (the file step 1 just created; copy it from VS Code) and press Enter. It prints `undefined`, which is normal. This replaces the browser's record with what's actually on disk.
4. **Open `browser/packt-downloader.js`**, change `DRY_RUN = true` to `DRY_RUN = false` (the repo copy defaults to a dry run), check `MAX_DOWNLOADS = Infinity`, save, copy all of it, paste it into the Console and press Enter.
5. **Check the numbers.** After the ~5-minute reading phase, the Console prints `Planned: P files ... Already done: X. This run: Y.` **X should equal N** from step 1, and Y should be P − N. If X is 0 or far off, close the tab and repeat from step 2.
6. **If a human check appears,** use the **Retry / Skip** screen: complete the check, close every tab except the library tab, then click **Retry**. If no pause screen appears and new check tabs keep opening, handle them by hand (complete each check and close the extra tabs), then report it as an issue.
7. **When the Console prints `Finished`,** go to [step 6. Verify](#6-verify): `New-SetDone.ps1` should report the planned count (or a few more if there are `(1)` duplicates).

| Situation | What happens | What to do |
| --- | --- | --- |
| Stopped while a file was being opened | It isn't marked done yet, so it's retried. If it had already downloaded, you get a harmless `(1)` duplicate. | Nothing, or delete the duplicate |
| Edge closed while files were still downloading | Unfinished files were already marked done and would be skipped | Resume steps 1–3 fix this (unfinished `.crdownload` files aren't counted) |
| Different browser, profile or PC, or site data cleared | The browser's record is gone, so the script would start from zero | Resume steps 1–3 fix this: the files on disk are the real record |
| Any restart | Reading the library again takes ~5 minutes | Expected |

## 6. Verify

1. Check every file and rebuild the "done" record from what's actually in the folder:

   ```powershell
   .\tools\Update-Manifest.ps1  # the library in OneDrive\Documents\PacktPub; -Folder for another
   ```

   It writes `manifest.csv` into the folder and prints how many files are valid, any that failed the check, and (with `packt-library.json` in the folder) **every file not downloaded yet, by title**. The first run hashes everything, about a minute for 20 GB.
2. If anything is listed as not downloaded or failed, paste the generated `browser/set-done.js` into the Console, then run the downloader again. Only those files are downloaded. Repeat until nothing is listed.
   A download that shows *Couldn't download - Virus detected* in **Ctrl+J** was blocked by your antivirus, not by the site, so retrying won't help.
   If a file can never be downloaded (for example, the antivirus blocks it every time), add a line `<isbn>:<format>  reason` to `skip.txt` in the library folder. The manifest then lists it as skipped, and `set-done.js` includes it so the downloader stops retrying it.
3. Duplicates such as `9781… (1).pdf` can appear after a human check. The manifest lists identical copies; the extras are safe to delete.
4. A few titles have no downloadable files at all. The dry-run list shows them with empty `files`.

## 7. Afterwards

1. **Put Edge back:** `edge://settings/downloads` → set *Location* back to your usual Downloads folder, and turn *Ask me what to do with each download* back on if you like.
2. **Copy to your reading device:** EPUBs suit most e-readers and phones; PDFs are better on tablets or for diagrams-heavy books.
   For a Kindle, add the EPUBs to Calibre (*Add books*; the originals are copied, not changed), close Calibre, then fix their details from Packt's records:

   ```powershell
   .\tools\Update-CalibreMetadata.ps1 -WhatIf   # preview
   .\tools\Update-CalibreMetadata.ps1
   ```

   (It defaults to `OneDrive\Documents\PacktPub`; use `-Folder` for another copy.) It sets each book's ISBN, publication date, publisher, category tag and a `PacktPub` tag (so they can be told apart from the Humble Bundle books in the same library), and corrects titles (adding the edition) and missing authors. It backs up Calibre's database first, and a second run changes nothing. Then send the books from Calibre (*Send to device* or *Email to Kindle*).
3. **Back up:** archive the whole PacktPub folder (zip it, or copy it to your backup drive or cloud storage).
4. Optional: leave the pop-up permission for PacktPub in place for next time.

## Next time (new purchases)

Repeat steps 2–7 with the **same folder**. Run `New-SetDone.ps1` first and paste `set-done.js` (step 6) so the script knows what you already have, even on a different PC or browser profile. Only new titles will be downloaded.
