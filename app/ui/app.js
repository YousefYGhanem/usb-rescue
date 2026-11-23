'use strict';
// USB Rescue UI. All recovery work is done by Recover-UsbDrive.ps1; this file only shows its progress.
const T = window.__TAURI__ || mockTauri();   // the mock lets the UI run in a normal browser for design work
const invoke = T.core.invoke;
const $ = (id) => document.getElementById(id);

const S = { drives: [], sel: null, outDir: '', outFree: 0, loaded: false, running: false, stopped: false, carve: false, panel: true, stage: 0, r: {} };

const gb = (b) => (b >= 100 * 2 ** 30 ? Math.round(b / 2 ** 30) : (b / 2 ** 30).toFixed(1)) + ' GB';
const plural = (n, w) => n.toLocaleString() + ' ' + w + (n === 1 ? '' : 's');
const friendly = (m) => String(m || '').replace(/run the script again/gi, 'press Try again').replace(/^Exception[^:]*:\s*/, '');

// ---- screens and progress chrome ----
function show(id) {
  for (const s of document.querySelectorAll('.screen')) {
    if (s.id === id && s.hidden) { s.hidden = false; s.style.animation = 'none'; void s.offsetWidth; s.style.animation = ''; }
    else if (s.id !== id) s.hidden = true;
  }
  const working = id === 's-copy' || id === 's-work';
  $('panelBtn').hidden = !working;
  $('panel').hidden = !(working && S.panel);
}

// 0 choose, 1 safe copy, 2 repair, 3 your files, 4 done
function setStage(n) {
  S.stage = n;
  const k = Math.min(n, 3);
  [...$('dots').children].forEach((d, i) => { d.className = i === k ? 'on' : i < k ? 'past' : ''; });
  $('dots').setAttribute('aria-label', `Step ${k + 1} of 4`);
  [...$('timeline').children].forEach((li, i) => { li.className = i < n ? 'done' : i === n && S.running ? 'busy' : ''; });
}

function setRing(frac) {
  const ring = document.querySelector('.ring');
  ring.classList.toggle('indeterminate', frac == null);
  $('ringFill').style.strokeDashoffset = frac == null ? '' : String(603.2 * (1 - Math.min(frac, 1)));
  $('pct').textContent = frac == null ? '' : Math.floor(frac * 100) + '%';
}

function log(line) {
  const pre = $('log');
  pre.textContent = (pre.textContent + line + '\n').split('\n').slice(-300).join('\n');
  pre.scrollTop = pre.scrollHeight;
}

// ---- step 1: choose a drive ----
function renderDrives() {
  const box = $('drives');
  box.textContent = '';
  if (!S.drives.length) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.innerHTML = '<span class="spinner" aria-hidden="true"></span>';
    e.append(S.loaded ? 'Plug in the USB drive or SD card. It shows up here by itself.' : 'Looking for USB drives...');
    box.append(e);
  }
  for (const d of S.drives) {
    const b = document.createElement('button');
    b.className = 'drive' + (d.readable ? '' : ' bad');
    b.setAttribute('aria-pressed', String(d.number === S.sel));
    const letters = (d.letters || []).length ? '  /  Drive ' + d.letters.join(', ') + ':' : '';
    const status = d.size <= 0 ? 'Not responding' : d.readable ? 'Opens normally' : 'Needs rescue';
    for (const [cls, text] of [['name', d.name || 'USB drive'], ['meta', (d.size > 0 ? gb(d.size) : 'No media') + letters], ['status', status]]) {
      const s = document.createElement('span'); s.className = cls; s.textContent = text; b.append(s);
    }
    b.onclick = () => { S.sel = d.number; renderDrives(); };
    box.append(b);
  }
  $('startBtn').disabled = S.sel == null || S.running;
}

async function refresh() {
  if (S.running || $('s-pick').hidden) return;
  try {
    const r = await invoke('list_drives');
    S.drives = r.drives || [];
    if (r.version) $('ver').textContent = 'USB Rescue ' + r.version;
    if (!S.outDir) { S.outDir = r.outDir || ''; S.outFree = r.outFree || 0; renderOut(); }
    if (!S.drives.some((d) => d.number === S.sel)) {
      const pick = S.drives.find((d) => !d.readable && d.size > 0) || S.drives[0];
      S.sel = pick ? pick.number : null;
    }
  } catch (e) { S.drives = []; log(String(e)); }
  S.loaded = true;
  renderDrives();
}

function renderOut() {
  $('outDir').textContent = (S.outDir || 'not set') + (S.outFree ? `  (${gb(S.outFree)} free)` : '');
}

async function changeOut() {
  const p = await T.dialog.open({ directory: true, title: 'Choose where to save the rescued files' });
  if (!p) return;
  S.outDir = /UsbRecovery$/i.test(p) ? p : p.replace(/\\$/, '') + '\\UsbRecovery';
  S.outFree = 0;
  renderOut();
}

