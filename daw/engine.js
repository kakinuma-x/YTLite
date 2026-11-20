'use strict';
/* PocketDAW audio engine: synth, drum kit, mixer graph, scheduler, mic capture, offline render. */

const DRUMS = [
  { p: 36, n: 'Kick' }, { p: 37, n: 'Rim' }, { p: 38, n: 'Snare' }, { p: 39, n: 'Clap' },
  { p: 41, n: 'Tom L' }, { p: 42, n: 'HH Cl' }, { p: 45, n: 'Tom M' }, { p: 46, n: 'HH Op' },
  { p: 48, n: 'Tom H' }, { p: 49, n: 'Crash' }, { p: 51, n: 'Ride' }, { p: 56, n: 'Cowbell' },
];

const PRESETS = {
  'エレピ':   { w1: 'sine', w2: 'triangle', oct2: 1, det: 3, mix: 0.3, cut: 2600, res: 0.5, env: 0.5, a: 0.004, d: 0.9, s: 0.25, r: 0.35 },
  'ベース':   { w1: 'sawtooth', w2: 'square', oct2: -1, det: 0, mix: 0.4, cut: 420, res: 3, env: 0.6, a: 0.004, d: 0.25, s: 0.6, r: 0.12 },
  'リード':   { w1: 'sawtooth', w2: 'sawtooth', oct2: 0, det: 12, mix: 0.5, cut: 3200, res: 2, env: 0.3, a: 0.01, d: 0.3, s: 0.8, r: 0.2 },
  'パッド':   { w1: 'sawtooth', w2: 'sawtooth', oct2: 0, det: 16, mix: 0.5, cut: 1400, res: 0.7, env: 0.1, a: 0.5, d: 1.2, s: 0.8, r: 1.2 },
  'プラック': { w1: 'square', w2: 'sawtooth', oct2: 0, det: 6, mix: 0.5, cut: 900, res: 2.5, env: 0.9, a: 0.002, d: 0.22, s: 0.0, r: 0.2 },
  'オルガン': { w1: 'sine', w2: 'sine', oct2: 1, det: 0, mix: 0.45, cut: 6000, res: 0.3, env: 0, a: 0.006, d: 0.1, s: 1, r: 0.06 },
  'ベル':     { w1: 'sine', w2: 'sine', oct2: 2, det: 7, mix: 0.35, cut: 8000, res: 0.3, env: 0, a: 0.002, d: 1.6, s: 0.0, r: 1.2 },
};

