# How we got here

This project was built in one long session with an AI coding agent (Claude Code), starting from a cloned repository that no longer worked. This is the story of that session: what we tried, what broke, and what the evidence said at each step. It is written for two audiences: someone learning to **code with agents**, and a **security engineer** interested in how a real web target behaves.

## 1. Start from someone else's code

The starting point was [lmbringas/packtpub-downloader](https://github.com/lmbringas/packtpub-downloader), a Python script from about 2019. It logged in to PacktPub's REST API (`services.packtpub.com`), listed your books a page at a time, and downloaded each file with `requests`.

The first request to the agent was simply *"explore this repo."* It read every file and reported bugs:
- The token refresh was broken in two places.
- `download_book` used a variable that was never defined.
- Book titles weren't cleaned for characters Windows doesn't allow in file names.
- The dependency versions were too old to install on current Python.

Then it ranked the bugs by how much each would stop a real run. At the top of the list it put something that wasn't a bug at all:

> **Step 0: check whether the API still exists.** The project is unmaintained; if the endpoints are gone, none of the fixes matter.

**Lesson (agents):** ask for a ranked list and the reasoning behind it, not just a list of problems. The most valuable item was the assumption everything else depended on.

## 2. The wall: Cloudflare

Step 0 was answered with a few `curl` requests that were *meant* to fail (fake credentials, no token). A missing endpoint would return 404; an existing one, 401. Every endpoint instead returned **HTTP 403 with a Cloudflare "Just a moment…" page** (`cf-mitigated: challenge`). A browser User-Agent made no difference.

So the original design (a script talking to an API) was dead, whatever the code quality. That changed the project from *"fix the bugs"* to *"find a new approach"*. The agent laid out three options instead of guessing: download by hand, borrow the browser's session cookies, or drive a real browser.

## 3. Discovering the site with read-only probes

The user's browser developer tools gave the first clue: a download link of the form `subscription.packtpub.com/download/<isbn>/epub`, on a different host from the old API. Probing it without logging in hit the same Cloudflare challenge. Everything needed a real browser.

The next step was to **learn how the site works without changing anything**, using small snippets pasted into the Edge DevTools Console:

1. **What does the library page request?** One snippet listed the page's network requests (with query strings removed, so no tokens leaked) and its download links. It found the internal API: `/api/entitlements/users/me/owned` and `/api/product/<isbn>/files`.
2. **What do those endpoints return?** A second snippet fetched two books and one file list, and tried a download, aborting as soon as the headers arrived. It failed silently the first two times. The cause: `copy()` (copy to clipboard) only works while the page has focus, and by the time the network requests finished, focus was in DevTools. The fix was to print the result and have the user copy it by hand.

**Lesson (agents):** give the agent eyes. When it can't see the target directly, a *read-only* probe that reports back beats a guess. And when a probe fails, find out why before trying again: the clipboard problem would have kept breaking every later probe.

## 4. Dead ends worth keeping

- **Playwright (an automated browser).** It passed Cloudflare's first check, but when the user tried to log in, the "verify you are human" box reloaded forever. Browsers launched by automation tools carry flags that bot detection looks for.
- **Attaching to a normal browser through a debugging port.** The agent tried to launch Edge with a remote-debugging port, so the user could log in by hand and the agent could attach afterwards. **The agent's own safety controls blocked this** as weakening security: an open debugging port gives any local program full control of the browser, and the aim was partly to get past bot detection. The agent stopped, explained, and let the user choose. It did not look for another way around the block.

**Lesson (agents):** guardrails are part of the design. A refusal can push you toward a better approach, and it did here.

## 5. The approach that worked: run inside the page

Option 2, reworked: **run the downloader in the user's own logged-in tab**, pasted into the Console. No bot check to pass, no credentials to handle. The script:

1. Pages through `/api/entitlements/users/me/owned` (907 titles).
2. Calls `/api/product/<isbn>/files` for each title to find its real formats. Many older books have `mobi`; video courses have `video`; some titles have nothing at all.
3. Saves a dry-run file, `packt-library.json`, before touching any download.

It runs as a dry run first, then a single-file test, and only then the full run.

## 6. Three 403s and what each one taught

| Attempt | Result | Lesson |
| --- | --- | --- |
| A "does this link work?" `fetch()` before each download | **403** | `/download/` refuses script (fetch) requests |
| An `<a download>` link click, used to choose the file name | **403** in Edge ("No permissions") | The `download` attribute changes the request headers and is refused too |
| `window.open(url)` in a normal tab | **Works** | Only a real page navigation is served |

The server was almost certainly checking **Fetch Metadata headers** (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`), a real defence that lets an endpoint tell script requests from user actions (see [self-xss.md](self-xss.md)). The user's own manual click working was the control case that separated "my script is wrong" from "my session is wrong."

Two smaller problems followed:
- **Pop-ups blocked.** A one-line `window.open` test typed in the Console worked, because Edge allows a pop-up right after the user presses Enter. The script's first download came minutes later and was blocked. The fix: allow pop-ups for the site.
- **A settings edit caught in review.** Between runs, the formats line had been widened to include `mobi`, `video` and `code`. The user had asked for PDF and EPUB only, and video courses can be several gigabytes each. A "check the code again" review caught it before the full run.

## 7. The run, and a forensic detour

The full run started 1,079 downloads. After about 200, Cloudflare began showing a human check in the download tab. The script couldn't see it, so it kept "downloading" and **marked each file as done even though nothing arrived.**

The file creation times told the story:

| Time | Files | What happened |
| --- | --- | --- |
| 02:31–02:46 | 1–177 | Normal, one file every ~5 s |
| 02:46–02:59 | 178–191 | About one file per minute: most attempts blocked by the check |
| 02:59–06:25 | none | Nothing for 3½ hours while the script carried on |
| 06:25–06:29 | 192–243 | Back to normal after the user passed the check |

Two fixes:
1. **Detect and pause.** Before each file, the download tab is reset to `about:blank`. A successful download leaves it blank; a page appearing means something went wrong. If that page is the Cloudflare check, the script pauses, flashes the tab title, and waits for a **Continue** click after the user has passed the check. It never tries to solve the check itself.
2. **Trust the disk, not the log.** The files are named `<isbn>.<ext>`, so the correct "done" record could be rebuilt from the folder itself. That became [`tools/New-SetDone.ps1`](../tools/New-SetDone.ps1).

**Lesson (security):** a script's log is only what it *believed* happened. Timestamps on the actual artefacts showed the real timeline, including the 3½-hour gap.

**Lesson (agents):** "marked done when started" was a shortcut the agent took knowingly, and it failed exactly as the agent had warned it might. Recording a result as success before it's confirmed is a common source of bugs, whoever writes the code.

## 8. Cleanup

With a working tool, the repository was rebuilt as the user's own:
- The old Python and Docker files were removed.
- The history was restarted, with credit to the original project.
- Personal data (the library list and the rebuilt resume record) was git-ignored.
- The security angle was written up in [self-xss.md](self-xss.md).

## Takeaways

**Coding with agents**
- Check the assumption everything depends on first (step 0), before fixing anything.
- Use read-only probes and dry runs before making changes, and one-file tests before full runs.
- Change code only in response to evidence: every change here followed a specific observed failure.
- Keep the human in the loop for judgement calls: which approach to take, when to push to GitHub, and passing the human check.
- Review the code before a big run, even when you trust it.

**Security**
- The same Console access that made this tool possible is the self-XSS attack surface.
- Defences we ran into firsthand: bot management, Fetch Metadata enforcement, behavioural rate limiting, and the browser's paste warning.
- In an investigation, the files and their timestamps are better evidence than what a program says it did.