// ---- running a rescue ----
async function start(carve) {
  if (S.sel == null || S.running) return;
  Object.assign(S, { running: true, stopped: false, carve, r: {}, err: null });
  $('paused').hidden = true;
  $('stSpeed').textContent = '-'; $('stBad').textContent = '0 MB';
  const d = S.drives.find((x) => x.number === S.sel);
  if (d) $('tl0').textContent = `${d.name} (${gb(d.size)})`;
  copyScreen('Getting ready', 'Checking the drive before copying it.');
  setRing(null); $('copied').textContent = 'Starting';
  setStage(1);
  try { await invoke('start_rescue', { disk: S.sel, outDir: S.outDir, carve }); }
  catch (e) { S.running = false; showError(String(e)); }
}

function copyScreen(title, line) { $('copyTitle').textContent = title; $('copyLine').textContent = line; show('s-copy'); }
function workScreen(title, line, stoppable = true) { $('workTitle').textContent = title; $('workLine').textContent = line; $('stopBtn').hidden = !stoppable; show('s-work'); }

function onEvent(e) {
  switch (e.t) {
    case 'step': {
      const n = parseInt(e.name, 10);
      if (n === 2) { copyScreen('Copying your drive safely', 'Healthy parts first. Damaged parts get a careful second try at the end.'); setStage(1); }
      if (n === 3) { workScreen('Fixing the copy', 'Checking the partition table and boot sector...'); setStage(2); }
      if (n === 4) { workScreen('Bringing your files back', 'Copying files with their names and folders...'); setStage(3); $('tl3').textContent = 'Copying...'; }
      if (n === 5) { workScreen('Searching deeper', 'Looking for photos, documents and videos by their content. This can take a long time.'); setStage(3); $('tl3').textContent = 'Deep scan running'; }
      break;
    }
    case 'disk': $('tl0').textContent = `${e.name} (${gb(e.size)})`; break;
    case 'pass1': {
      const f = e.size ? e.pos / e.size : 0;
      setRing(f);
      $('copied').textContent = `${gb(e.pos)} of ${gb(e.size)}`;
      $('stSpeed').textContent = e.mbs + ' MB/s';
      $('stBad').textContent = e.damagedMB + ' MB';
      $('tl1').textContent = `${Math.floor(f * 100)}% copied, healthy parts first`;
      if (e.mbs > 0) {
        const s = (e.size - e.pos) / 2 ** 20 / e.mbs;
        $('copyLine').textContent = `About ${s > 90 ? Math.ceil(s / 60) + ' minutes' : Math.max(1, Math.round(s)) + ' seconds'} left. You can stop anytime and pick up later.`;
      }
      break;
    }
    case 'pass2':
      $('copyTitle').textContent = 'Retrying damaged areas';
      $('copyLine').textContent = 'Reading the damaged parts piece by piece. This part can be slow.';
      setRing(e.total ? e.done / e.total : 0);
      $('copied').textContent = `${e.done} of ${e.total} MB`;
      $('tl1').textContent = 'Second pass on damaged areas';
      break;
    case 'imaged': S.r.bad = e.badSectors; $('tl1').textContent = e.badSectors ? plural(e.badSectors, 'unreadable sector') : 'Every sector read fine'; break;
    case 'copied': Object.assign(S.r, { count: e.count, bytes: e.bytes, failed: e.failed }); $('tl3').textContent = plural(e.count, 'file') + ' copied'; break;
    case 'carved': S.r.carved = e.count; break;
    case 'done': S.r.done = true; S.r.outDir = e.outDir; break;
    case 'error': S.err = e.msg; break;
  }
}

function onLog(line) {
  log(line);
  if (S.stage !== 2) return;
  if (/rebuilt the table/i.test(line)) $('workLine').textContent = 'The partition table was missing: rebuilt it on the copy.';
  else if (/restored from the (\w+) backup/i.test(line)) $('workLine').textContent = `Boot sector restored from its ${RegExp.$1} backup copy.`;
  else if (/looks OK/i.test(line)) $('workLine').textContent = 'The file system looks OK. Opening the copy...';
}

function onExit(code) {
  S.running = false;
  if (S.r.done) return showDone();
  if (S.stopped) { show('s-pick'); setStage(0); $('paused').hidden = false; refresh(); return; }
  showError(S.err ? friendly(S.err) : `The rescue stopped unexpectedly (code ${code}). Open "Technical log" for details.`);
}