/* One mixer graph on a given (live or offline) context. */
class Graph {
  constructor(ctx) {
    this.ctx = ctx;
    this.tracks = new Map();
    this.voices = new Set();
    const c = ctx;
    this.in = c.createGain();
    this.comp = c.createDynamicsCompressor();
    this.comp.threshold.value = -8; this.comp.knee.value = 6; this.comp.ratio.value = 12;
    this.comp.attack.value = 0.003; this.comp.release.value = 0.15;
    this.out = c.createGain();
    this.an = c.createAnalyser(); this.an.fftSize = 512;
    this.in.connect(this.comp).connect(this.out).connect(c.destination);
    this.out.connect(this.an);
    // shared reverb
    this.rev = c.createConvolver(); this.rev.buffer = this.makeIR(2.4);
    this.rev.connect(this.in);
    // shared tempo delay
    this.dly = c.createDelay(2); this.dlyFb = c.createGain(); this.dlyFb.gain.value = 0.36;
    this.dlyLp = c.createBiquadFilter(); this.dlyLp.type = 'lowpass'; this.dlyLp.frequency.value = 3200;
    this.dly.connect(this.dlyLp).connect(this.dlyFb).connect(this.dly);
    this.dlyLp.connect(this.in);
    // noise
    const n = c.sampleRate * 2, nb = c.createBuffer(1, n, c.sampleRate), d = nb.getChannelData(0);
    for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
    this.noise = nb;
  }
  makeIR(sec) {
    const c = this.ctx, n = Math.floor(c.sampleRate * sec), b = c.createBuffer(2, n, c.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = b.getChannelData(ch);
      for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / n, 3.2) * 0.6;
    }
    return b;
  }
  sync(proj) {
    const c = this.ctx, now = c.currentTime;
    const ids = new Set(proj.tracks.map(t => t.id));
    for (const [id, tn] of this.tracks) if (!ids.has(id)) { tn.mute.disconnect(); this.tracks.delete(id); }
    const anySolo = proj.tracks.some(t => t.solo);
    for (const t of proj.tracks) {
      let tn = this.tracks.get(t.id);
      if (!tn) {
        tn = { input: c.createGain(), vol: c.createGain(), pan: c.createStereoPanner(), mute: c.createGain(),
               rev: c.createGain(), dly: c.createGain(), an: c.createAnalyser() };
        tn.an.fftSize = 256;
        tn.input.connect(tn.vol).connect(tn.pan).connect(tn.mute);
        tn.mute.connect(this.in); tn.mute.connect(tn.rev).connect(this.rev); tn.mute.connect(tn.dly).connect(this.dly);
        tn.mute.connect(tn.an);
        tn.vol.gain.value = t.vol; tn.pan.pan.value = t.pan; tn.rev.gain.value = t.rev; tn.dly.gain.value = t.dly;
        tn.mute.gain.value = 1;
        this.tracks.set(t.id, tn);
      }
      const aud = anySolo ? t.solo : !t.mute;
      tn.vol.gain.setTargetAtTime(t.vol, now, 0.02);
      tn.pan.pan.setTargetAtTime(t.pan, now, 0.02);
      tn.rev.gain.setTargetAtTime(t.rev, now, 0.02);
      tn.dly.gain.setTargetAtTime(t.dly, now, 0.02);
      tn.mute.gain.setTargetAtTime(aud ? 1 : 0, now, 0.01);
    }
    this.out.gain.setTargetAtTime(proj.master == null ? 0.9 : proj.master, now, 0.02);
    this.dly.delayTime.setTargetAtTime(Math.min(1.9, 60 / proj.bpm * 0.75), now, 0.05);
  }
  /* returns a voice handle for synth notes (null for drums) */
  noteOn(track, pitch, vel, t) {
    const tn = this.tracks.get(track.id); if (!tn) return null;
    if (track.type === 'drums') { this.drum(tn.input, pitch, vel, t); return null; }
    const c = this.ctx, P = track.inst, f = 440 * Math.pow(2, (pitch - 69) / 12);
    const o1 = c.createOscillator(), o2 = c.createOscillator(), g1 = c.createGain(), g2 = c.createGain();
    const flt = c.createBiquadFilter(), amp = c.createGain();
    o1.type = P.w1; o2.type = P.w2; o1.frequency.value = f; o2.frequency.value = f * Math.pow(2, P.oct2); o2.detune.value = P.det;
    g1.gain.value = 1 - P.mix; g2.gain.value = P.mix;
    flt.type = 'lowpass'; flt.Q.value = P.res;
    const base = Math.min(18000, P.cut * Math.pow(2, (pitch - 60) / 30));
    const peak = Math.min(20000, base * (1 + P.env * 10));
    flt.frequency.setValueAtTime(peak, t); flt.frequency.setTargetAtTime(base, t, Math.max(0.01, P.d / 3));
    const a = Math.max(0.002, P.a), lvl = 0.26 * vel;
    amp.gain.setValueAtTime(0, t); amp.gain.linearRampToValueAtTime(lvl, t + a);
    amp.gain.setTargetAtTime(lvl * P.s, t + a, Math.max(0.01, P.d / 3));
    o1.connect(g1).connect(flt); o2.connect(g2).connect(flt); flt.connect(amp).connect(tn.input);
    o1.start(t); o2.start(t);
    const v = { o1, o2, amp, t, a, d: Math.max(0.01, P.d / 3), s: P.s, r: Math.max(0.01, P.r / 3), lvl, off: false };
    this.voices.add(v); o1.onended = () => this.voices.delete(v);
    return v;
  }
  noteOff(v, t) {
    if (!v || v.off) return; v.off = true;
    const g = v.amp.gain; t = Math.max(t, v.t + 0.001);
    g.cancelScheduledValues(t);
    if (t < v.t + v.a) g.linearRampToValueAtTime(v.lvl * (t - v.t) / v.a, t);
    else g.setValueAtTime(v.lvl * (v.s + (1 - v.s) * Math.exp(-(t - v.t - v.a) / v.d)), t);
    g.setTargetAtTime(0, t, v.r);
    const end = t + v.r * 6 + 0.05; v.o1.stop(end); v.o2.stop(end);
  }
  playNote(track, pitch, vel, t, dur) { const v = this.noteOn(track, pitch, vel, t); if (v) this.noteOff(v, t + dur); }
  allOff() { const t = this.ctx.currentTime; for (const v of [...this.voices]) { v.off = false; v.r = 0.01; try { this.noteOff(v, t); } catch (e) {} } }
  nz(t, dur, type, freq, q) {
    const c = this.ctx, s = c.createBufferSource(); s.buffer = this.noise; s.loop = true;
    const f = c.createBiquadFilter(); f.type = type; f.frequency.value = freq; if (q) f.Q.value = q;
    const g = c.createGain(); s.connect(f).connect(g); s.start(t, Math.random()); s.stop(t + dur + 0.05);
    return g;
  }
  tone(t, dur, type, f0, f1, sweep) {
    const c = this.ctx, o = c.createOscillator(), g = c.createGain(); o.type = type;
    o.frequency.setValueAtTime(f0, t); if (f1) o.frequency.exponentialRampToValueAtTime(f1, t + sweep);
    o.connect(g); o.start(t); o.stop(t + dur + 0.05); return g;
  }
  env(g, t, lvl, dur, dest) {
    g.gain.setValueAtTime(lvl, t); g.gain.exponentialRampToValueAtTime(0.0008, t + dur); g.connect(dest);
  }
  drum(dest, p, vel, t) {
    const v = vel;
    switch (p) {
      case 36: this.env(this.tone(t, 0.45, 'sine', 160, 44, 0.11), t, 1.0 * v, 0.42, dest);
               this.env(this.nz(t, 0.02, 'lowpass', 3000), t, 0.25 * v, 0.02, dest); break;
      case 37: this.env(this.tone(t, 0.05, 'square', 1700), t, 0.25 * v, 0.03, dest);
               this.env(this.nz(t, 0.04, 'bandpass', 2600, 4), t, 0.5 * v, 0.035, dest); break;
      case 38: this.env(this.tone(t, 0.16, 'triangle', 240, 150, 0.08), t, 0.55 * v, 0.14, dest);
               this.env(this.nz(t, 0.22, 'highpass', 1500), t, 0.55 * v, 0.2, dest); break;
      case 39: for (let i = 0; i < 3; i++) this.env(this.nz(t + i * 0.012, 0.02, 'bandpass', 1300, 1.5), t + i * 0.012, 0.6 * v, 0.018, dest);
               this.env(this.nz(t + 0.036, 0.2, 'bandpass', 1300, 1.2), t + 0.036, 0.6 * v, 0.18, dest); break;
      case 41: this.env(this.tone(t, 0.4, 'sine', 130, 80, 0.2), t, 0.8 * v, 0.36, dest); break;
      case 45: this.env(this.tone(t, 0.34, 'sine', 185, 120, 0.18), t, 0.8 * v, 0.3, dest); break;
      case 48: this.env(this.tone(t, 0.28, 'sine', 260, 175, 0.15), t, 0.8 * v, 0.25, dest); break;
      case 42: this.env(this.nz(t, 0.06, 'highpass', 7500), t, 0.38 * v, 0.05, dest); break;
      case 46: this.env(this.nz(t, 0.36, 'highpass', 7000), t, 0.36 * v, 0.32, dest); break;
      case 49: this.env(this.nz(t, 1.5, 'highpass', 5200), t, 0.42 * v, 1.4, dest);
               this.env(this.nz(t, 0.5, 'bandpass', 3400, 0.8), t, 0.2 * v, 0.45, dest); break;
      case 51: this.env(this.nz(t, 0.7, 'bandpass', 8200, 2), t, 0.3 * v, 0.6, dest);
               this.env(this.tone(t, 0.3, 'square', 5270), t, 0.03 * v, 0.25, dest); break;
      case 56: { const b = this.ctx.createBiquadFilter(); b.type = 'bandpass'; b.frequency.value = 2640; b.Q.value = 1; b.connect(dest);
               this.env(this.tone(t, 0.3, 'square', 540), t, 0.3 * v, 0.28, b);
               this.env(this.tone(t, 0.3, 'square', 800), t, 0.3 * v, 0.28, b); break; }
      default: this.env(this.nz(t, 0.05, 'highpass', 6000), t, 0.3 * v, 0.04, dest);
    }
  }
  click(t, accent) {
    this.env(this.tone(t, 0.04, 'square', accent ? 1760 : 1175), t, accent ? 0.28 : 0.18, 0.035, this.out);
  }
  playAudio(track, clip, buf, t, off, dur) {
    const tn = this.tracks.get(track.id); if (!tn || !buf) return null;
    const c = this.ctx, s = c.createBufferSource(), g = c.createGain();
    s.buffer = buf; g.gain.value = clip.gain == null ? 1 : clip.gain;
    s.connect(g).connect(tn.input);
    off = Math.max(0, Math.min(off, buf.duration)); dur = Math.max(0, Math.min(dur, buf.duration - off));
    if (dur <= 0) return null;
    s.start(t, off, dur); return s;
  }
}

