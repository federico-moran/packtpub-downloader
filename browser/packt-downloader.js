// PacktPub library downloader - runs inside your own logged-in browser session.
//
// One-time Edge setup (your normal Edge - no special launch command needed):
//   - Allow pop-ups for the site: edge://settings/content/popups > Allow > Add > https://subscription.packtpub.com
//   - Downloads: edge://settings/downloads > turn off "Ask me what to do with each download",
//     and set Location to a dedicated folder (e.g. OneDrive\Documents\PacktPub). See docs/playbook.md.
//   - The first time you paste into the Console, Edge asks you to type "allow pasting".
//
// How to use:
//   1. Log in and open https://subscription.packtpub.com/owned in Edge.
//   2. Press F12 > Console, paste this whole file, press Enter.
//   3. It starts as a dry run (DRY_RUN = true): it lists what would be downloaded and saves packt-library.json
//      (every title with its formats and details; tools/Update-Manifest.ps1 reads it from the download folder).
//   4. Set DRY_RUN = false (and MAX_DOWNLOADS = 1 for a first test) and run again.
//   5. If Cloudflare's "verify you are human" check appears, the script pauses: complete the check
//      in the download tab, close every other tab, then click Retry on the library page.
//
// Already-downloaded files are remembered in this site's localStorage, so re-running resumes.
// To forget that history:  localStorage.removeItem('packtDownloaderDone')
// To rebuild it from the files actually on disk, see tools/New-SetDone.ps1.

