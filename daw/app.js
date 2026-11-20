'use strict';
/* PocketDAW UI: project state, arrangement, piano roll, keys, mixer, storage. */

const $ = s => document.querySelector(s);
const el = (tag, props, kids) => {
  const e = document.createElement(tag);
  for (const k in (props || {})) {
    const v = props[k];
    if (k === 'text') e.textContent = v; else if (k === 'cls') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'style') e.style.cssText = v; else if (v !== false && v != null) e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of (kids || [])) e.append(c);
  return e;
};
const uid = () => Math.random().toString(36).slice(2, 10);
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const COLORS = ['#e5484d', '#f76b15', '#e2a600', '#46a758', '#12a594', '#3e8be0', '#8e5cd9', '#e93d82'];
const NOTE = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const isBlack = p => [1, 3, 6, 8, 10].includes(((p % 12) + 12) % 12);
const TYPE = { synth: 'SYN', drums: 'DRM', audio: 'AUD' };

const S = {
  proj: null, selTrack: null, selClip: null, selNotes: new Set(), pos: 0, tab: 'edit', grid: 0.25, lastLen: 0.5, oct: 4,
  metro: false, rec: null, undo: [], redo: [], snap: '', set: { countIn: true, quant: false, latMs: 0 },
};
let dirtyA = true, dirtyR = true;
const dirty = () => { dirtyA = dirtyR = true; };

/* ---------- storage ---------- */
const DB = {
  db: null,
  open() {
    return new Promise(res => {
      try {
        const r = indexedDB.open('pocketdaw', 1);
        r.onupgradeneeded = () => { const d = r.result; d.createObjectStore('projects', { keyPath: 'id' }); d.createObjectStore('audio', { keyPath: 'id' }); d.createObjectStore('meta', { keyPath: 'k' }); };
        r.onsuccess = () => { this.db = r.result; res(true); };
        r.onerror = r.onblocked = () => res(false);
      } catch (e) { res(false); }
    });
  },
  tx(store, mode, fn) {
    return new Promise(res => {
      if (!this.db) return res(undefined);
      try { const rq = fn(this.db.transaction(store, mode).objectStore(store)); rq.onsuccess = () => res(rq.result); rq.onerror = () => res(undefined); }
      catch (e) { res(undefined); }
    });
  },
  get(s, k) { return this.tx(s, 'readonly', o => o.get(k)); },
  put(s, v) { return this.tx(s, 'readwrite', o => o.put(v)); },
  del(s, k) { return this.tx(s, 'readwrite', o => o.delete(k)); },
  all(s) { return this.tx(s, 'readonly', o => o.getAll()); },
  keys(s) { return this.tx(s, 'readonly', o => o.getAllKeys()); },
};
let saveT = 0;
function save() {
  clearTimeout(saveT);
  saveT = setTimeout(() => { S.proj.saved = Date.now(); DB.put('projects', JSON.parse(JSON.stringify(S.proj))); DB.put('meta', { k: 'last', v: S.proj.id }); }, 400);
}
const saveSet = () => DB.put('meta', { k: 'set', v: S.set });

/* ---------- project model ---------- */
function mkTrack(type, name, preset) {
  const n = S.proj ? S.proj.tracks.length : 0;
  const t = { id: uid(), name, type, color: COLORS[n % COLORS.length], vol: 0.8, pan: 0, mute: false, solo: false, rev: type === 'drums' ? 0.04 : 0.12, dly: 0, clips: [] };
  if (type === 'synth') t.inst = Object.assign({ preset }, PRESETS[preset]);
  return t;
}
function newProject(name) {
  return { id: uid(), name: name || '新しい曲', bpm: 120, master: 0.9, loop: { on: false, start: 0, end: 16 }, tracks: [], saved: Date.now() };
}
function demoProject() {
  const p = newProject('デモ曲'); p.bpm = 104; p.loop = { on: true, start: 0, end: 32 };
  const save0 = S.proj; S.proj = p;
  const dr = mkTrack('drums', 'ドラム'), bs = mkTrack('synth', 'ベース', 'ベース'), ch = mkTrack('synth', 'コード', 'エレピ'), ld = mkTrack('synth', 'メロディ', 'プラック');
  p.tracks.push(dr); bs.color = COLORS[1]; p.tracks.push(bs); ch.color = COLORS[5]; p.tracks.push(ch); ld.color = COLORS[3]; p.tracks.push(ld);
  S.proj = save0;
  const N = (pp, t, d, v) => ({ p: pp, t, d, v: v == null ? 0.8 : v });
  const dn = [];
  for (let b = 0; b < 16; b++) {
    if (b % 4 === 0 || b % 8 === 5) dn.push(N(36, b, 0.25, 0.95));
    if (b % 8 === 2) dn.push(N(36, b + 0.5, 0.25, 0.8));
    if (b % 2 === 1) dn.push(N(38, b, 0.25, 0.9));
    dn.push(N(42, b, 0.25, 0.7)); dn.push(N(b % 4 === 3 ? 46 : 42, b + 0.5, 0.25, 0.5));
  }
  dn.push(N(39, 15.5, 0.25, 0.7));
  dr.clips.push({ id: uid(), start: 0, len: 16, notes: dn }, { id: uid(), start: 16, len: 16, notes: JSON.parse(JSON.stringify(dn)) });
  const roots = [45, 41, 48, 43], bn = [], cn = [];
  const tri = [[57, 60, 64], [57, 60, 65], [55, 60, 64], [55, 59, 62]];
  roots.forEach((r, i) => {
    const o = i * 4;
    bn.push(N(r - 12, o, 0.75), N(r - 12, o + 1, 0.4, 0.6), N(r, o + 1.5, 0.4, 0.7), N(r - 12, o + 2.5, 0.5), N(r - 12, o + 3.5, 0.4, 0.6));
    tri[i].forEach(pp => { cn.push(N(pp, o, 1.5, 0.55), N(pp, o + 2.5, 1.25, 0.5)); });
  });
  bs.clips.push({ id: uid(), start: 0, len: 16, notes: bn }, { id: uid(), start: 16, len: 16, notes: JSON.parse(JSON.stringify(bn)) });
  ch.clips.push({ id: uid(), start: 0, len: 16, notes: cn }, { id: uid(), start: 16, len: 16, notes: JSON.parse(JSON.stringify(cn)) });
  const mel = [[76, 0, 1], [72, 1, 0.5], [74, 1.5, 0.5], [76, 2, 1.5], [69, 4, 1], [72, 5, 0.5], [77, 5.5, 1], [76, 6.5, 1], [79, 8, 1], [76, 9, 0.5], [72, 9.5, 0.5], [74, 10, 1.5], [71, 12, 1], [74, 13, 0.5], [79, 13.5, 1], [74, 14.5, 1.25]];
  ld.clips.push({ id: uid(), start: 16, len: 16, notes: mel.map(m => N(m[0], m[1], m[2], 0.75)) });
  ld.dly = 0.3; ch.rev = 0.25;
  return p;
}
const track = id => S.proj.tracks.find(t => t.id === id);
const selTrack = () => track(S.selTrack) || null;
function selClip() {
  for (const tr of S.proj.tracks) { const cl = tr.clips.find(c => c.id === S.selClip); if (cl) return { tr, cl }; }
  return null;
}
const cLen = cl => clipLenBeats(cl, S.proj.bpm);

function commit() {
  S.undo.push(S.snap); if (S.undo.length > 60) S.undo.shift();
  S.redo = []; S.snap = JSON.stringify(S.proj); save(); Engine.sync(); refresh();
}
function restore(json) {
  S.snap = json; S.proj = JSON.parse(json); Engine.proj = S.proj; S.selNotes = new Set();
  if (!track(S.selTrack)) S.selTrack = S.proj.tracks[0] ? S.proj.tracks[0].id : null;
  if (!selClip()) S.selClip = null;
  save(); Engine.sync(); refresh();
}
function undo() { if (!S.undo.length) return; S.redo.push(S.snap); restore(S.undo.pop()); }
function redo() { if (!S.redo.length) return; S.undo.push(S.snap); restore(S.redo.pop()); }

async function loadProject(p) {
  if (S.proj) stopAll();
  S.proj = p; Engine.proj = p; S.undo = []; S.redo = []; S.snap = JSON.stringify(p); S.pos = 0;
  S.selTrack = p.tracks[0] ? p.tracks[0].id : null; S.selClip = null; S.selNotes = new Set();
  A.sx = 0; A.sy = 0;
  for (const t of p.tracks) for (const c of t.clips) if (c.audioId && !Engine.buffers.has(c.audioId)) {
    const a = await DB.get('audio', c.audioId); if (a) Engine.setAudio(a.id, a.ch, a.sr);
  }
  Engine.sync(); DB.put('meta', { k: 'last', v: p.id }); refresh();
}