function clipLenBeats(clip, bpm) { return clip.audioId ? clip.dur * bpm / 60 : clip.len; }
function projEndBeat(proj) {
  let e = 0;
  for (const t of proj.tracks) for (const c of t.clips) e = Math.max(e, c.start + clipLenBeats(c, proj.bpm));
  return e;
}

/* Schedule everything whose start falls in [a,b). `jump` = playback (re)entered at a. */
function scheduleRange(g, proj, a, b, timeAt, jump, buffers, srcs, metro) {
  const spb = 60 / proj.bpm;
  if (metro) for (let k = Math.ceil(a - 1e-9); k < b; k++) g.click(timeAt(k), ((k % 4) + 4) % 4 === 0);
  for (const tr of proj.tracks) {
    for (const cl of tr.clips) {
      const cs = cl.start;
      if (cl.audioId) {
        const len = cl.dur / spb; let s = null;
        if (cs >= a && cs < b) s = g.playAudio(tr, cl, buffers.get(cl.audioId), timeAt(cs), cl.off || 0, cl.dur);
        else if (jump && cs < a && cs + len > a + 1e-6) {
          const o = (a - cs) * spb;
          s = g.playAudio(tr, cl, buffers.get(cl.audioId), timeAt(a), (cl.off || 0) + o, cl.dur - o);
        }
        if (s && srcs) srcs.push(s);
      } else {
        if (cs + cl.len <= a || cs >= b) continue;
        for (const n of cl.notes) {
          const nb = cs + n.t;
          if (n.t < cl.len - 1e-6 && nb >= a && nb < b)
            g.playNote(tr, n.p, n.v, timeAt(nb), Math.max(0.03, Math.min(n.d, cl.len - n.t) * spb));
        }
      }
    }
  }
}