function showDone() {
  setStage(4);
  const { count = 0, carved = 0, bad = 0, failed } = S.r;
  const any = count + carved > 0;
  $('doneTitle').textContent = any ? 'All done. Your files are safe.' : "We couldn't find your files yet";
  let line = any
    ? `${plural(count, 'file')} came back with their names and folders` + (carved ? `, and ${carved.toLocaleString()} more were found by the deep scan.` : '.')
    : 'The drive is badly damaged. Search deeper looks for photos, documents and videos by their content.';
  if (bad) line += ' A few damaged spots could not be read; files stored there may be partly damaged.';
  else if (failed && any) line += ' Some files could not be copied; Search deeper may find them.';
  $('doneLine').textContent = line;
  $('openFilesBtn').hidden = !any;
  $('deepBtn').hidden = S.carve;
  show('s-done');
}

function showError(msg) {
  setStage(S.stage);
  $('errLine').textContent = msg;
  show('s-error');
}

function backToPick() { show('s-pick'); setStage(0); refresh(); }

// ---- wiring ----
$('startBtn').onclick = () => start(false);
$('changeBtn').onclick = changeOut;
$('pauseBtn').onclick = $('stopBtn').onclick = () => { S.stopped = true; invoke('stop_rescue'); };
$('openFilesBtn').onclick = () => invoke('open_path', { path: S.r.outDir || S.outDir }).catch((e) => showError(String(e)));
$('deepBtn').onclick = () => start(true);
$('againBtn').onclick = backToPick;
$('retryBtn').onclick = () => start(S.carve);
$('errBackBtn').onclick = backToPick;
$('helpBtn').onclick = () => invoke('open_path', { path: 'help' });
$('panelBtn').onclick = () => {
  S.panel = !S.panel;
  $('panel').hidden = !S.panel;
  $('panelBtn').setAttribute('aria-expanded', String(S.panel));
  $('panelBtn').querySelector('span').textContent = S.panel ? 'Hide details' : "What's happening";
};
T.event.listen('rescue-event', (e) => onEvent(e.payload));
T.event.listen('rescue-log', (e) => onLog(e.payload));
T.event.listen('rescue-exit', (e) => onExit(e.payload));
setStage(0);
renderDrives();
refresh();
setInterval(refresh, 5000);   // drives show up and disappear by themselves
window.addEventListener('focus', refresh);

// ---- browser-only stand-in for the Rust side, with a short fake rescue ----
function mockTauri() {
  const handlers = {};
  const emit = (n, p) => (handlers[n] || []).forEach((h) => h({ payload: p }));
  let timers = [];
  const at = (ms, f) => timers.push(setTimeout(f, ms));
  return {
    core: {
      async invoke(cmd, a) {
        if (cmd === 'list_drives') return { version: 'preview', outDir: 'D:\\UsbRecovery', outFree: 412 * 2 ** 30, drives: [
          { number: 2, name: 'Generic Flash Disk', size: 16 * 2 ** 30, letters: ['E'], readable: false },
          { number: 3, name: 'SanDisk Ultra', size: 64 * 2 ** 30, letters: ['F'], readable: true }] };
        if (cmd === 'stop_rescue') { timers.forEach(clearTimeout); timers = []; setTimeout(() => emit('rescue-exit', 1), 200); }
        if (cmd === 'start_rescue') {
          const size = 16 * 2 ** 30;
          at(300, () => emit('rescue-event', { t: 'disk', name: 'Generic Flash Disk', size }));
          at(900, () => emit('rescue-event', { t: 'step', name: '2/5 Image the drive (read-only)' }));
          for (let i = 1; i <= 50; i++) at(900 + i * 90, () => emit('rescue-event', { t: 'pass1', pos: size * i / 50, size, mbs: 18.4, damagedMB: 0 }));
          at(5600, () => emit('rescue-event', { t: 'imaged', badSectors: 0 }));
          at(5700, () => emit('rescue-event', { t: 'step', name: '3/5 Repair boot sectors on the copy' }));
          at(6900, () => emit('rescue-log', 'Partition at 1 MB : boot sector was damaged - restored from the FAT32 backup copy'));
          at(8200, () => emit('rescue-event', { t: 'step', name: '4/5 Mount the copy and copy files out' }));
          at(10000, () => emit('rescue-event', { t: 'copied', count: 1284, bytes: 3.2 * 2 ** 30, failed: false }));
          if (a.carve) at(10300, () => emit('rescue-event', { t: 'step', name: '5/5 Deep scan' }));
          if (a.carve) at(13000, () => emit('rescue-event', { t: 'carved', count: 312 }));
          at(a.carve ? 13200 : 10200, () => { emit('rescue-event', { t: 'done', outDir: 'D:\\UsbRecovery' }); emit('rescue-exit', 0); });
        }
      },
    },
    event: { listen: async (n, h) => { (handlers[n] = handlers[n] || []).push(h); } },
    dialog: { open: async () => 'E:\\Backups' },
  };
}