/* ---------- small UI helpers ---------- */
let toastT = 0;
function toast(msg) {
  let t = $('#toast'); if (!t) { t = el('div', { id: 'toast' }); document.body.append(t); }
  t.textContent = msg; t.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => { t.hidden = true; }, 2600);
}
function closeDlg() { const o = $('#ovl'); if (o) o.remove(); }
function dialog(title, build) {
  closeDlg();
  const d = el('div', { id: 'dlg', role: 'dialog', 'aria-label': title }, [el('h3', { text: title })]);
  const o = el('div', { id: 'ovl', onclick: e => { if (e.target === o) closeDlg(); } }, [d]);
  build(d); document.body.append(o); return d;
}
const btn = (text, fn, cls) => el('button', { text, cls: cls || '', onclick: fn });
function confirmDlg(title, msg, okText, fn) {
  dialog(title, d => { d.append(el('p', { text: msg }), el('div', { cls: 'acts' }, [btn('キャンセル', closeDlg), btn(okText, () => { closeDlg(); fn(); }, 'pri')])); });
}
function promptDlg(title, val, fn) {
  dialog(title, d => {
    const i = el('input', { type: 'text', id: 'dlgText', value: val, maxlength: 40 });
    const ok = () => { const v = i.value.trim(); closeDlg(); if (v) fn(v); };
    i.addEventListener('keydown', e => { if (e.key === 'Enter') ok(); });
    d.append(i, el('div', { cls: 'acts' }, [btn('キャンセル', closeDlg), btn('OK', ok, 'pri')]));
    setTimeout(() => i.focus(), 50);
  });
}
let cssCache = {};
const css = n => cssCache[n] || (cssCache[n] = getComputedStyle(document.documentElement).getPropertyValue(n).trim());
const dropCss = () => { cssCache = {}; dirty(); };
try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', dropCss); } catch (e) {}
new MutationObserver(dropCss).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

function fit(cv) {
  const r = cv.parentElement.getBoundingClientRect(), d = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.round(r.width)), h = Math.max(1, Math.round(r.height));
  if (cv.width !== Math.round(w * d) || cv.height !== Math.round(h * d)) { cv.width = Math.round(w * d); cv.height = Math.round(h * d); }
  const c = cv.getContext('2d'); c.setTransform(d, 0, 0, d, 0, 0); return { w, h, c };
}
function rr(c, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2); c.beginPath(); c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r);
  c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath();
}