const Engine = {
  ctx: null, g: null, proj: null, buffers: new Map(), peaks: new Map(),
  playing: false, recording: false, metro: false, countInEnd: -Infinity,
  anchor: { time: 0, beat: 0 }, prev: null, sched: 0, jump: false, srcs: [], timer: null,
  ensure() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      this.ctx = new AC({ latencyHint: 'interactive' });
      this.g = new Graph(this.ctx);
      if (this.proj) this.g.sync(this.proj);
      try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
    }
    if (this.ctx.state !== 'running') this.ctx.resume().catch(() => {});
    return this.ctx;
  },
  sync() { if (this.g && this.proj) this.g.sync(this.proj); },
  beatAt(t) { let a = this.anchor; if (this.prev && t < a.time) a = this.prev; return a.beat + (t - a.time) * this.proj.bpm / 60; },
  timeAt(beat) { return this.anchor.time + (beat - this.anchor.beat) * 60 / this.proj.bpm; },
  pos() { return this.beatAt(this.ctx.currentTime); },
  setBpm(bpm) {
    if (this.playing) { const now = this.ctx.currentTime, b = this.beatAt(now); this.proj.bpm = bpm; this.anchor = { time: now, beat: b }; this.prev = null; }
    else this.proj.bpm = bpm;
    this.sync();
  },
  start(beat) {
    this.ensure(); this.stop();
    this.anchor = { time: this.ctx.currentTime + 0.07, beat }; this.prev = null;
    this.sched = beat; this.jump = true; this.srcs = []; this.playing = true;
    this.timer = setInterval(() => this.tick(), 25); this.tick();
  },
  stop() {
    if (!this.playing) return;
    clearInterval(this.timer); this.playing = false;
    const now = this.ctx.currentTime;
    for (const s of this.srcs) { try { s.stop(now); } catch (e) {} }
    this.srcs = []; this.g.allOff();
  },
  tick() {
    const ctx = this.ctx, p = this.proj, hor = ctx.currentTime + 0.16;
    for (let guard = 0; guard < 16; guard++) {
      const L = p.loop, useLoop = L.on && !this.recording && L.end > L.start + 0.01 && this.sched < L.end;
      const to = this.anchor.beat + (hor - this.anchor.time) * p.bpm / 60;
      if (useLoop && to >= L.end) {
        this.range(this.sched, L.end);
        const tw = this.timeAt(L.end);
        for (const s of this.srcs) { try { s.stop(tw); } catch (e) {} }
        this.srcs = [];
        this.prev = this.anchor; this.anchor = { time: tw, beat: L.start }; this.sched = L.start; this.jump = true;
        continue;
      }
      if (to > this.sched) { this.range(this.sched, to); this.sched = to; }
      break;
    }
  },
  range(a, b) {
    const jump = this.jump; this.jump = false;
    scheduleRange(this.g, this.proj, a, b, x => this.timeAt(x), jump, this.buffers, this.srcs, this.metro || a < this.countInEnd);
  },
  /* ---- audio data ---- */
  setAudio(id, chans, sr) {
    const b = new AudioBuffer({ numberOfChannels: chans.length, length: chans[0].length, sampleRate: sr });
    chans.forEach((c, i) => b.getChannelData(i).set(c));
    this.buffers.set(id, b);
    const d = chans[0], step = Math.max(1, Math.floor(sr / 100)), n = Math.ceil(d.length / step), pk = new Float32Array(n);
    for (let i = 0; i < n; i++) { let m = 0; const e = Math.min(d.length, (i + 1) * step); for (let j = i * step; j < e; j += 4) { const x = Math.abs(d[j]); if (x > m) m = x; } pk[i] = m; }
    this.peaks.set(id, pk);
    return b;
  },
  /* ---- mic ---- */
  mic: null,
  async micStart() {
    const ctx = this.ensure();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('nomic');
    try { if (navigator.audioSession) navigator.audioSession.type = 'play-and-record'; } catch (e) {}
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    const src = ctx.createMediaStreamSource(stream), sink = ctx.createGain(); sink.gain.value = 0; sink.connect(ctx.destination);
    const m = { stream, src, sink, chunks: [], t0: null, peak: 0, node: null };
    const push = (d, t) => { if (m.t0 == null) m.t0 = t; m.chunks.push(d); let pk = 0; for (let i = 0; i < d.length; i += 8) { const x = Math.abs(d[i]); if (x > pk) pk = x; } m.peak = Math.max(pk, m.peak * 0.8); };
    let ok = false;
    if (ctx.audioWorklet) {
      try {
        const code = `class R extends AudioWorkletProcessor{constructor(){super();this.b=new Float32Array(2048);this.n=0;this.t=0}
          process(i){const c=i[0][0];if(!c)return true;if(this.n===0)this.t=currentTime;this.b.set(c,this.n);this.n+=c.length;
          if(this.n>=2048){this.port.postMessage({d:this.b,t:this.t});this.b=new Float32Array(2048);this.n=0}return true}}
          registerProcessor('pd-rec',R)`;
        const url = URL.createObjectURL(new Blob([code], { type: 'application/javascript' }));
        await ctx.audioWorklet.addModule(url);
        m.node = new AudioWorkletNode(ctx, 'pd-rec', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit' });
        m.node.port.onmessage = e => push(e.data.d, e.data.t);
        ok = true;
      } catch (e) { ok = false; }
    }
    if (!ok) {
      m.node = ctx.createScriptProcessor(4096, 1, 1);
      m.node.onaudioprocess = e => push(new Float32Array(e.inputBuffer.getChannelData(0)), e.playbackTime);
    }
    src.connect(m.node); m.node.connect(sink);
    this.mic = m;
  },
  micStop() {
    const m = this.mic; if (!m) return null; this.mic = null;
    try { m.src.disconnect(); m.node.disconnect(); m.stream.getTracks().forEach(t => t.stop()); } catch (e) {}
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
    let n = 0; for (const c of m.chunks) n += c.length;
    const data = new Float32Array(n); let o = 0; for (const c of m.chunks) { data.set(c, o); o += c.length; }
    return { data, t0: m.t0 || 0, sr: this.ctx.sampleRate };
  },
  /* ---- offline bounce ---- */
  async render(proj) {
    const sr = 44100, spb = 60 / proj.bpm, end = projEndBeat(proj);
    const OC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    const oc = new OC(2, Math.ceil((end * spb + 2.5) * sr), sr), g = new Graph(oc);
    g.sync(proj);
    for (const [id, tn] of g.tracks) { // sync() ramps; pin values for t=0
      const t = proj.tracks.find(x => x.id === id), anySolo = proj.tracks.some(x => x.solo);
      tn.mute.gain.cancelScheduledValues(0); tn.mute.gain.value = (anySolo ? t.solo : !t.mute) ? 1 : 0;
    }
    g.out.gain.cancelScheduledValues(0); g.out.gain.value = proj.master == null ? 0.9 : proj.master;
    g.dly.delayTime.cancelScheduledValues(0); g.dly.delayTime.value = Math.min(1.9, spb * 0.75);
    scheduleRange(g, proj, 0, end + 0.001, b => 0.02 + b * spb, false, this.buffers, null, false);
    return await oc.startRendering();
  },
};

