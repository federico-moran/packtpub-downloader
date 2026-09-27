# Playbook: downloading your PacktPub library

A step-by-step checklist for each run. For what the tool is and how it works, see the [README](../README.md).

**Time needed:** about 10 minutes of setup, then about 90 minutes of mostly unattended running for a library of ~1,000 files. Stay within earshot for the occasional human check.

## 1. Prepare a dedicated folder

Create a folder used only for PacktPub files, for example:

```
C:\Users\<you>\Downloads\PacktPub
```

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
5. `packt-library.json` is saved to the PacktPub folder. It lists every title and its external code links; keep it or move it somewhere else.

## 4. One-file test

1. In the script, set `DRY_RUN = false` and `MAX_DOWNLOADS = 1`, then paste and run it again.
2. Check **Ctrl+J**: the file should be named like `9781803231679.pdf`, be at least a few hundred KB, and open.

## 5. Full run

1. Set `MAX_DOWNLOADS = Infinity`, then paste and run it again.
2. Leave both tabs open: the library tab running the script, and the download tab it opens.
3. **If a human check appears,** the library tab's title flashes *⚠ Verify you are human* and a **Continue** button appears. Complete the check in the download tab, then click **Continue**.
4. The run is finished when the Console prints `Finished: ...`. Any files listed as *failed* weren't marked done, so running the script again retries them.

**If the run is interrupted** (tab closed, PC restarted), just repeat step 5. Files already started are skipped.

## 6. Verify

1. Rebuild the "done" record from what's actually in the folder:
   ```powershell
   .\tools\New-SetDone.ps1 -Folder "$env:USERPROFILE\Downloads\PacktPub"
   ```
   It prints `N files recorded`. **Compare that with N from the dry run.**
2. If it's lower, paste the generated `browser/set-done.js` into the Console, then run the downloader again. Only the missing files are downloaded. Repeat until the counts match.
3. Duplicates such as `9781… (1).pdf` can appear after a human check. They're safe to delete.
4. A few titles have no downloadable files at all. The dry-run list shows them with empty `files`.

## 7. Afterwards

1. **Put Edge back:** `edge://settings/downloads` → set *Location* back to your usual Downloads folder, and turn *Ask me what to do with each download* back on if you like.
2. **Copy to your reading device:** EPUBs suit most e-readers and phones; PDFs are better on tablets or for diagrams-heavy books.
3. **Back up:** archive the whole PacktPub folder (zip it, or copy it to your backup drive or cloud storage).
4. Optional: leave the pop-up permission for PacktPub in place for next time.

## Next time (new purchases)

Repeat steps 2–7 with the **same folder**. Run `New-SetDone.ps1` first and paste `set-done.js` (step 6) so the script knows what you already have, even on a different PC or browser profile. Only new titles will be downloaded.