(async () => {
  // ---- Settings ------------------------------------------------------------
  const FORMATS = ['pdf', 'epub'];  // format names as the site uses them: 'pdf', 'epub', 'mobi', 'video', 'code'
  const DRY_RUN = true;             // true = only list what would be downloaded
  const MAX_DOWNLOADS = Infinity;   // e.g. 1 for a first test; Infinity for everything
  const DELAY_MS = 5000;            // pause between downloads, to be gentle on the site
  // ---------------------------------------------------------------------------

  const PAGE = 25;
  const DONE_KEY = 'packtDownloaderDone';

  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const getJson = async url => {
    const r = await fetch(url);
    if (!r.ok) throw new Error(`HTTP ${r.status} for ${url}`);
    return r.json();
  };
  const saveTextFile = (name, text) => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
    a.download = name;
    document.body.append(a);
    a.click();
    a.remove();
  };

  let done;
  try { done = new Set(JSON.parse(localStorage.getItem(DONE_KEY) || '[]')); } catch { done = new Set(); }
  const markDone = key => {
    done.add(key);
    try { localStorage.setItem(DONE_KEY, JSON.stringify([...done])); } catch {}
  };

  // 1. List every owned title
  const titles = new Map();  // isbn -> the book list's record for that title
  for (let offset = 0; ; offset += PAGE) {
    const { data = [] } = await getJson(`/api/entitlements/users/me/owned?limit=${PAGE}&offset=${offset}`);
    const before = titles.size;
    for (const item of data) titles.set(String(item.productId), item);
    console.log(`Listed ${titles.size} titles...`);
    if (data.length === 0 || titles.size === before) break;  // end of list (or the API ignored offset)
    await sleep(500);
  }

  // 2. Look up the available formats for each title
  const plan = [], external = [], manifest = [];
  let checked = 0;
  for (const [isbn, item] of titles) {
    const title = item.simplifiedProduct?.title || item.productName || isbn;
    let files = {}, error;
    try {
      files = (await getJson(`/api/product/${isbn}/files`)).data || {};
    } catch (e) {
      error = e.message;
      console.warn(`Could not get formats for "${title}": ${error}`);
    }
    // Saved in the dry run's packt-library.json. `acquired`/`source` are when and how the title was
    // added to the account; `product` is the book list's full description (category, dates, ...).
    manifest.push({ isbn, title, files, ...(error && { error }),
      acquired: item.createdAt, source: item.entitlementSource, product: item.simplifiedProduct });
    for (const [fmt, link] of Object.entries(files)) {
      if (typeof link !== 'string' || !link) continue;
      const url = new URL(link, location.origin);
      if (url.origin !== location.origin) {
        external.push({ isbn, title, fmt, link });
      } else if (FORMATS.includes(fmt)) {
        plan.push({ isbn, title, fmt, url: url.href, key: `${isbn}:${fmt}` });
      }
    }
    if (++checked % 10 === 0) console.log(`Checked formats for ${checked}/${titles.size} titles...`);
    await sleep(300);
  }

  const todo = plan.filter(p => !done.has(p.key)).slice(0, MAX_DOWNLOADS);
  const available = {};
  for (const m of manifest) for (const f of Object.keys(m.files)) available[f] = (available[f] || 0) + 1;
  console.log('Formats available across your library:', available);
  console.log(`Planned: ${plan.length} files in ${FORMATS.join(', ')}. Already done: ${plan.length - plan.filter(p => !done.has(p.key)).length}. This run: ${todo.length}.`);
  console.table(todo.map(({ title, fmt }) => ({ title, fmt })));

  if (DRY_RUN) {
    const saved = { generated: new Date().toISOString(), titles: manifest, externalLinks: external };
    saveTextFile('packt-library.json', JSON.stringify(saved, null, 2));
    console.log('DRY RUN - nothing downloaded. Saved packt-library.json (every title with its formats, details and external code links).');
    return 'Dry run finished';
  }

  // 3. Download one at a time.
  // /download/ links only work as a normal page navigation: a fetch or an <a download> click gets 403.
  // So each link is opened in one reused tab (allow pop-ups for this site) and the server picks the
  // file name (<isbn>.<ext>). The tab is reset to about:blank first: a download leaves it there,
  // while Cloudflare's "verify you are human" check or an error page replaces it with a page.
  // The check page also cuts this page's link to the tab (Cross-Origin-Opener-Policy): the tab then
  // reads as closed or can't be inspected, and the next window.open() creates a new tab. So a tab
  // we can no longer see is treated like a check, not like a successful download.
  const isChallenge = doc =>
    /just a moment/i.test(doc.title) || !!doc.querySelector('script[src*="challenge-platform"], #challenge-form');

  // 'ok' (still blank: the link became a download), 'challenge', 'page' (some other page), or
  // 'lost' (tab closed or cut off - almost always the human check).
  const tabState = win => {
    try {
      if (win.closed) return 'lost';
      if (win.location.href === 'about:blank') return 'ok';
      return isChallenge(win.document) ? 'challenge' : 'page';
    } catch {
      return 'lost';
    }
  };

  // Pause until the person has passed the check. Resolves 'retry' or 'skip'.
  const waitForHuman = () => new Promise(resolve => {
    const box = document.createElement('div');
    box.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,.6);display:flex;align-items:center;justify-content:center';
    box.innerHTML = '<div style="background:#fff;color:#000;padding:24px 28px;border-radius:8px;font:16px system-ui;max-width:440px">'
      + '<b>Downloads paused</b><p>A "verify you are human" check appeared in a download tab. Complete it there, '
      + 'then <b>close every tab except this one</b> and click Retry.</p>'
      + '<button data-r="retry" style="font:inherit;padding:6px 16px">Retry</button> '
      + '<button data-r="skip" style="font:inherit;padding:6px 16px">Skip this file</button></div>';
    const title = document.title;
    const flash = setInterval(() => { document.title = document.title === title ? '⚠ Verify you are human' : title; }, 1000);
    for (const b of box.querySelectorAll('button')) {
      b.onclick = () => { clearInterval(flash); document.title = title; box.remove(); resolve(b.dataset.r); };
    }
    document.body.append(box);
    try {  // short beep; may be silent if the browser blocks audio
      const ac = new AudioContext(), o = ac.createOscillator();
      o.connect(ac.destination); o.start(); o.stop(ac.currentTime + 0.3);
    } catch {}
  });

  const failed = [];
  for (let n = 0; n < todo.length; n++) {
    const p = todo[n];
    console.log(`(${n + 1}/${todo.length}) ${p.fmt}: ${p.title}`);
    let win = window.open('about:blank', 'packt-download');
    if (!win) {
      console.warn('Pop-up blocked - allow pop-ups for subscription.packtpub.com and run again.');
      return 'Stopped: pop-ups blocked';
    }
    win = window.open(p.url, 'packt-download');
    await sleep(DELAY_MS);

    const state = tabState(win);
    if (state === 'challenge' || state === 'lost') {
      console.warn(`  Human check (${state === 'lost' ? 'download tab cut off' : 'check page'}) - paused.`);
      if (await waitForHuman() === 'retry') n--;  // retry this file
      else failed.push(p);
      continue;
    }
    if (state === 'page') {
      console.warn(`  failed: the server showed a page instead of a file (${win.document.title || 'untitled'})`);
      failed.push(p);
      continue;
    }
    markDone(p.key);
  }

  if (failed.length) {
    console.warn(`${failed.length} failed (not marked done, so a re-run will retry them):`);
    console.table(failed.map(({ title, fmt }) => ({ title, fmt })));
  }
  return `Finished: ${todo.length - failed.length} started, ${failed.length} failed - check Ctrl+J for any download errors`;
})();