function encodeWav(buf) {
  const nc = buf.numberOfChannels, n = buf.length, sr = buf.sampleRate, ab = new ArrayBuffer(44 + n * nc * 2), v = new DataView(ab);
  const ws = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  ws(0, 'RIFF'); v.setUint32(4, 36 + n * nc * 2, true); ws(8, 'WAVEfmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
  v.setUint16(22, nc, true); v.setUint32(24, sr, true); v.setUint32(28, sr * nc * 2, true); v.setUint16(32, nc * 2, true); v.setUint16(34, 16, true);
  ws(36, 'data'); v.setUint32(40, n * nc * 2, true);
  const ch = []; for (let c = 0; c < nc; c++) ch.push(buf.getChannelData(c));
  let o = 44;
  for (let i = 0; i < n; i++) for (let c = 0; c < nc; c++) { const x = Math.max(-1, Math.min(1, ch[c][i])); v.setInt16(o, x < 0 ? x * 32768 : x * 32767, true); o += 2; }
  return ab;
}

/* store-only zip (used where only .zip downloads are permitted) */
function zipStore(name, data) {
  const u8 = new Uint8Array(data), nm = new TextEncoder().encode(name);
  let crc = -1; const tbl = zipStore.t || (zipStore.t = (() => { const t = new Uint32Array(256); for (let i = 0; i < 256; i++) { let c = i; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[i] = c; } return t; })());
  for (let i = 0; i < u8.length; i++) crc = tbl[(crc ^ u8[i]) & 255] ^ (crc >>> 8);
  crc = (crc ^ -1) >>> 0;
  const lh = new DataView(new ArrayBuffer(30)), cd = new DataView(new ArrayBuffer(46)), eo = new DataView(new ArrayBuffer(22));
  lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x800, true); lh.setUint32(14, crc, true);
  lh.setUint32(18, u8.length, true); lh.setUint32(22, u8.length, true); lh.setUint16(26, nm.length, true);
  cd.setUint32(0, 0x02014b50, true); cd.setUint16(4, 20, true); cd.setUint16(6, 20, true); cd.setUint16(8, 0x800, true); cd.setUint32(16, crc, true);
  cd.setUint32(20, u8.length, true); cd.setUint32(24, u8.length, true); cd.setUint16(28, nm.length, true);
  eo.setUint32(0, 0x06054b50, true); eo.setUint16(8, 1, true); eo.setUint16(10, 1, true); eo.setUint32(12, 46 + nm.length, true);
  eo.setUint32(16, 30 + nm.length + u8.length, true);
  return new Blob([lh, nm, u8, cd, nm, eo], { type: 'application/zip' });
}
