# Case study: this downloader is self-XSS

The downloader works by pasting JavaScript into the DevTools Console of a logged-in page. That gives it the same power as **cross-site scripting (XSS)**: code running inside a trusted site's page, with the user's session. Here I'm doing it to my own session, on purpose. Attackers get the same result by tricking a victim into pasting their code, a social-engineering attack known as **self-XSS** ([Wikipedia](https://en.wikipedia.org/wiki/Self-XSS), [Chrome for Developers](https://developer.chrome.com/blog/self-xss)). This note walks through why the two are the same, using what the script actually does, and what defends against it.

## XSS in one paragraph

Cross-site scripting (XSS) means **an attacker's JavaScript runs inside a trusted site's page**. The browser's same-origin policy normally keeps one site's code away from another site's data. XSS gets around that by putting hostile code *inside* the trusted origin, where it has the same rights as the site's own code: it can read the page, call the site's APIs with the victim's cookies, and act as the victim.

[OWASP](https://owasp.org/www-community/Types_of_Cross-Site_Scripting) describes three types, which differ in how the code gets in:

| Type | How the attacker's script gets into the page |
| --- | --- |
| Reflected | Injected via a crafted link; the server echoes it back unescaped |
| Stored | Saved in the site's data (a comment, a profile field) and served to every viewer |
| DOM-based | The page's own JavaScript writes attacker-controlled input into the DOM unsafely |

All three are bugs in the site. **Self-XSS isn't one of them:** the site has no bug at all, and the victim pastes the code in themselves, after being tricked. It's social engineering, not a vulnerability, which is why bug bounty programs such as [Google's](https://bughunters.google.com/learn/invalid-reports/web-platform/xss/6496555932319744/do-it-yourself-xss) don't accept reports of it. But the code lands in the same place, with the same power.

## What the Console gives a script

Code typed in the Console runs *in the page's origin*: same cookies, same storage, same APIs, and the same Content Security Policy (CSP) limits on where it can send requests. Here is what this project's script does, mapped to the attack capability each step demonstrates:

| What the downloader does | The attacker version |
| --- | --- |
| `fetch('/api/entitlements/users/me/owned')` with no login code | Calls any authenticated API as the victim. HttpOnly cookies are sent automatically, even though the script can't read them. |
| Walks 907 titles and their file lists in about 5 minutes | Enumerates the account's data (orders, messages, documents, contacts) |
| Opens `/download/...` for 1,079 files | **Bulk data exfiltration**, driven from the victim's own trusted browser and IP |
| Stores progress in `localStorage` | Leaves data behind that survives page reloads, for example to track a victim across visits |
| Opens a second tab with `window.open` | Starts navigations and pop-ups, which CSP `connect-src` does not restrict |
| Builds an overlay with Retry and Skip buttons when a human check appears | **UI redress**: a convincing fake prompt inside the real site ("session expired, re-enter your password") |

An attacker adds two things: sending the results to a server they control, and taking harmful actions instead of downloading (changing email/password or payout details, creating API tokens, sending messages).

## How victims get talked into it

- "Paste this into your browser console to unlock free coins / see who viewed your profile / verify your account."
- A fake support agent: "open DevTools and run this so we can fix your account."
- **ClickFix**, the currently common relative: a fake *"verify you are human"* page copies a command to the clipboard and tells the user to press **Win+R**, **Ctrl+V**, **Enter**. The payload then runs in PowerShell on the machine, not just in one site's page. (Note the irony: this project hit the real Cloudflare check many times.)

## What stopped or slowed this script (real defenses we ran into)

These are the controls that actually affected this project, which makes them good evidence of what works:

1. **Bot management (Cloudflare).** A plain Python/`curl` client got a JavaScript challenge (`cf-mitigated: challenge`, HTTP 403). An automated browser launched by Playwright got stuck in a challenge loop at login. Only a real user's browser got through, one more reason an attacker would want their code running in the victim's own browser.
2. **Fetch Metadata enforcement (most likely).** `/download/<isbn>/<format>` returned **403 to `fetch()`** and to `<a download>` clicks, and only served a real page navigation. The likeliest explanation is that the server checks the Fetch Metadata headers the browser adds (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` for a navigation), which lets it refuse script-driven requests to sensitive endpoints.
3. **Behavioral rate limiting.** After roughly 200 downloads, Cloudflare started challenging the download tab, forcing a human back into the loop. The unattended run stalled for 3½ hours, which would stall an attacker's bulk exfiltration the same way.
4. **The browser's paste warning.** Edge refused the first paste until the user typed `allow pasting`, a speed bump aimed directly at self-XSS.

## Would an EDR catch it?

Almost certainly not. An EDR (SentinelOne, Defender for Endpoint, CrowdStrike and similar) watches the **operating system**: processes, files, the registry, network connections. At that level, this script is normal browsing.

| Activity | What the EDR sees | Suspicious? |
| --- | --- | --- |
| Pasting and running the script | Normally nothing. The JavaScript runs inside the browser's page process, and what happens in the Console and the page isn't something EDR is built to watch. | — |
| 907 API calls | `msedge.exe` making HTTPS connections to a legitimate site | No |
| 1,079 downloads | `msedge.exe` creating `.pdf`/`.epub` files in `Downloads` | No |
| New processes, code injection, persistence, script engines | None | — |

EDR detections are built on things like a process launching something unexpected (`winword → powershell`), code injection, credential access, persistence, and ransomware-style mass changes to existing files. This script does none of that. The most an EDR does here is:

- **scan the downloaded files** as they're written (a malicious PDF could be caught there), and
- **record file-creation events in its telemetry,** where a hunt might spot one browser process writing ~1,000 files in two hours. That's a hunt, not an alert.

**The attacker's version is also mostly invisible.** A self-XSS payload that sends account data to an attacker's server is, to the endpoint, just the browser making another HTTPS request. The EDR might flag the destination through threat intelligence, but not the behavior. That is a large part of why browser-only attacks appeal to attackers: they stay under the EDR. The trade-off is that the attacker is limited to what that one site allows.

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
- **Watch what happens inside the page.** Browser security tools (security extensions or enterprise browsers) can see script behavior, pastes, data leaving the page and risky sites, which EDR can't.
- **Network and data layer.** A secure web gateway or SSE/CASB for URL filtering, DLP on uploads, and download limits for sanctioned apps.
- **Identity layer.** Conditional access (managed device, compliant browser), short session lifetimes, re-authentication for sensitive actions, and token protection or device-bound sessions where supported.
- **Users.** Teach the one-line lesson below, and include ClickFix-style fake CAPTCHAs in phishing simulations.

### First two steps: the most risk reduced for the least effort

**1. Find out who actually needs DevTools.**

- List the groups that genuinely use it: developers, QA, web/IT support, security. Everyone else is a candidate for `DeveloperToolsAvailability = 2`.
- Assign the policy by group (Intune configuration profile or GPO), with the exempt groups excluded, and a simple exception request process.
- Pilot with one department first. The policy has no audit-only mode, so the pilot is how you find people who rely on DevTools without knowing it (for example, support staff who clear site data or read errors in the Console).
- Check that it applied on a test machine at `edge://policy` (or `chrome://policy`).

**2. Take an inventory of installed browser extensions.**

- Use the reporting you already have. Depending on your tools, that may be your browser management console (e.g. Microsoft Edge management or Chrome Browser Cloud Management extension reports) or Microsoft Defender Vulnerability Management's browser-extension inventory. Failing that, a script can read extension folders on disk (`%LOCALAPPDATA%\Microsoft\Edge\User Data\<profile>\Extensions`).
- Rank extensions by **permissions and reach**: "read and change all your data on all websites", access to cookies, the ability to inject scripts. Also note how many users have each one.
- Build the allowlist from what's actually used and justified, then enforce it: `ExtensionInstallBlocklist = *` plus `ExtensionInstallAllowlist`, and optionally `ExtensionInstallForcelist` for required ones.
- Watch for extensions that change owner or add permissions in an update. Hijacked or sold extensions are a known supply-chain route.

Together these close off the two easiest ways for someone else's code to run inside a user's logged-in session: a pasted script and an installed extension.

## Defenses, by layer

**Browser / endpoint**

- Leave the paste warning on, and teach users what it means.
- For users who don't need DevTools, set the `DeveloperToolsAvailability` policy to `2` (Edge/Chrome, via Group Policy or Intune). This is the strongest single control against console-paste attacks.
- ClickFix: remove the Run dialog (`NoRun`) where you can, use PowerShell Constrained Language Mode with AppLocker/WDAC, and block `mshta` and similar built-in tools.
- Session and download controls (e.g. Defender for Cloud Apps session policies, or an enterprise browser) to cap bulk downloads.

**Application**

- **HttpOnly** session cookies. This stops token theft, but not abuse within the session.
- A strict **CSP `connect-src`**. Console code obeys the page's CSP for `fetch`/XHR, which limits where data can be sent. Navigations, and requests governed by other directives (images, for example), can still leak it.
- **Step-up authentication** (password or MFA) for sensitive actions. A pasted script can't answer an MFA prompt.
- **Fetch Metadata checks** on endpoints that should only be reached by user navigation.
- **Rate limits and bot management** tuned to human behavior.
- Device Bound Session Credentials limit cookie *replay* elsewhere, but not abuse inside the victim's browser.

**Detection ideas**

- API call patterns that don't match the UI, e.g. `/api/product/<isbn>/files` for 907 titles in minutes with no product-page views.
- Requests at a perfectly regular rhythm (this script: one every 5 seconds, for hours).
- Missing app-specific headers (CSRF tokens, app version, request IDs) that the real front end always sends.
- Download volume compared with the user's normal baseline.
- For ClickFix: `explorer.exe` launching `powershell`/`mshta`/`cmd` with long or encoded command lines, and new values under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU`.

## The one-line lesson

> Never paste anything into the browser Console, the Run dialog or a terminal because a website or a stranger told you to, unless you understand what it does.

That includes this project: it asks you to paste its script, so read it first. The browser can't tell the difference between *you* running code in your session and *someone else's* code that you ran for them.