/* Pointer gestures: start() may return a drag {move,end}; tap/dbl/long/pinch are optional. */
function gestures(elm, h) {
  const pts = new Map(); let drag = null, sx = 0, sy = 0, moved = false, longed = false, lastTap = 0, lx = 0, ly = 0, pd = 0, lp = 0;
  const xy = e => { const r = elm.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  const dist = () => { const a = [...pts.values()]; return Math.hypot(a[0][0] - a[1][0], a[0][1] - a[1][1]) || 1; };
  elm.addEventListener('pointerdown', e => {
    e.preventDefault(); try { elm.setPointerCapture(e.pointerId); } catch (x) {}
    const p = xy(e); pts.set(e.pointerId, p);
    if (pts.size === 1) {
      moved = false; longed = false; sx = p[0]; sy = p[1]; drag = h.start ? h.start(sx, sy) : null;
      clearTimeout(lp);
      if (h.long) lp = setTimeout(() => { if (!moved && pts.size === 1) { const d = h.long(sx, sy); if (d) { drag = d; longed = true; } } }, 420);
    } else if (pts.size === 2) { clearTimeout(lp); if (drag && drag.end && moved) drag.end(); drag = null; moved = true; pd = dist(); }
  });
  elm.addEventListener('pointermove', e => {
    if (!pts.has(e.pointerId)) return;
    const p = xy(e); pts.set(e.pointerId, p);
    if (pts.size === 2) { const d = dist(), a = [...pts.values()]; if (h.pinch) h.pinch(d / pd, (a[0][0] + a[1][0]) / 2, (a[0][1] + a[1][1]) / 2); pd = d; return; }
    if (!moved && Math.hypot(p[0] - sx, p[1] - sy) > 7) { moved = true; clearTimeout(lp); }
    if ((moved || longed) && drag && drag.move) drag.move(p[0], p[1], p[0] - sx, p[1] - sy);
  });
  const up = e => {
    if (!pts.has(e.pointerId)) return;
    const p = xy(e); pts.delete(e.pointerId);
    if (pts.size) return;
    clearTimeout(lp);
    if (moved || longed) { if (drag && drag.end) drag.end(); }
    else if (e.type === 'pointerup') {
      if (drag && drag.end) drag.end(true);
      const now = performance.now();
      if (now - lastTap < 330 && Math.hypot(p[0] - lx, p[1] - ly) < 24 && h.dbl) { lastTap = 0; h.dbl(p[0], p[1]); }
      else { lastTap = now; lx = p[0]; ly = p[1]; if (h.tap) h.tap(p[0], p[1]); }
    }
    drag = null;
  };
  elm.addEventListener('pointerup', up); elm.addEventListener('pointercancel', up);
  elm.addEventListener('wheel', e => {
    e.preventDefault();
    if (e.ctrlKey && h.pinch) { const p = xy(e); h.pinch(Math.exp(-e.deltaY / 200), p[0], p[1]); }
    else if (h.wheel) h.wheel(e.deltaX, e.deltaY);
  }, { passive: false });
}

/* ---------- transport ---------- */
function setPos(b) { S.pos = Math.max(0, b); if (Engine.playing && !S.rec) Engine.start(S.pos); dirty(); updTime(); }
function play() {
  if (Engine.playing) return stopAll();
  Engine.ensure(); Engine.metro = S.metro; Engine.countInEnd = -Infinity; Engine.recording = false;
  const e = projEndBeat(S.proj), L = S.proj.loop;
  if (!(L.on && S.pos < L.end) && e > 0 && S.pos >= e) S.pos = 0;
  Engine.start(S.pos); updTransport();
}
function stopAll() {
  if (Engine.playing) S.pos = Math.max(0, Engine.pos());
  Engine.stop(); Engine.recording = false;
  for (const k of [...live.keys()]) liveOff(k);
  if (S.rec) finishRec();
  updTransport(); dirty(); updTime();
}
async function record() {
  if (S.rec) return stopAll();
  const tr = selTrack(); if (!tr) return toast('録音するトラックを選んでください');
  if (Engine.playing) stopAll();
  Engine.ensure();
  if (tr.type === 'audio') {
    try { await Engine.micStart(); } catch (e) { return toast('マイクを使用できません。ブラウザの許可を確認するか、オーディオ読み込みを使ってください'); }
  }
  const start = S.pos, pre = S.set.countIn ? 4 : 0;
  S.rec = { tr: tr.id, start, notes: [], held: new Map(), startTime: 0 };
  Engine.metro = S.metro; Engine.countInEnd = start; Engine.recording = true;
  Engine.start(start - pre);
  S.rec.startTime = Engine.timeAt(start);
  if (tr.type !== 'audio' && S.tab !== 'keys') setTab('keys');
  updTransport();
}
function finishRec() {
  const r = S.rec; S.rec = null; const tr = track(r.tr); if (!tr) return;
  const spb = 60 / S.proj.bpm;
  if (tr.type !== 'audio') {
    const notes = r.notes.filter(n => n.t >= r.start - 0.15).map(n => Object.assign({}, n, { t: Math.max(r.start, n.t) }));
    if (!notes.length) return toast('ノートは録音されませんでした');
    const cs = Math.floor(r.start / 4) * 4; let last = 0;
    const out = notes.map(n => {
      let t = n.t - cs, d = n.d;
      if (S.set.quant) { t = Math.round(t / S.grid) * S.grid; d = Math.max(S.grid, Math.round(d / S.grid) * S.grid); }
      last = Math.max(last, t + d); return { p: n.p, t, d, v: n.v };
    });
    const cl = { id: uid(), start: cs, len: Math.max(4, Math.ceil((last - 0.01) / 4) * 4), notes: out };
    tr.clips.push(cl); S.selClip = cl.id; S.selNotes = new Set(); commit();
  } else {
    const m = Engine.micStop(); if (!m) return;
    const c = Engine.ctx, lat = (c.outputLatency || 0) + (c.baseLatency || 0) + S.set.latMs / 1000;
    let skip = Math.round((r.startTime - m.t0 + lat) * m.sr), start = r.start;
    if (skip < 0) { start += (-skip / m.sr) / spb; skip = 0; }
    const data = m.data.slice(skip);
    if (data.length < m.sr * 0.15) return toast('録音が短すぎます');
    const id = S.proj.id + ':' + uid();
    DB.put('audio', { id, sr: m.sr, ch: [data] }); Engine.setAudio(id, [data], m.sr);
    const cl = { id: uid(), start, audioId: id, off: 0, dur: data.length / m.sr, gain: 1, name: '録音' };
    tr.clips.push(cl); S.selClip = cl.id; commit();
  }
}
function updTransport() {
  $('#bPlay').textContent = Engine.playing ? '■' : '▶\uFE0E';
  $('#bPlay').classList.toggle('on', Engine.playing && !S.rec);
  $('#bRec').classList.toggle('on', !!S.rec);
  $('#bLoop').classList.toggle('on', S.proj.loop.on);
  $('#bMetro').classList.toggle('on', S.metro);
}
function updTime() {
  const b = Math.max(0, S.pos), s = b * 60 / S.proj.bpm;
  const txt = (Math.floor(b / 4) + 1) + '.' + (Math.floor(b % 4) + 1) + '.' + (Math.floor((b % 1) * 4 + 1e-6) + 1);
  const t = $('#time');
  if (t.firstChild.nodeValue !== txt) t.firstChild.nodeValue = txt;
  const st = Math.floor(s / 60) + ':' + (s % 60 < 10 ? '0' : '') + (s % 60).toFixed(1);
  if (t.lastChild.textContent !== st) t.lastChild.textContent = st;
}

/* ---------- arrangement ---------- */
const A = { ppb: 22, sx: 0, sy: 0, RUL: 26, TH: 56, w: 0, h: 0 };
const arrCv = $('#arrCv');
const snapA = () => (A.ppb >= 44 ? 0.25 : A.ppb >= 13 ? 1 : 4);
function drawArr() {
  const { w, h, c } = fit(arrCv), p = S.proj, T = p.tracks, { RUL, TH, ppb } = A;
  A.w = w; A.h = h;
  A.sy = clamp(A.sy, 0, Math.max(0, T.length * TH - (h - RUL))); A.sx = Math.max(0, A.sx);
  $('#headsIn').style.transform = 'translateY(' + (-A.sy) + 'px)';
  c.fillStyle = css('--bg'); c.fillRect(0, 0, w, h);
  T.forEach((t, i) => {
    const y = RUL + i * TH - A.sy; if (y > h || y + TH < RUL) return;
    c.fillStyle = css(t.id === S.selTrack ? '--lane2' : '--lane'); c.fillRect(0, y, w, TH - 1);
  });
  const b0 = Math.floor(A.sx / ppb);
  for (let b = b0; b * ppb - A.sx < w; b++) {
    const bar = b % 4 === 0; if (!bar && ppb < 12) continue; if (ppb < 4.5 && b % 16) continue;
    const x = Math.round(b * ppb - A.sx) + 0.5;
    c.strokeStyle = css(bar ? '--gridbar' : '--grid'); c.beginPath(); c.moveTo(x, RUL); c.lineTo(x, h); c.stroke();
  }
  c.font = '600 11px ' + css('--ui'); c.textBaseline = 'middle';
  const spb = 60 / p.bpm;
  T.forEach((t, i) => {
    const y = RUL + i * TH - A.sy + 3, ch = TH - 7; if (y > h || y + ch < RUL) return;
    for (const cl of t.clips) {
      const x = cl.start * ppb - A.sx, cw = Math.max(4, cLen(cl) * ppb - 1); if (x > w || x + cw < 0) continue;
      const sel = cl.id === S.selClip;
      c.globalAlpha = sel ? 1 : 0.78; c.fillStyle = t.color; rr(c, x, y, cw, ch, 5); c.fill(); c.globalAlpha = 1;
      c.save(); rr(c, x, y, cw, ch, 5); c.clip();
      c.fillStyle = 'rgba(0,0,0,.28)'; c.fillRect(x, y, cw, 15);
      c.fillStyle = '#fff'; c.fillText(cl.name || t.name, x + 5, y + 8);
      c.fillStyle = 'rgba(255,255,255,.92)';
      if (cl.audioId) {
        const pk = Engine.peaks.get(cl.audioId), mid = y + 15 + (ch - 15) / 2, hh = (ch - 19) / 2;
        if (pk) for (let px = Math.max(0, Math.floor(x)); px < Math.min(w, x + cw); px += 2) {
          const a = pk[Math.floor(((cl.off || 0) + (px - x) / ppb * spb) * 100)] || 0, v = Math.max(1, Math.min(1, a * (cl.gain == null ? 1 : cl.gain)) * hh);
          c.fillRect(px, mid - v, 1.4, v * 2);
        }
      } else if (cl.notes.length) {
        let lo = 127, hi = 0; for (const n of cl.notes) { if (n.p < lo) lo = n.p; if (n.p > hi) hi = n.p; }
        const span = Math.max(6, hi - lo), bh = ch - 21;
        for (const n of cl.notes) if (n.t < cl.len) c.fillRect(x + n.t * ppb, y + 17 + bh - (n.p - lo) / span * bh, Math.max(2, Math.min(n.d, cl.len - n.t) * ppb - 1), 2.5);
      }
      c.restore();
      if (sel) { c.strokeStyle = css('--sel'); c.lineWidth = 2; rr(c, x + 1, y + 1, cw - 2, ch - 2, 4); c.stroke(); c.lineWidth = 1;
        c.fillStyle = css('--sel'); c.fillRect(x + cw - 6, y + ch / 2 - 8, 2.5, 16); }
    }
    if (S.rec && S.rec.tr === t.id && S.pos > S.rec.start) {
      c.globalAlpha = 0.5; c.fillStyle = css('--rec'); rr(c, S.rec.start * ppb - A.sx, y, (S.pos - S.rec.start) * ppb, ch, 5); c.fill(); c.globalAlpha = 1;
    }
  });
  // ruler
  c.fillStyle = css('--panel'); c.fillRect(0, 0, w, RUL);
  const L = p.loop;
  if (L.on) { c.fillStyle = css('--accent'); c.globalAlpha = 0.3; c.fillRect(L.start * ppb - A.sx, 0, (L.end - L.start) * ppb, RUL); c.globalAlpha = 1;
    c.fillRect(L.start * ppb - A.sx, 0, 3, RUL); c.fillRect(L.end * ppb - A.sx - 3, 0, 3, RUL); }
  c.fillStyle = css('--dim'); c.font = '10px ' + css('--mono');
  const every = ppb * 4 >= 34 ? 1 : ppb * 4 >= 17 ? 2 : ppb * 4 >= 9 ? 4 : 8;
  for (let bar = Math.floor(b0 / 4); bar * 4 * ppb - A.sx < w; bar++) if (bar % every === 0) c.fillText(String(bar + 1), bar * 4 * ppb - A.sx + 4, RUL / 2);
  c.strokeStyle = css('--line'); c.beginPath(); c.moveTo(0, RUL - 0.5); c.lineTo(w, RUL - 0.5); c.stroke();
  const px = Math.round(S.pos * ppb - A.sx) + 0.5;
  if (px >= 0 && px <= w) { c.strokeStyle = css('--accent'); c.lineWidth = 1.5; c.beginPath(); c.moveTo(px, 0); c.lineTo(px, h); c.stroke(); c.lineWidth = 1;
    c.fillStyle = css('--accent'); c.beginPath(); c.moveTo(px - 6, 0); c.lineTo(px + 6, 0); c.lineTo(px, 9); c.fill(); }
}
function clipAt(x, y) {
  const i = Math.floor((y - A.RUL + A.sy) / A.TH), tr = S.proj.tracks[i]; if (!tr || y < A.RUL) return null;
  for (let k = tr.clips.length - 1; k >= 0; k--) {
    const cl = tr.clips[k], x0 = cl.start * A.ppb - A.sx, x1 = x0 + cLen(cl) * A.ppb;
    if (x >= x0 - 2 && x <= x1 + 4) return { tr, cl, edge: x > x1 - Math.min(18, (x1 - x0) * 0.35) };
  }
  return { tr, cl: null };
}
function zoomArr(f, cx) {
  cx = cx == null ? A.w / 2 : cx; const b = (cx + A.sx) / A.ppb;
  A.ppb = clamp(A.ppb * f, 3, 170); A.sx = Math.max(0, b * A.ppb - cx); dirtyA = true;
}
gestures(arrCv, {
  start(x, y) {
    const p = S.proj, sn = snapA(), beat = xx => Math.max(0, Math.round((xx + A.sx) / A.ppb / sn) * sn);
    if (y < A.RUL) {
      const L = p.loop;
      if (L.on) for (const k of ['end', 'start']) if (Math.abs(L[k] * A.ppb - A.sx - x) < 16)
        return { move(xx) { const b = beat(xx); if (k === 'start') L.start = Math.min(b, L.end - sn); else L.end = Math.max(b, L.start + sn); dirtyA = true; }, end(tap) { if (!tap) commit(); } };
      return { move(xx) { setPos(beat(xx)); }, end(tap) { if (tap) setPos(beat(x)); } };
    }
    const hit = clipAt(x, y);
    if (hit && hit.cl && hit.cl.id === S.selClip) {
      const cl = hit.cl, o = { start: cl.start, len: cl.len, dur: cl.dur }; let tr = hit.tr, ch = false;
      if (hit.edge) return {
        move(xx, yy, dx) {
          ch = true;
          if (cl.audioId) { const b = Engine.buffers.get(cl.audioId); cl.dur = clamp(o.dur + dx / A.ppb * 60 / p.bpm, 0.05, (b ? b.duration : o.dur) - (cl.off || 0)); }
          else cl.len = Math.max(sn, Math.round((o.len + dx / A.ppb) / sn) * sn);
          dirty();
        }, end() { if (ch) commit(); } };
      return {
        move(xx, yy, dx) {
          ch = true; cl.start = Math.max(0, Math.round((o.start + dx / A.ppb) / sn) * sn);
          const t2 = p.tracks[Math.floor((yy - A.RUL + A.sy) / A.TH)];
          if (t2 && t2 !== tr && (t2.type === 'audio') === (tr.type === 'audio')) { tr.clips.splice(tr.clips.indexOf(cl), 1); t2.clips.push(cl); tr = t2; S.selTrack = t2.id; renderHeads(); }
          dirty();
        }, end() { if (ch) commit(); } };
    }
    const o = { sx: A.sx, sy: A.sy };
    return { move(xx, yy, dx, dy) { A.sx = Math.max(0, o.sx - dx); A.sy = o.sy - dy; dirtyA = true; } };
  },
  tap(x, y) {
    if (y < A.RUL) return;
    const hit = clipAt(x, y); if (!hit) { S.selClip = null; return refresh(); }
    S.selTrack = hit.tr.id; S.selClip = hit.cl ? hit.cl.id : null; S.selNotes = new Set(); refresh();
  },
  dbl(x, y) {
    if (y < A.RUL) return;
    const hit = clipAt(x, y); if (!hit) return;
    if (hit.cl) { S.selTrack = hit.tr.id; S.selClip = hit.cl.id; openPanel('edit'); }
    else { S.selTrack = hit.tr.id; addClip(Math.floor((x + A.sx) / A.ppb / 4) * 4); }
  },
  pinch(s, cx) { zoomArr(s, cx); },
  wheel(dx, dy) { A.sx = Math.max(0, A.sx + dx); A.sy += dy; dirtyA = true; },
});

function renderHeads() {
  const box = $('#headsIn'); box.textContent = '';
  for (const t of S.proj.tracks) {
    const h = el('div', { cls: 'head' + (t.id === S.selTrack ? ' sel' : ''), style: '--c:' + t.color, onclick: () => { S.selTrack = t.id; if (!t.clips.some(c => c.id === S.selClip)) S.selClip = null; refresh(); } }, [
      el('div', { cls: 'nm', text: t.name }),
      el('div', { cls: 'ms' }, [
        el('button', { text: 'M', cls: 'm' + (t.mute ? ' on' : ''), 'aria-label': 'ミュート', onclick: e => { e.stopPropagation(); t.mute = !t.mute; commit(); } }),
        el('button', { text: 'S', cls: t.solo ? 'on' : '', 'aria-label': 'ソロ', onclick: e => { e.stopPropagation(); t.solo = !t.solo; commit(); } }),
        el('span', { cls: 'ty', text: TYPE[t.type] }),
      ]),
    ]);
    box.append(h);
  }
}

/* ---------- clip & track actions ---------- */
function addClip(at) {
  const tr = selTrack(); if (!tr) return toast('先にトラックを追加してください');
  if (tr.type === 'audio') return importAudio();
  const start = at == null ? Math.floor(S.pos / 4) * 4 : at;
  const cl = { id: uid(), start, len: 4, notes: [] };
  tr.clips.push(cl); S.selClip = cl.id; S.selNotes = new Set(); commit(); openPanel('edit');
}
function dupClip() {
  const s = selClip(); if (!s) return toast('クリップを選んでください');
  const c2 = JSON.parse(JSON.stringify(s.cl)); c2.id = uid(); c2.start = s.cl.start + Math.max(snapA(), Math.ceil(cLen(s.cl) / snapA() - 1e-6) * snapA());
  s.tr.clips.push(c2); S.selClip = c2.id; S.selNotes = new Set(); commit();
}
function splitClip() {
  const s = selClip(); if (!s) return toast('クリップを選んでください');
  const cl = s.cl, rel = S.pos - cl.start;
  if (rel <= 0.01 || rel >= cLen(cl) - 0.01) return toast('再生位置をクリップの途中に置いてください');
  const c2 = JSON.parse(JSON.stringify(cl)); c2.id = uid(); c2.start = S.pos;
  if (cl.audioId) { const sec = rel * 60 / S.proj.bpm; c2.off = (cl.off || 0) + sec; c2.dur = cl.dur - sec; cl.dur = sec; }
  else { c2.notes = cl.notes.filter(n => n.t >= rel).map(n => Object.assign({}, n, { t: n.t - rel })); c2.len = cl.len - rel; cl.notes = cl.notes.filter(n => n.t < rel); cl.len = rel; }
  s.tr.clips.push(c2); S.selNotes = new Set(); commit();
}
function delSel() {
  const s = selClip();
  if (s) { s.tr.clips.splice(s.tr.clips.indexOf(s.cl), 1); S.selClip = null; S.selNotes = new Set(); return commit(); }
  const tr = selTrack(); if (!tr) return;
  confirmDlg('トラックを削除', '「' + tr.name + '」とその中のクリップをすべて削除します。', '削除', () => {
    S.proj.tracks.splice(S.proj.tracks.indexOf(tr), 1); S.selTrack = S.proj.tracks[0] ? S.proj.tracks[0].id : null; commit();
  });
}
function addTrackDlg() {
  dialog('トラックを追加', d => {
    const add = (type, name, preset) => () => { closeDlg(); const t = mkTrack(type, name, preset); S.proj.tracks.push(t); S.selTrack = t.id; S.selClip = null; commit(); A.sy = 1e9; };
    d.append(el('div', { cls: 'list' }, [
      btn('シンセ　鍵盤で弾く・ピアノロールで打ち込む', add('synth', 'シンセ', 'エレピ')),
      btn('ドラム　12パーツのドラムキット', add('drums', 'ドラム')),
      btn('オーディオ　マイク録音・音声ファイル', add('audio', 'オーディオ')),
    ]), el('div', { cls: 'acts' }, [btn('閉じる', closeDlg)]));
  });
}
function importAudio() { Engine.ensure(); const f = $('#fileIn'); f.value = ''; f.click(); }
$('#fileIn').addEventListener('change', async e => {
  const file = e.target.files[0]; if (!file) return;
  toast('読み込み中…');
  try {
    const ctx = Engine.ensure(), ab = await file.arrayBuffer();
    const buf = await new Promise((res, rej) => { const pr = ctx.decodeAudioData(ab, res, rej); if (pr && pr.catch) pr.catch(rej); });
    const ch = []; for (let i = 0; i < Math.min(2, buf.numberOfChannels); i++) ch.push(new Float32Array(buf.getChannelData(i)));
    const id = S.proj.id + ':' + uid(); DB.put('audio', { id, sr: buf.sampleRate, ch }); Engine.setAudio(id, ch, buf.sampleRate);
    let tr = selTrack();
    if (!tr || tr.type !== 'audio') { tr = mkTrack('audio', 'オーディオ'); S.proj.tracks.push(tr); S.selTrack = tr.id; }
    const cl = { id: uid(), start: S.pos, audioId: id, off: 0, dur: buf.duration, gain: 1, name: file.name.replace(/\.[^.]+$/, '').slice(0, 24) };
    tr.clips.push(cl); S.selClip = cl.id; commit(); toast('読み込みました');
  } catch (err) { toast('この音声ファイルは読み込めませんでした'); }
});

/* ---------- piano roll ---------- */
const R = { ppb: 56, sx: 0, sy: 0, KW: 46, RH: 18, w: 0, h: 0, clip: null, box: null };
const rollCv = $('#rollCv');
function rowsOf(tr) { if (tr.type === 'drums') return DRUMS.map(d => d.p).reverse(); const a = []; for (let p = 108; p >= 24; p--) a.push(p); return a; }
function drawRoll() {
  const s = selClip(); if (!s || s.cl.audioId || S.tab !== 'edit') return;
  const { w, h, c } = fit(rollCv), { tr, cl } = s, rows = rowsOf(tr), drums = tr.type === 'drums';
  R.w = w; R.h = h; R.RH = drums ? Math.max(24, Math.min(34, Math.floor(h / rows.length))) : 18;
  const { KW, RH, ppb } = R;
  if (R.clip !== cl.id) {
    R.clip = cl.id; R.sx = 0;
    const ps = cl.notes.map(n => n.p), mid = ps.length ? (Math.min(...ps) + Math.max(...ps)) / 2 : 62;
    R.sy = drums ? 1e9 : (rows.indexOf(Math.round(mid)) + 0.5) * RH - h / 2;
  }
  R.sy = clamp(R.sy, 0, Math.max(0, rows.length * RH - h)); R.sx = Math.max(0, R.sx);
  c.fillStyle = css('--lane'); c.fillRect(0, 0, w, h);
  const r0 = Math.floor(R.sy / RH);
  for (let r = r0; r < rows.length && r * RH - R.sy < h; r++) {
    const y = r * RH - R.sy, p = rows[r];
    if (drums ? r % 2 : isBlack(p)) { c.fillStyle = css('--lane2'); c.fillRect(KW, y, w, RH); c.fillStyle = css('--grid'); c.globalAlpha = 0.6; c.fillRect(KW, y, w, RH); c.globalAlpha = 1; }
    if (!drums && p % 12 === 0) { c.fillStyle = css('--gridbar'); c.fillRect(KW, y + RH - 1, w, 1); }
  }
  const g = S.grid, gpx = g * ppb, st = gpx >= 7 ? g : 1;
  for (let k = Math.floor(R.sx / ppb / st); k * st * ppb - R.sx < w; k++) {
    const b = k * st, x = Math.round(KW + b * ppb - R.sx) + 0.5; if (x < KW) continue;
    const onBeat = Math.abs(b - Math.round(b)) < 1e-6, bar = onBeat && Math.round(b) % 4 === 0;
    c.strokeStyle = css(bar ? '--gridbar' : '--grid'); c.globalAlpha = bar || onBeat ? 1 : 0.55; c.lineWidth = bar ? 1.5 : 1;
    c.beginPath(); c.moveTo(x, 0); c.lineTo(x, h); c.stroke();
  }
  c.globalAlpha = 1; c.lineWidth = 1;
  const xe = KW + cl.len * ppb - R.sx;
  if (xe < w) { c.fillStyle = css('--bg'); c.globalAlpha = 0.72; c.fillRect(Math.max(KW, xe), 0, w, h); c.globalAlpha = 1; }
  for (const n of cl.notes) {
    const r = rows.indexOf(n.p); if (r < 0) continue;
    const x = KW + n.t * ppb - R.sx, y = r * RH - R.sy, nw = Math.max(4, n.d * ppb - 1); if (x > w || x + nw < KW || y > h || y + RH < 0) continue;
    c.globalAlpha = 0.45 + n.v * 0.55; c.fillStyle = tr.color; rr(c, x, y + 1, nw, RH - 2, 3); c.fill(); c.globalAlpha = 1;
    if (S.selNotes.has(n)) { c.strokeStyle = css('--sel'); c.lineWidth = 2; rr(c, x + 1, y + 2, nw - 2, RH - 4, 2); c.stroke(); c.lineWidth = 1; }
  }
  if (R.box) { c.strokeStyle = css('--accent'); c.fillStyle = css('--accent'); c.globalAlpha = 0.18; c.fillRect(R.box.x, R.box.y, R.box.w, R.box.h); c.globalAlpha = 1; c.strokeRect(R.box.x + 0.5, R.box.y + 0.5, R.box.w, R.box.h); }
  const px = KW + (S.pos - cl.start) * ppb - R.sx;
  if (px >= KW && px <= w) { c.strokeStyle = css('--accent'); c.lineWidth = 1.5; c.beginPath(); c.moveTo(px, 0); c.lineTo(px, h); c.stroke(); c.lineWidth = 1; }
  // key column
  c.font = '10px ' + css('--ui'); c.textBaseline = 'middle';
  for (let r = r0; r < rows.length && r * RH - R.sy < h; r++) {
    const y = r * RH - R.sy, p = rows[r];
    if (drums) { c.fillStyle = css('--panel'); c.fillRect(0, y, KW, RH); c.fillStyle = css('--fg'); c.fillText(DRUMS.find(d => d.p === p).n, 4, y + RH / 2); }
    else { c.fillStyle = css(isBlack(p) ? '--keyb' : '--keyw'); c.fillRect(0, y, KW, RH); if (p % 12 === 0) { c.fillStyle = '#555b6b'; c.fillText('C' + (p / 12 - 1), 24, y + RH / 2); } }
    c.fillStyle = css('--line'); c.fillRect(0, y + RH - 1, KW, 1);
  }
  c.fillStyle = css('--line'); c.fillRect(KW - 1, 0, 1, h);
  c.fillStyle = css('--dim'); c.font = '10px ' + css('--mono');
  for (let bar = Math.floor(R.sx / ppb / 4); bar * 4 * ppb - R.sx < w; bar++) { const x = KW + bar * 4 * ppb - R.sx; if (x >= KW) c.fillText(String(Math.floor(cl.start / 4) + bar + 1), x + 4, 7); }
}
function rollHit(x, y) {
  const s = selClip(); if (!s) return null;
  const rows = rowsOf(s.tr), r = Math.floor((y + R.sy) / R.RH), p = rows[r], t = (x - R.KW + R.sx) / R.ppb;
  let note = null;
  for (let i = s.cl.notes.length - 1; i >= 0; i--) { const n = s.cl.notes[i]; if (n.p === p && t >= n.t - 3 / R.ppb && t <= n.t + Math.max(n.d, 6 / R.ppb) + 3 / R.ppb) { note = n; break; } }
  return { s, rows, r, p, t, note };
}
function audition(tr, p, v) {
  Engine.ensure(); Engine.sync();
  Engine.g.playNote(tr, p, v || 0.8, Engine.ctx.currentTime + 0.005, 0.22);
}
function zoomRoll(f, cx) {
  cx = cx == null ? R.w / 2 : cx; const b = (cx - R.KW + R.sx) / R.ppb;
  R.ppb = clamp(R.ppb * f, 10, 320); R.sx = Math.max(0, b * R.ppb - (cx - R.KW)); dirtyR = true;
}
gestures(rollCv, {
  start(x, y) {
    const h = rollHit(x, y); if (!h) return null;
    if (x < R.KW) return null;
    if (h.note) {
      const n = h.note, g = S.grid, drums = h.s.tr.type === 'drums';
      if (!S.selNotes.has(n)) { S.selNotes = new Set([n]); syncVel(); }
      audition(h.s.tr, n.p, n.v);
      const nx1 = R.KW + (n.t + n.d) * R.ppb - R.sx, edge = !drums && x > nx1 - Math.min(16, n.d * R.ppb * 0.4);
      const o = [...S.selNotes].map(m => ({ m, t: m.t, d: m.d, r: h.rows.indexOf(m.p) })); let ch = false, lastP = n.p;
      dirtyR = true;
      return {
        move(xx, yy, dx, dy) {
          ch = true;
          if (edge) for (const q of o) q.m.d = Math.max(g, Math.round((q.d + dx / R.ppb) / g) * g);
          else {
            const dt = Math.round(dx / R.ppb / g) * g, dr = Math.round(dy / R.RH);
            const minT = Math.min(...o.map(q => q.t)), minR = Math.min(...o.map(q => q.r)), maxR = Math.max(...o.map(q => q.r));
            const ddt = Math.max(dt, -minT), ddr = clamp(dr, -minR, h.rows.length - 1 - maxR);
            for (const q of o) { q.m.t = q.t + ddt; q.m.p = h.rows[q.r + ddr]; }
            if (n.p !== lastP) { lastP = n.p; audition(h.s.tr, n.p, n.v); }
          }
          dirtyR = dirtyA = true;
        },
        end() { if (ch) { if (!drums) S.lastLen = n.d; growClip(h.s.cl); commit(); } },
      };
    }
    const o = { sx: R.sx, sy: R.sy };
    return { move(xx, yy, dx, dy) { R.sx = Math.max(0, o.sx - dx); R.sy = o.sy - dy; dirtyR = true; } };
  },
  tap(x, y) {
    const h = rollHit(x, y); if (!h || h.p == null) return;
    if (x < R.KW) return audition(h.s.tr, h.p);
    if (h.note) { dirtyR = true; return; }
    const g = S.grid, t = Math.floor(h.t / g + 1e-6) * g; if (t < 0) return;
    const n = { p: h.p, t, d: h.s.tr.type === 'drums' ? g : S.lastLen, v: +$('#rVel').value };
    h.s.cl.notes.push(n); S.selNotes = new Set([n]); growClip(h.s.cl); audition(h.s.tr, n.p, n.v); commit();
  },
  dbl(x, y) {
    const h = rollHit(x, y); if (!h || !h.note || x < R.KW) return;
    h.s.cl.notes.splice(h.s.cl.notes.indexOf(h.note), 1); S.selNotes.delete(h.note); commit();
  },
  long(x, y) {
    const h = rollHit(x, y); if (!h || h.note || x < R.KW) return null;
    S.selNotes = new Set(); R.box = { x, y, w: 0, h: 0 }; dirtyR = true;
    return {
      move(xx, yy) {
        const b = R.box = { x: Math.min(x, xx), y: Math.min(y, yy), w: Math.abs(xx - x), h: Math.abs(yy - y) };
        S.selNotes = new Set(h.s.cl.notes.filter(n => {
          const nx = R.KW + n.t * R.ppb - R.sx, ny = h.rows.indexOf(n.p) * R.RH - R.sy;
          return nx < b.x + b.w && nx + n.d * R.ppb > b.x && ny < b.y + b.h && ny + R.RH > b.y;
        })); dirtyR = true;
      },
      end() { R.box = null; syncVel(); dirtyR = true; },
    };
  },
  pinch(s, cx) { zoomRoll(s, cx); },
  wheel(dx, dy) { R.sx = Math.max(0, R.sx + dx); R.sy += dy; dirtyR = true; },
});
function growClip(cl) { let e = 0; for (const n of cl.notes) e = Math.max(e, n.t + n.d); if (e > cl.len + 1e-6) cl.len = Math.ceil(e / 4 - 1e-6) * 4; }
function syncVel() { const n = [...S.selNotes][0]; if (n) $('#rVel').value = n.v; }

/* ---------- live play (keys / pads) ---------- */
const live = new Map();
function liveOn(key, pitch) {
  const tr = selTrack(); if (!tr || tr.type === 'audio') return;
  Engine.ensure(); if (live.has(key)) liveOff(key);
  const v = Engine.g.noteOn(tr, pitch, 0.85, Engine.ctx.currentTime);
  live.set(key, { pitch, v, tr: tr.id });
  if (S.rec && S.rec.tr === tr.id && Engine.playing) {
    const b = Engine.pos();
    if (tr.type === 'drums') S.rec.notes.push({ p: pitch, t: b, d: S.grid, v: 0.85 }); else S.rec.held.set(key, b);
  }
}
function liveOff(key) {
  const l = live.get(key); if (!l) return; live.delete(key);
  if (l.v) Engine.g.noteOff(l.v, Engine.ctx.currentTime);
  if (S.rec && S.rec.held.has(key)) {
    const t = S.rec.held.get(key); S.rec.held.delete(key);
    const b = Engine.playing ? Engine.pos() : S.pos; S.rec.notes.push({ p: l.pitch, t, d: Math.max(0.06, b - t), v: 0.85 });
  }
}
function bindPlaySurface(box) {
  const cur = new Map();
  const at = e => { const t = document.elementFromPoint(e.clientX, e.clientY); return t && t.dataset && t.dataset.p != null && box.contains(t) ? t : null; };
  const set = (id, t) => {
    const old = cur.get(id); if (old === t) return;
    if (old) { old.classList.remove('dn'); liveOff('k' + id); cur.delete(id); }
    if (t) { t.classList.add('dn'); cur.set(id, t); liveOn('k' + id, +t.dataset.p); }
  };
  box.addEventListener('pointerdown', e => { e.preventDefault(); try { box.setPointerCapture(e.pointerId); } catch (x) {} set(e.pointerId, at(e)); });
  box.addEventListener('pointermove', e => { if (cur.has(e.pointerId) && !box.classList.contains('nogl')) set(e.pointerId, at(e)); });
  const up = e => set(e.pointerId, null);
  box.addEventListener('pointerup', up); box.addEventListener('pointercancel', up);
}
function renderKeys() {
  const bar = $('#keysBar'), wrap = $('#keysWrap'), tr = selTrack(); bar.textContent = ''; wrap.textContent = '';
  if (!tr) { wrap.append(el('div', { cls: 'hint', text: 'トラックを追加すると、ここで演奏できます。' })); return; }
  if (tr.type === 'audio') {
    bar.append(btn('音声ファイルを読み込む', importAudio));
    wrap.append(el('div', { cls: 'hint', text: 'オーディオトラックです。● を押すとマイク録音が始まり、もう一度押すと止まります。伴奏の回り込みを防ぐため、録音中はイヤホンの使用をおすすめします。' }));
    return;
  }
  if (tr.type === 'drums') {
    bar.append(el('span', { cls: 'hint', style: 'padding:0', text: tr.name + '　パッドを叩いて演奏。● で録音' }));
    const pads = el('div', { id: 'pads', cls: 'nogl' }); DRUMS.forEach(d => pads.append(el('div', { cls: 'pad', 'data-p': d.p, text: d.n })));
    wrap.append(pads); bindPlaySurface(pads); return;
  }
  const lab = el('span', { text: 'C' + S.oct, style: 'min-width:30px;text-align:center;font-family:var(--mono)' });
  bar.append(btn('オクターブ −', () => { S.oct = clamp(S.oct - 1, 0, 7); renderKeys(); }), lab, btn('オクターブ ＋', () => { S.oct = clamp(S.oct + 1, 0, 7); renderKeys(); }),
    el('span', { cls: 'hint', style: 'padding:0 4px', text: tr.name }));
  const kb = el('div', { id: 'kb' }), nW = clamp(Math.floor((wrap.clientWidth || 400) / 42), 8, 22);
  let p = S.oct * 12 + 12; const whites = [];
  for (let i = 0; i < nW; i++) { while (isBlack(p)) p++; whites.push(p); kb.append(el('div', { cls: 'wk', 'data-p': p, text: p % 12 === 0 ? 'C' + (p / 12 - 1) : '' })); p++; }
  whites.forEach((wp, i) => { if (i < nW - 1 && isBlack(wp + 1)) kb.append(el('div', { cls: 'bk', 'data-p': wp + 1, style: 'left:' + ((i + 1) / nW * 100 - 30 / nW) + '%;width:' + (60 / nW) + '%' })); });
  wrap.append(kb); bindPlaySurface(kb);
}

/* ---------- mixer & sound ---------- */
function slider(label, id, val, min, max, step, fmt, onin) {
  const out = el('output', { text: fmt(val) });
  const i = el('input', { type: 'range', id, min, max, step, value: val, 'aria-label': label,
    oninput: () => { out.textContent = fmt(+i.value); onin(+i.value); }, onchange: () => commit() });
  return el('div', { cls: 'row' }, [el('label', { for: id, text: label }), i, out]);
}
const pct = v => Math.round(v * 100) + '';
const panFmt = v => (Math.abs(v) < 0.02 ? 'C' : (v < 0 ? 'L' : 'R') + Math.round(Math.abs(v) * 100));
let meterEls = [];
function renderMix() {
  const box = $('#strips'); box.textContent = ''; meterEls = [];
  const live = () => Engine.sync();
  for (const t of S.proj.tracks) {
    const m = el('i');
    box.append(el('div', { cls: 'strip', style: '--c:' + t.color }, [
      el('h4', {}, [el('span', { text: t.name }),
        el('button', { text: 'M', cls: t.mute ? 'on' : '', 'aria-label': 'ミュート', onclick: () => { t.mute = !t.mute; commit(); } }),
        el('button', { text: 'S', cls: t.solo ? 'on' : '', 'aria-label': 'ソロ', onclick: () => { t.solo = !t.solo; commit(); } })]),
      el('div', { cls: 'meter' }, [m]),
      slider('音量', 'v' + t.id, t.vol, 0, 1.2, 0.01, pct, v => { t.vol = v; live(); }),
      slider('パン', 'p' + t.id, t.pan, -1, 1, 0.02, panFmt, v => { t.pan = v; live(); }),
      slider('リバーブ', 'r' + t.id, t.rev, 0, 1, 0.01, pct, v => { t.rev = v; live(); }),
      slider('ディレイ', 'd' + t.id, t.dly, 0, 1, 0.01, pct, v => { t.dly = v; live(); }),
    ]));
    meterEls.push({ id: t.id, m });
  }
  const mm = el('i');
  box.append(el('div', { cls: 'strip' }, [el('h4', {}, [el('span', { text: 'マスター' })]), el('div', { cls: 'meter' }, [mm]),
    slider('音量', 'vMaster', S.proj.master, 0, 1.2, 0.01, pct, v => { S.proj.master = v; live(); })]));
  meterEls.push({ id: null, m: mm });
}
const mbuf = new Float32Array(256);
function drawMeters() {
  if (!Engine.g) return;
  for (const e of meterEls) {
    const an = e.id ? (Engine.g.tracks.get(e.id) || {}).an : Engine.g.an; if (!an) continue;
    an.getFloatTimeDomainData(mbuf); let pk = 0; for (let i = 0; i < 256; i += 2) { const x = Math.abs(mbuf[i]); if (x > pk) pk = x; }
    const db = 20 * Math.log10(pk + 1e-5), w = clamp((db + 48) / 48, 0, 1) * 100;
    e.lv = Math.max(w, (e.lv || 0) - 3); e.m.style.width = e.lv + '%';
  }
}
function renderInst() {
  const box = $('#instBody'), tr = selTrack(); box.textContent = '';
  if (!tr) { box.append(el('div', { cls: 'hint', text: 'トラックがありません。「＋トラック」で追加してください。' })); return; }
  const f = el('div', { cls: 'form' });
  const colors = el('span', { style: 'display:flex;gap:6px' }, COLORS.map(cc => el('button', { 'aria-label': '色', style: 'width:28px;min-height:28px;padding:0;border-radius:50%;background:' + cc + (cc === tr.color ? ';outline:2px solid var(--fg);outline-offset:1px' : ''), onclick: () => { tr.color = cc; commit(); } })));
  f.append(el('div', { cls: 'full' }, [btn('名前: ' + tr.name, () => promptDlg('トラック名', tr.name, v => { tr.name = v; commit(); })), colors,
    btn('トラック削除', () => { S.selClip = null; delSel(); }, 'dan')]));
  if (tr.type === 'synth') {
    const P = tr.inst, sel = el('select', { id: 'selPreset', 'aria-label': 'プリセット', onchange: () => { tr.inst = Object.assign({ preset: sel.value }, PRESETS[sel.value]); commit(); audition(tr, 60); } },
      Object.keys(PRESETS).map(k => el('option', { value: k, text: k, selected: k === P.preset })));
    const wsel = (id, key, label) => { const s = el('select', { id, 'aria-label': label, onchange: () => { P[key] = s.value; commit(); } }, [['sine', 'サイン'], ['triangle', '三角'], ['sawtooth', 'ノコギリ'], ['square', '矩形']].map(w => el('option', { value: w[0], text: w[1], selected: P[key] === w[0] }))); return s; };
    f.append(el('div', { cls: 'full' }, [el('label', { for: 'selPreset', text: 'プリセット' }), sel, el('label', { for: 'w1', text: '波形1' }), wsel('w1', 'w1', '波形1'), el('label', { for: 'w2', text: '波形2' }), wsel('w2', 'w2', '波形2'), btn('試聴', () => audition(tr, 60))]));
    const sec = v => (v < 1 ? Math.round(v * 1000) + 'ms' : v.toFixed(1) + 's'), hz = v => (v >= 1000 ? (v / 1000).toFixed(1) + 'k' : Math.round(v) + '');
    const S2 = (label, key, min, max, step, fmt, map, inv) => slider(label, 'i_' + key, inv ? inv(P[key]) : P[key], min, max, step, x => fmt(map ? map(x) : x), x => { P[key] = map ? map(x) : x; });
    f.append(
      S2('ミックス', 'mix', 0, 1, 0.01, pct), S2('デチューン', 'det', 0, 40, 1, v => v + 'c'),
      S2('波形2 Oct', 'oct2', -2, 2, 1, v => (v > 0 ? '+' : '') + v),
      S2('カットオフ', 'cut', 0, 1, 0.005, hz, x => 80 * Math.pow(150, x), v => Math.log(v / 80) / Math.log(150)),
      S2('レゾナンス', 'res', 0.1, 12, 0.1, v => v.toFixed(1)), S2('フィルタEnv', 'env', 0, 1, 0.01, pct),
      S2('アタック', 'a', 0, 1, 0.005, sec, x => 0.002 + x * x * 2, v => Math.sqrt((v - 0.002) / 2)),
      S2('ディケイ', 'd', 0, 1, 0.005, sec, x => 0.02 + x * x * 3, v => Math.sqrt((v - 0.02) / 3)),
      S2('サステイン', 's', 0, 1, 0.01, pct),
      S2('リリース', 'r', 0, 1, 0.005, sec, x => 0.02 + x * x * 3, v => Math.sqrt((v - 0.02) / 3)));
  } else if (tr.type === 'drums') {
    f.append(el('div', { cls: 'hint full', style: 'padding:0', text: '内蔵ドラムキット（キック、スネア、クラップ、ハイハット、タム、シンバルなど12パーツ）。音量・リバーブはミキサーで調整します。' }));
  } else {
    f.append(el('div', { cls: 'full' }, [btn('音声ファイルを読み込む', importAudio)]),
      slider('録音補正', 'latMs', S.set.latMs, -200, 300, 5, v => v + 'ms', v => { S.set.latMs = v; saveSet(); }),
      el('div', { cls: 'hint full', style: 'padding:0', text: '録音が伴奏より遅れて聞こえるときは「録音補正」を増やしてください（次の録音から反映）。' }));
  }
  box.append(f);
}
function renderEdit() {
  const s = selClip(), alt = $('#editAlt'), isRoll = !!(s && !s.cl.audioId);
  $('#rollBar').hidden = !isRoll; $('#rollWrap').hidden = !isRoll; alt.hidden = isRoll; alt.textContent = '';
  if (isRoll) { dirtyR = true; return; }
  if (!s) { alt.append(el('div', { cls: 'hint', text: 'クリップを選ぶとここで編集できます。タイムラインの空き部分をダブルタップ、または「＋クリップ」で新しいクリップを作成。クリップはタップで選択、もう一度ドラッグで移動、右端のドラッグで長さ変更。' })); return; }
  const cl = s.cl, f = el('div', { cls: 'form' });
  f.append(el('div', { cls: 'full' }, [btn('名前: ' + (cl.name || 'オーディオ'), () => promptDlg('クリップ名', cl.name || '', v => { cl.name = v; commit(); })),
    el('span', { cls: 'hint', style: 'padding:0', text: '長さ ' + cl.dur.toFixed(2) + ' 秒' })]),
    slider('ゲイン', 'clGain', cl.gain == null ? 1 : cl.gain, 0, 2, 0.01, pct, v => { cl.gain = v; dirtyA = true; }));
  alt.append(f);
}

/* ---------- panel / refresh ---------- */
function setTab(t) { S.tab = t; renderPanel(); }
function openPanel(t) { $('#app').classList.remove('min'); S.tab = t; refresh(); }
function renderPanel() {
  document.querySelectorAll('#tabs [data-tab]').forEach(b => b.classList.toggle('on', b.dataset.tab === S.tab));
  $('#pEdit').hidden = S.tab !== 'edit'; $('#pKeys').hidden = S.tab !== 'keys'; $('#pMix').hidden = S.tab !== 'mix'; $('#pInst').hidden = S.tab !== 'inst';
  if (S.tab === 'edit') renderEdit(); else if (S.tab === 'keys') renderKeys(); else if (S.tab === 'mix') renderMix(); else renderInst();
}
function refresh() {
  renderHeads(); renderPanel(); updTransport(); updTime(); dirty();
  $('#bBpm').firstChild.nodeValue = String(Math.round(S.proj.bpm));
  $('#bUndo').disabled = !S.undo.length; $('#bRedo').disabled = !S.redo.length;
  const has = !!selClip(); $('#bDup').disabled = !has; $('#bSplit').disabled = !has;
}
function frame() {
  if (Engine.playing) {
    S.pos = Engine.pos(); updTime(); dirty();
    const px = S.pos * A.ppb - A.sx; if (px > A.w - 24 || px < 0) A.sx = Math.max(0, S.pos * A.ppb - 40);
    const s = selClip(); if (s && S.tab === 'edit') { const rp = (S.pos - s.cl.start) * R.ppb - R.sx; if (S.pos >= s.cl.start && S.pos < s.cl.start + cLen(s.cl) && (rp > R.w - R.KW - 24 || rp < 0)) R.sx = Math.max(0, (S.pos - s.cl.start) * R.ppb - 30); }
    if (!S.rec && !S.proj.loop.on && S.pos > projEndBeat(S.proj) + 8) stopAll();
  }
  if (dirtyA) { dirtyA = false; drawArr(); }
  if (dirtyR) { dirtyR = false; drawRoll(); }
  if (S.tab === 'mix') drawMeters();
  requestAnimationFrame(frame);
}

/* ---------- dialogs ---------- */
function bpmDlg() {
  dialog('テンポ', d => {
    const i = el('input', { type: 'number', id: 'bpmIn', min: 40, max: 240, value: Math.round(S.proj.bpm), inputmode: 'numeric' });
    const set = v => { v = clamp(Math.round(v) || 120, 40, 240); i.value = v; Engine.setBpm(v); refresh(); };
    i.addEventListener('change', () => set(+i.value));
    let taps = [];
    d.append(i, el('div', { cls: 'acts', style: 'justify-content:space-between' }, [btn('−5', () => set(S.proj.bpm - 5)), btn('−1', () => set(S.proj.bpm - 1)), btn('＋1', () => set(S.proj.bpm + 1)), btn('＋5', () => set(S.proj.bpm + 5)),
      btn('タップ', () => { const n = performance.now(); taps = taps.filter(t => n - t < 2500); taps.push(n); if (taps.length > 1) set(60000 / ((n - taps[0]) / (taps.length - 1))); })]),
      el('div', { cls: 'acts' }, [btn('完了', () => { set(+i.value); closeDlg(); commit(); }, 'pri')]));
  });
}
function menuDlg() {
  dialog(S.proj.name, d => {
    const it = (t, fn) => btn(t, () => { closeDlg(); fn(); });
    d.append(el('div', { cls: 'list' }, [
      it('曲名を変更', () => promptDlg('曲名', S.proj.name, v => { S.proj.name = v; commit(); })),
      it('新しい曲を作る', () => promptDlg('新しい曲の名前', '新しい曲', async v => { const p = newProject(v); const keep = S.proj; S.proj = p; p.tracks.push(mkTrack('synth', 'シンセ', 'エレピ')); S.proj = keep; await DB.put('projects', p); loadProject(p); })),
      it('保存した曲を開く', projectsDlg),
      it('デモ曲を開く', async () => { const p = demoProject(); await DB.put('projects', p); loadProject(p); }),
      it('WAVで書き出す', exportDlg),
      it('設定', settingsDlg),
      it('使い方', helpDlg),
    ]), el('div', { cls: 'acts' }, [btn('閉じる', closeDlg)]));
  });
}
async function projectsDlg() {
  const list = ((await DB.all('projects')) || []).sort((a, b) => (b.saved || 0) - (a.saved || 0));
  dialog('保存した曲', d => {
    if (!list.length) d.append(el('p', { text: 'この端末に保存された曲はまだありません。編集内容は自動で保存されます。' }));
    const box = el('div', { cls: 'list' });
    for (const p of list) box.append(el('div', { cls: 'item' }, [
      btn(p.name + (p.id === S.proj.id ? '（編集中）' : '') + '　' + new Date(p.saved || 0).toLocaleDateString('ja-JP'), () => { closeDlg(); if (p.id !== S.proj.id) loadProject(p); }),
      el('button', { text: '削除', cls: 'dan', disabled: p.id === S.proj.id, onclick: () => confirmDlg('曲を削除', '「' + p.name + '」を削除します。元に戻せません。', '削除', async () => {
        await DB.del('projects', p.id); for (const k of ((await DB.keys('audio')) || [])) if (String(k).startsWith(p.id + ':')) DB.del('audio', k); projectsDlg(); }) }),
    ]));
    d.append(box, el('div', { cls: 'acts' }, [btn('閉じる', closeDlg)]));
  });
}
function settingsDlg() {
  dialog('設定', d => {
    const ck = (label, key) => { const i = el('input', { type: 'checkbox', id: 'set_' + key }); i.checked = !!S.set[key]; i.addEventListener('change', () => { S.set[key] = i.checked; saveSet(); }); return el('label', { cls: 'ck', for: 'set_' + key }, [i, el('span', { text: label })]); };
    d.append(ck('録音前に1小節のカウントを入れる', 'countIn'), ck('鍵盤・パッドの録音をグリッドに揃える', 'quant'), el('div', { cls: 'acts' }, [btn('閉じる', closeDlg, 'pri')]));
  });
}
function helpDlg() {
  dialog('使い方', d => {
    ['上段：▶ 再生／停止、● 録音（選択中のトラックへ）、⟲ ループ、♩ メトロノーム。ルーラーをタップすると再生位置が移動し、ループの両端はドラッグで動かせます。',
     'タイムライン：クリップをタップで選択、選択中のクリップをドラッグで移動、右端ドラッグで長さ変更、ダブルタップでエディタを開きます。2本指のピンチで拡大縮小。',
     'エディタ：空きマスをタップでノート追加、ドラッグで移動、右端で長さ変更、ダブルタップで削除、長押ししてドラッグで範囲選択。',
     '演奏：鍵盤やパッドを弾きながら ● で録音できます。オーディオトラックではマイク録音か音声ファイルの読み込みができます。',
     '曲は編集のたびにこの端末へ自動保存されます。完成したらメニューの「WAVで書き出す」で書き出せます。'].forEach(t => d.append(el('p', { text: t })));
    d.append(el('div', { cls: 'acts' }, [btn('閉じる', closeDlg, 'pri')]));
  });
}
async function exportDlg() {
  if (projEndBeat(S.proj) <= 0) return toast('書き出す内容がありません');
  stopAll(); Engine.ensure();
  dialog('WAVで書き出す', d => { d.append(el('p', { id: 'expMsg', text: 'ミックスを書き出しています…' })); });
  let wav;
  try { wav = encodeWav(await Engine.render(S.proj)); } catch (e) { closeDlg(); return toast('書き出しに失敗しました'); }
  const name = (S.proj.name.replace(/[\\/:*?"<>|]/g, '_') || 'song'), blob = new Blob([wav], { type: 'audio/wav' }), url = URL.createObjectURL(blob);
  let dl = null; try { if (window.claude && window.claude.use) dl = await window.claude.use('downloads'); } catch (e) {}
  dialog('WAVで書き出す', d => {
    const msg = el('p', { text: '44.1kHz / 16bit ステレオ、' + (wav.byteLength / 1048576).toFixed(1) + ' MB。下のプレーヤーで確認できます。' });
    const a = el('audio', { controls: true, src: url });
    const saveBtn = btn(dl ? 'ZIPで保存' : '保存・共有', async () => {
      try {
        if (dl) { await dl.save({ filename: name + '.zip', data: zipStore(name + '.wav', wav) }); msg.textContent = '保存しました。ZIPの中にWAVが入っています。'; return; }
        const file = new File([blob], name + '.wav', { type: 'audio/wav' });
        if (navigator.canShare && navigator.canShare({ files: [file] })) { await navigator.share({ files: [file], title: name }); return; }
        const l = el('a', { href: url, download: name + '.wav' }); document.body.append(l); l.click(); l.remove();
      } catch (e) { if (!e || (e.name !== 'AbortError' && e.code !== 'declined')) msg.textContent = '保存できませんでした。この表示環境では保存が許可されていない可能性があります。'; }
    }, 'pri');
    d.append(msg, a, el('div', { cls: 'acts' }, [btn('閉じる', () => { a.pause(); closeDlg(); }), saveBtn]));
  });
}

/* ---------- wiring ---------- */
$('#bPlay').onclick = play; $('#bRec').onclick = record;
$('#bHome').onclick = () => { const L = S.proj.loop; setPos(L.on && S.pos > L.start + 0.01 ? L.start : 0); A.sx = Math.max(0, S.pos * A.ppb - 40); };
$('#bLoop').onclick = () => { S.proj.loop.on = !S.proj.loop.on; commit(); };
$('#bMetro').onclick = () => { S.metro = !S.metro; Engine.metro = S.metro; updTransport(); };
$('#bBpm').onclick = bpmDlg; $('#bMenu').onclick = menuDlg;
$('#bUndo').onclick = undo; $('#bRedo').onclick = redo;
$('#bAddTrack').onclick = addTrackDlg; $('#bAddClip').onclick = () => addClip();
$('#bDup').onclick = dupClip; $('#bSplit').onclick = splitClip; $('#bDel').onclick = delSel;
$('#bZoomIn').onclick = () => zoomArr(1.4); $('#bZoomOut').onclick = () => zoomArr(1 / 1.4);
$('#bRZoomIn').onclick = () => zoomRoll(1.4); $('#bRZoomOut').onclick = () => zoomRoll(1 / 1.4);
document.querySelectorAll('#tabs [data-tab]').forEach(b => { b.onclick = () => { if (S.tab === b.dataset.tab && !$('#app').classList.contains('min')) return; openPanel(b.dataset.tab); }; });
$('#bSize').onclick = () => { const a = $('#app').classList; if (a.contains('min')) a.remove('min'); else if (a.contains('big')) { a.remove('big'); a.add('min'); } else a.add('big'); setTimeout(() => { dirty(); if (S.tab === 'keys') renderKeys(); }, 0); };
$('#selGrid').onchange = e => { S.grid = +e.target.value; dirtyR = true; };
$('#bQuant').onclick = () => { const s = selClip(); if (!s) return; const g = S.grid, ns = S.selNotes.size ? [...S.selNotes] : s.cl.notes; for (const n of ns) n.t = Math.max(0, Math.round(n.t / g) * g); commit(); };
$('#bSelAll').onclick = () => { const s = selClip(); if (!s) return; S.selNotes = S.selNotes.size === s.cl.notes.length ? new Set() : new Set(s.cl.notes); dirtyR = true; };
$('#bNoteDel').onclick = () => { const s = selClip(); if (!s || !S.selNotes.size) return toast('削除するノートを選んでください'); s.cl.notes = s.cl.notes.filter(n => !S.selNotes.has(n)); S.selNotes = new Set(); commit(); };
$('#rVel').oninput = e => { for (const n of S.selNotes) n.v = +e.target.value; dirtyR = true; };
$('#rVel').onchange = () => { if (S.selNotes.size) commit(); };
document.addEventListener('pointerdown', () => Engine.ensure(), { capture: true });
document.addEventListener('visibilitychange', () => { if (document.hidden && Engine.playing) stopAll(); });
document.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
  if (e.code === 'Space') { e.preventDefault(); play(); }
  else if ((e.metaKey || e.ctrlKey) && e.key === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); }
  else if (e.key === 'Delete' || e.key === 'Backspace') { if (S.tab === 'edit' && S.selNotes.size) $('#bNoteDel').click(); else if (selClip()) delSel(); }
});
document.addEventListener('gesturestart', e => e.preventDefault());
new ResizeObserver(() => { dirty(); if (S.tab === 'keys') renderKeys(); }).observe($('#app'));
new ResizeObserver(dirty).observe($('#panel'));

(async function boot() {
  await DB.open();
  const set = await DB.get('meta', 'set'); if (set && set.v) Object.assign(S.set, set.v);
  const last = await DB.get('meta', 'last'); let p = last && last.v ? await DB.get('projects', last.v) : null;
  if (!p) { p = demoProject(); DB.put('projects', p); }
  await loadProject(p);
  requestAnimationFrame(frame);
})();
