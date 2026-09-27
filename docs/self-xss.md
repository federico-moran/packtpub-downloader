# Case study: this downloader is self-XSS

The downloader works by pasting JavaScript into the DevTools Console of a logged-in page. That is the same technique as **self-XSS**, a social-engineering attack. This note walks through why, using what the script actually does, and what defends against it.

## XSS in one paragraph

Cross-site scripting (XSS) means **an attacker's JavaScript runs inside a trusted site's page**. The browser's same-origin policy normally keeps one site's code away from another site's data. XSS gets around that by putting hostile code *inside* the trusted origin, where it has the same rights as the site's own code: it can read the page, call the site's APIs with the victim's cookies, and act as the victim.

The classic variants differ only in how the code gets in:

| Variant | How the attacker's script gets into the page |
| --- | --- |
| Reflected | Injected via a crafted link; the server echoes it back unescaped |
| Stored | Saved in the site's data (a comment, a profile field) and served to every viewer |
| DOM-based | The page's own JavaScript writes attacker-controlled input into the DOM unsafely |
| **Self-XSS** | **The victim pastes it in themselves**, after being tricked |

In the first three the site has a bug. In self-XSS **the site has no bug at all**. The injection point is the user, and the payload lands in exactly the same place with exactly the same power.

## What the Console gives a script

Code typed in the Console runs *in the page's origin*: same cookies, same storage, same APIs, same CSP. Here is what this project's script does, mapped to the attack capability each step demonstrates:

| What the downloader does | The attacker version |
| --- | --- |
| `fetch('/api/entitlements/users/me/owned')` with no login code | Calls any authenticated API as the victim. HttpOnly cookies are sent automatically, even though the script can't read them. |
| Walks 907 titles and their file lists in about 5 minutes | Enumerates the account's data (orders, messages, documents, contacts) |
| Opens `/download/...` for 1,079 files | **Bulk data exfiltration**, driven from the victim's own trusted browser and IP |
| Stores progress in `localStorage` | **Persistence**: data or code that survives page reloads |
| Opens a second tab with `window.open` | Starts navigations and pop-ups, which CSP `connect-src` does not restrict |
| Builds a pop-up overlay with a Continue button | **UI redress**: a convincing fake prompt inside the real site ("session expired, re-enter your password") |

An attacker adds only one thing: sending the results to a server they control, and taking harmful actions instead of downloading (changing email/password or payout details, creating API tokens, sending messages).

## How victims get talked into it

- "Paste this into your browser console to unlock free coins / see who viewed your profile / verify your account."
- A fake support agent: "open DevTools and run this so we can fix your account."
- **ClickFix**, the currently common relative: a fake *"verify you are human"* page copies a command to the clipboard and tells the user to press **Win+R**, **Ctrl+V**, **Enter**. The payload then runs in PowerShell on the machine, not just in one site's page. (Note the irony: this project hit the real Cloudflare check many times.)

## What stopped or slowed this script (real defences we ran into)

These are the controls that actually affected this project, which makes them good evidence of what works:

1. **Bot management (Cloudflare).** A plain Python/`curl` client got a JavaScript challenge (`cf-mitigated: challenge`, HTTP 403). An automated browser launched by Playwright was caught and stuck in a challenge loop. Only a real user's browser got through, which is exactly why attackers need the victim to run their code.
2. **Fetch Metadata enforcement.** `/download/<isbn>/<format>` returned **403 to `fetch()`** and to `<a download>` clicks, and only served a real page navigation (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`). A server can use these headers to refuse script-driven requests to sensitive endpoints.
3. **Behavioural rate limiting.** After roughly 200 downloads, Cloudflare started challenging the download tab, forcing a human back into the loop. Unattended bulk exfiltration stalled for 3½ hours.
4. **The browser's paste warning.** Edge refused the first paste until the user typed `allow pasting`, a speed bump aimed directly at self-XSS.

## Would an EDR catch it?

Almost certainly not. An EDR (SentinelOne, Defender for Endpoint, CrowdStrike and similar) watches the **operating system**: processes, files, the registry, network connections. At that level, this script is normal browsing.

| Activity | What the EDR sees | Suspicious? |
| --- | --- | --- |
| Pasting and running the script | Nothing. The JavaScript runs inside the browser's page process; the DevTools Console and the page are invisible to the EDR. | — |
| 907 API calls | `msedge.exe` making HTTPS connections to a legitimate site | No |
| 1,079 downloads | `msedge.exe` creating `.pdf`/`.epub` files in `Downloads` | No |
| New processes, code injection, persistence, script engines | None | — |

EDR detections are built on things like a process launching something unexpected (`winword → powershell`), code injection, credential access, persistence, and ransomware-style mass changes to existing files. This script does none of that. The most an EDR does here is:

- **scan the downloaded files** as they're written (a malicious PDF could be caught there), and
- **record file-creation events in its telemetry,** where a hunt might spot one browser process writing ~1,000 files in two hours. That's a hunt, not an alert.

**The attacker's version is also mostly invisible.** A self-XSS payload that sends account data to an attacker's server is, to the endpoint, just the browser making another HTTPS request. The EDR might flag the destination through threat intelligence, but not the behaviour. That is a large part of why browser-only attacks appeal to attackers: they stay under the EDR. The trade-off is that the attacker is limited to what that one site allows.

**ClickFix is different.** Once the victim pastes into the Run dialog, the attack leaves the browser:

```text
explorer.exe → powershell.exe -enc <long base64> → downloads and runs payload
```

An unusual parent/child process chain, an encoded command line, and a newly written program being run are exactly what EDR is built to catch.

**Takeaway:** EDR covers the endpoint, but a user's **logged-in browser session is largely a blind spot** for it. The browser and identity layers need controls of their own.

### Protecting enterprise browsers: where to start

- **Manage the browser as a platform.** Enforce policy through Group Policy or Intune (Edge for Business, Chrome Enterprise): approved browsers only, forced updates, sign-in tied to corporate identity.
- **Control DevTools.** Set `DeveloperToolsAvailability = 2` for everyone except groups that need it (developers, IT). This removes the Console-paste attack path for most users.
- **Control extensions.** Use an allowlist (`ExtensionInstallAllowlist` with `ExtensionInstallBlocklist = *`) and review extension permissions. A malicious extension has the same in-page power as a pasted script, permanently.
- **Watch what happens inside the page.** Browser security tools (security extensions or enterprise browsers) can see script behaviour, pastes, data leaving the page and risky sites, which EDR can't.
- **Network and data layer.** A secure web gateway or SSE/CASB for URL filtering, DLP on uploads, and download limits for sanctioned apps.
- **Identity layer.** Conditional access (managed device, compliant browser), short session lifetimes, re-authentication for sensitive actions, and token protection or device-bound sessions where supported.
- **Users.** Teach the one-line lesson below, and include ClickFix-style fake CAPTCHAs in phishing simulations.

## Defences, by layer

**Browser / endpoint**
- Leave the paste warning on, and teach users what it means.
- For users who don't need DevTools, set the `DeveloperToolsAvailability` policy to `2` (Edge/Chrome, via Group Policy or Intune). This is the strongest single control against console-paste attacks.
- ClickFix: remove the Run dialog (`NoRun`) where you can, use PowerShell Constrained Language Mode with AppLocker/WDAC, and block `mshta` and similar built-in tools.
- Session and download controls (e.g. Defender for Cloud Apps session policies, or an enterprise browser) to cap bulk downloads.

**Application**
- **HttpOnly** session cookies. This stops token theft, but not abuse within the session.
- A strict **CSP `connect-src`**. Console code obeys the page's CSP for `fetch`/XHR, which limits where data can be sent (navigations and some beacons can still leak).
- **Step-up authentication** (password or MFA) for sensitive actions. A pasted script can't answer an MFA prompt.
- **Fetch Metadata checks** on endpoints that should only be reached by user navigation.
- **Rate limits and bot management** tuned to human behaviour.
- Device Bound Session Credentials limit cookie *replay* elsewhere, but not abuse inside the victim's browser.

**Detection ideas**
- API call patterns that don't match the UI, e.g. `/api/product/<isbn>/files` for 907 titles in minutes with no product-page views.
- Requests at a perfectly regular rhythm (this script: one every 5 seconds, for hours).
- Missing app-specific headers (CSRF tokens, app version, request IDs) that the real front end always sends.
- Download volume compared with the user's normal baseline.
- For ClickFix: `explorer.exe` launching `powershell`/`mshta`/`cmd` with long or encoded command lines, and new values under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU`.

## The one-line lesson

> No legitimate site will ever ask you to paste anything into the browser Console, the Run dialog, or a terminal.

The browser can't tell the difference between *you* running code in your session and *someone else's* code that you ran for them.
