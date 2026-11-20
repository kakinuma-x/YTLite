import Foundation

// Real-time engine: sequencer, synth and drum voices, audio clip playback, mixer, sends, limiter.
// Everything is rendered by `render(frames:left:right:)`, so the same code drives live playback
// and offline bounce. The UI thread talks to it through a snapshot + command queue.

struct NoteEvent { var beat: Double; var pitch: Int; var vel: Float; var dur: Double }

struct AudioClipRT { var start: Double; var off: Double; var dur: Double; var gain: Float; var data: AudioData }

final class TrackRT {
    let slot: Int
    let kind: TrackKind
    let vol: Float, pan: Float, rev: Float, dly: Float
    let audible: Bool
    let params: SynthParams
    let events: [NoteEvent]
    let clips: [AudioClipRT]
    init(slot: Int, track: Track, audible: Bool, audio: [String: AudioData]) {
        self.slot = slot; kind = track.kind; vol = Float(track.vol); pan = Float(track.pan); rev = Float(track.rev); dly = Float(track.dly)
        self.audible = audible; params = track.inst
        var ev: [NoteEvent] = [], cl: [AudioClipRT] = []
        for c in track.clips {
            if let id = c.audioID {
                if let d = audio[id] { cl.append(AudioClipRT(start: c.start, off: c.off, dur: c.dur, gain: Float(c.gain), data: d)) }
            } else {
                for n in c.notes where n.t < c.len - 1e-6 && n.t >= 0 {
                    ev.append(NoteEvent(beat: c.start + n.t, pitch: n.p, vel: Float(n.v), dur: max(0.02, min(n.d, c.len - n.t))))
                }
            }
        }
        ev.sort { $0.beat < $1.beat }
        events = ev; clips = cl
    }
}

final class Snapshot {
    let bpm: Double
    let master: Float
    let loop: LoopRange
    let tracks: [TrackRT]
    var bySlot: [TrackRT?]
    init(project: Project, slots: [UUID: Int], audio: [String: AudioData]) {
        bpm = project.bpm; master = Float(project.master); loop = project.loop
        let anySolo = project.tracks.contains { $0.solo }
        var ts: [TrackRT] = []; var by = [TrackRT?](repeating: nil, count: DAWEngine.maxTracks)
        for t in project.tracks {
            guard let s = slots[t.id] else { continue }
            let rt = TrackRT(slot: s, track: t, audible: anySolo ? t.solo : !t.mute, audio: audio)
            ts.append(rt); by[s] = rt
        }
        tracks = ts; bySlot = by
    }
}

enum EngineCommand {
    case play(Double)
    case stop
    case noteOn(slot: Int, pitch: Int, vel: Float)
    case noteOff(slot: Int, pitch: Int)
    case note(slot: Int, pitch: Int, vel: Float, seconds: Double)
    case metronome(Bool)
    case countIn(until: Double)
    case loopEnabled(Bool)
}

struct Voice {
    var active = false
    var drum = false
    var slot = 0
    var pitch = 0
    var held = false
    var delay = 0
    var remain = -1
    // synth
    var ph1 = 0.0, ph2 = 0.0, inc1 = 0.0, inc2 = 0.0
    var w1 = 0, w2 = 0
    var g1: Float = 1, g2: Float = 0
    var level: Float = 0, env: Float = 0
    var stage = 0
    var aInc: Float = 0, dCoef: Float = 0, sus: Float = 0, rCoef: Float = 0
    var cutBase: Float = 1000, cutPeak: Float = 1000, fenv: Float = 1, fCoef: Float = 1, k: Float = 1
    var ic1: Float = 0, ic2: Float = 0
    // drum
    var tAmp: Float = 0, tDec: Float = 0, tFreq = 0.0, tEnd = 0.0, tCoef = 1.0, tWave = 0
    var t2Freq = 0.0
    var nAmp: Float = 0, nDec: Float = 0, nType = 0, nG: Float = 0, nK: Float = 1
    var n2Amp: Float = 0, n2Dec: Float = 0
    var bursts = 0, burstCount = 0, burstLevel: Float = 0, tailDec: Float = 0
    var toMaster = false
}

final class Reverb {
    private var combs: [UnsafeMutablePointer<Float>] = []
    private var combLen: [Int] = [], combIdx: [Int] = [], combLP: [Float] = []
    private var aps: [UnsafeMutablePointer<Float>] = []
    private var apLen: [Int] = [], apIdx: [Int] = []
    init(sampleRate: Double) {
        let k = sampleRate / 44100
        for ch in 0..<2 {
            for l in [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] {
                let n = Int(Double(l + ch * 23) * k); let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n)
                combs.append(p); combLen.append(n); combIdx.append(0); combLP.append(0)
            }
            for l in [556, 441, 341, 225] {
                let n = Int(Double(l + ch * 23) * k); let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n)
                aps.append(p); apLen.append(n); apIdx.append(0)
            }
        }
    }
    deinit { combs.forEach { $0.deallocate() }; aps.forEach { $0.deallocate() } }
    func process(input: UnsafePointer<Float>, n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let fb: Float = 0.86, damp: Float = 0.25
        for ch in 0..<2 {
            let out = ch == 0 ? left : right
            for i in 0..<n {
                let x = input[i] * 0.015
                var acc: Float = 0
                for c in 0..<8 {
                    let ci = ch * 8 + c, buf = combs[ci], idx = combIdx[ci]
                    let y = buf[idx]
                    let lp = y * (1 - damp) + combLP[ci] * damp
                    combLP[ci] = lp
                    buf[idx] = x + lp * fb
                    combIdx[ci] = idx + 1 == combLen[ci] ? 0 : idx + 1
                    acc += y
                }
                for a in 0..<4 {
                    let ai = ch * 4 + a, buf = aps[ai], idx = apIdx[ai]
                    let b = buf[idx], y = b - acc
                    buf[idx] = acc + b * 0.5
                    apIdx[ai] = idx + 1 == apLen[ai] ? 0 : idx + 1
                    acc = y
                }
                out[i] += acc * 2.2
            }
        }
    }
}

public final class DAWEngine: @unchecked Sendable {
    public static let maxTracks = 32
    static let chunk = 64
    static let maxVoices = 72

    public let sampleRate: Double
    private let lock = NSLock()
    private var pendingSnap: Snapshot?
    private var pendingCmds: [EngineCommand] = []
    private var slots: [UUID: Int] = [:]

    // audio-thread state
    private var snap: Snapshot?
    private var playing = false
    private var beat = 0.0
    private var metro = false
    private var countInEnd = -Double.infinity
    private var loopEnabled = true
    private let cursors: UnsafeMutablePointer<Int>
    private let voices: UnsafeMutablePointer<Voice>
    private let busL: UnsafeMutablePointer<Float>, busR: UnsafeMutablePointer<Float>
    private let mixL: UnsafeMutablePointer<Float>, mixR: UnsafeMutablePointer<Float>
    private let revIn: UnsafeMutablePointer<Float>, dlyIn: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>          // per slot: gl, gr, rev, dly (smoothed)
    private let reverb: Reverb
    private let dlyBuf: UnsafeMutablePointer<Float>
    private let dlyLen: Int
    private var dlyPos = 0
    private var dlyLP: Float = 0
    private var limEnv: Float = 0
    private var masterGain: Float = 0.9
    private var rng: UInt32 = 0x1234567

    // shared with UI (plain memory, benign races)
    private let sharedBeat: UnsafeMutablePointer<Double>
    private let sharedFlags: UnsafeMutablePointer<Int32>
    private let meters: UnsafeMutablePointer<Float>         // maxTracks + 1 (master last)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        func alloc<T>(_ n: Int, _ v: T) -> UnsafeMutablePointer<T> { let p = UnsafeMutablePointer<T>.allocate(capacity: n); p.initialize(repeating: v, count: n); return p }
        cursors = alloc(Self.maxTracks, 0)
        voices = alloc(Self.maxVoices, Voice())
        busL = alloc(Self.chunk, 0); busR = alloc(Self.chunk, 0); mixL = alloc(Self.chunk, 0); mixR = alloc(Self.chunk, 0)
        revIn = alloc(Self.chunk, 0); dlyIn = alloc(Self.chunk, 0)
        gains = alloc(Self.maxTracks * 4, 0)
        reverb = Reverb(sampleRate: sampleRate)
        dlyLen = Int(sampleRate * 2.05); dlyBuf = alloc(dlyLen, 0)
        sharedBeat = alloc(1, 0); sharedFlags = alloc(1, 0); meters = alloc(Self.maxTracks + 1, 0)
        pendingCmds.reserveCapacity(64)
    }
    deinit {
        cursors.deallocate(); voices.deallocate(); busL.deallocate(); busR.deallocate(); mixL.deallocate(); mixR.deallocate()
        revIn.deallocate(); dlyIn.deallocate(); gains.deallocate(); dlyBuf.deallocate(); sharedBeat.deallocate(); sharedFlags.deallocate(); meters.deallocate()
    }

    // MARK: UI-side API

    public var positionBeats: Double { sharedBeat.pointee }
    public var isPlaying: Bool { sharedFlags.pointee != 0 }

    /// Peak since last read for a track (or master when id is nil).
    public func takeMeter(_ id: UUID?) -> Float {
        let i: Int
        if let id = id { guard let s = slots[id] else { return 0 }; i = s } else { i = Self.maxTracks }
        let v = meters[i]; meters[i] = 0; return v
    }

    public func setProject(_ p: Project, audio: [String: AudioData]) {
        var used = Set<Int>()
        var next: [UUID: Int] = [:]
        for t in p.tracks { if let s = slots[t.id] { next[t.id] = s; used.insert(s) } }
        for t in p.tracks where next[t.id] == nil {
            if let free = (0..<Self.maxTracks).first(where: { !used.contains($0) }) { next[t.id] = free; used.insert(free) }
        }
        slots = next
        let s = Snapshot(project: p, slots: next, audio: audio)
        lock.lock(); pendingSnap = s; lock.unlock()
    }

    public func send(_ c: EngineCommandPublic) {
        let cmd: EngineCommand
        switch c {
        case .play(let b): cmd = .play(b); sharedBeat.pointee = b; sharedFlags.pointee = 1
        case .stop: cmd = .stop; sharedFlags.pointee = 0
        case .noteOn(let id, let p, let v): guard let s = slots[id] else { return }; cmd = .noteOn(slot: s, pitch: p, vel: v)
        case .noteOff(let id, let p): guard let s = slots[id] else { return }; cmd = .noteOff(slot: s, pitch: p)
        case .note(let id, let p, let v, let sec): guard let s = slots[id] else { return }; cmd = .note(slot: s, pitch: p, vel: v, seconds: sec)
        case .metronome(let on): cmd = .metronome(on)
        case .countIn(let b): cmd = .countIn(until: b)
        case .loopEnabled(let on): cmd = .loopEnabled(on)
        }
        lock.lock(); pendingCmds.append(cmd); lock.unlock()
    }

    // MARK: render

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if lock.`try`() {
            if let s = pendingSnap { snap = s; pendingSnap = nil; if playing { seek() } }
            if !pendingCmds.isEmpty { for c in pendingCmds { apply(c) }; pendingCmds.removeAll(keepingCapacity: true) }
            lock.unlock()
        }
        guard let sn = snap else { for i in 0..<frames { left[i] = 0; right[i] = 0 }; return }
        var done = 0
        let bpf = sn.bpm / 60 / sampleRate
        while done < frames {
            var n = min(Self.chunk, frames - done)
            let looping = playing && loopEnabled && sn.loop.on && sn.loop.end > sn.loop.start + 0.01 && beat < sn.loop.end
            if looping {
                let toEnd = Int(((sn.loop.end - beat) / bpf).rounded(.up))
                if toEnd <= 0 { beat = sn.loop.start; seek(); continue }
                n = min(n, toEnd)
            }
            if playing { schedule(sn, b0: beat, b1: beat + Double(n) * bpf, bpf: bpf, n: n) }
            renderChunk(sn, n: n, outL: left + done, outR: right + done, bpf: bpf)
            if playing {
                beat += Double(n) * bpf
                if looping && beat >= sn.loop.end - 1e-9 { beat = sn.loop.start; seek() }
            }
            done += n
        }
        sharedBeat.pointee = beat
    }

    private func apply(_ c: EngineCommand) {
        switch c {
        case .play(let b): beat = b; playing = true; seek()
        case .stop:
            playing = false
            for i in 0..<Self.maxVoices where voices[i].active {
                if voices[i].drum { continue }
                voices[i].stage = 2; voices[i].rCoef = min(voices[i].rCoef, 0.995); voices[i].held = false; voices[i].remain = -1
            }
        case .noteOn(let slot, let pitch, let vel): startVoice(slot: slot, pitch: pitch, vel: vel, delay: 0, remain: -1, held: true)
        case .noteOff(let slot, let pitch):
            for i in 0..<Self.maxVoices where voices[i].active && voices[i].held && voices[i].slot == slot && voices[i].pitch == pitch {
                voices[i].held = false; voices[i].stage = 2
            }
        case .note(let slot, let pitch, let vel, let sec): startVoice(slot: slot, pitch: pitch, vel: vel, delay: 0, remain: Int(sec * sampleRate), held: false)
        case .metronome(let on): metro = on
        case .countIn(let b): countInEnd = b
        case .loopEnabled(let on): loopEnabled = on
        }
    }

    private func seek() {
        guard let sn = snap else { return }
        for t in sn.tracks {
            var lo = 0, hi = t.events.count
            while lo < hi { let m = (lo + hi) / 2; if t.events[m].beat < beat - 1e-9 { lo = m + 1 } else { hi = m } }
            cursors[t.slot] = lo
        }
    }

    private func schedule(_ sn: Snapshot, b0: Double, b1: Double, bpf: Double, n: Int) {
        for t in sn.tracks where t.kind != .audio {
            var c = cursors[t.slot]
            let ev = t.events
            while c < ev.count && ev[c].beat < b1 {
                let e = ev[c]
                let d = max(0, min(n - 1, Int((e.beat - b0) / bpf)))
                startVoice(slot: t.slot, pitch: e.pitch, vel: e.vel, delay: d, remain: max(1, Int(e.dur / bpf)), held: false)
                c += 1
            }
            cursors[t.slot] = c
        }
        if metro || b0 < countInEnd {
            let k = (b0 - 1e-9).rounded(.up)
            if k < b1 {
                let accent = Int(k) % 4 == 0
                startClick(delay: max(0, min(n - 1, Int((k - b0) / bpf))), accent: accent)
            }
        }
    }

    private func freeVoice() -> Int {
        for i in 0..<Self.maxVoices where !voices[i].active { return i }
        var best = 0; var low: Float = .infinity
        for i in 0..<Self.maxVoices {
            let v = voices[i]; let l = v.drum ? max(v.tAmp, v.nAmp) : (v.stage == 2 ? v.env * 0.3 : v.env + 1)
            if l < low { low = l; best = i }
        }
        return best
    }

    private func startVoice(slot: Int, pitch: Int, vel: Float, delay: Int, remain: Int, held: Bool) {
        guard let sn = snap, slot >= 0, slot < Self.maxTracks, let t = sn.bySlot[slot] else { return }
        if t.kind == .audio { return }
        let i = freeVoice()
        var v = Voice()
        v.active = true; v.slot = slot; v.pitch = pitch; v.delay = delay; v.remain = remain; v.held = held
        let sr = sampleRate
        if t.kind == .drums { v.drum = true; setupDrum(&v, pitch: pitch, vel: vel) }
        else {
            let P = t.params
            let f = 440 * pow(2, Double(pitch - 69) / 12)
            v.inc1 = f / sr
            v.inc2 = f * pow(2, Double(P.oct2)) * pow(2, P.det / 1200) / sr
            v.w1 = P.w1.index; v.w2 = P.w2.index
            v.g1 = Float(1 - P.mix); v.g2 = Float(P.mix)
            v.level = 0.26 * vel
            let a = max(0.002, P.a)
            v.aInc = v.level / Float(a * sr)
            v.dCoef = Float(exp(-1 / (max(0.01, P.d / 3) * sr)))
            v.sus = Float(P.s)
            v.rCoef = Float(exp(-1 / (max(0.01, P.r / 3) * sr)))
            let base = min(18000, P.cut * pow(2, Double(pitch - 60) / 30))
            v.cutBase = Float(base); v.cutPeak = Float(min(19000, base * (1 + P.env * 10)))
            v.fenv = 1; v.fCoef = Float(exp(-Double(Self.chunk) / (max(0.01, P.d / 3) * sr)))
            v.k = 1 / Float(0.6 + P.res * 0.6)
        }
        voices[i] = v
    }

    private func decay(_ seconds: Double) -> Float { Float(pow(0.0008, 1 / (seconds * sampleRate))) }
    private func svfG(_ hz: Double) -> Float { Float(tan(Double.pi * min(hz, sampleRate * 0.45) / sampleRate)) }

    private func setupDrum(_ v: inout Voice, pitch: Int, vel: Float) {
        func tone(_ wave: Int, _ f0: Double, _ f1: Double, _ sweep: Double, _ lvl: Float, _ dur: Double) {
            v.tWave = wave; v.tFreq = f0; v.tEnd = f1; v.tCoef = f1 == f0 ? 1 : pow(f1 / f0, 1 / (sweep * sampleRate)); v.tAmp = lvl * vel; v.tDec = decay(dur)
        }
        func noise(_ type: Int, _ hz: Double, _ q: Float, _ lvl: Float, _ dur: Double) {
            v.nType = type; v.nG = svfG(hz); v.nK = 1 / q; v.nAmp = lvl * vel; v.nDec = decay(dur)
        }
        switch pitch {
        case 36: tone(0, 160, 44, 0.11, 1.0, 0.42); noise(3, 3000, 0.7, 0.25, 0.02)
        case 37: tone(3, 1700, 1700, 1, 0.25, 0.03); noise(2, 2600, 4, 0.9, 0.035)
        case 38: tone(1, 240, 150, 0.08, 0.55, 0.14); noise(1, 1500, 0.7, 0.55, 0.2)
        case 39: noise(2, 1300, 1.4, 0.9, 0.018); v.bursts = 2; v.burstCount = Int(0.012 * sampleRate); v.burstLevel = 0.9 * vel; v.tailDec = decay(0.18)
        case 41: tone(0, 130, 80, 0.2, 0.8, 0.36)
        case 45: tone(0, 185, 120, 0.18, 0.8, 0.3)
        case 48: tone(0, 260, 175, 0.15, 0.8, 0.25)
        case 42: noise(1, 7500, 0.7, 0.38, 0.05)
        case 46: noise(1, 7000, 0.7, 0.36, 0.32)
        case 49: noise(1, 5200, 0.7, 0.46, 1.4)
        case 51: noise(2, 8200, 2, 0.5, 0.6); tone(3, 5270, 5270, 1, 0.03, 0.25)
        case 56: tone(3, 540, 540, 1, 0.22, 0.28); v.t2Freq = 800
        default: noise(1, 6000, 0.7, 0.3, 0.04)
        }
    }

    private func startClick(delay: Int, accent: Bool) {
        let i = freeVoice()
        var v = Voice()
        v.active = true; v.drum = true; v.toMaster = true; v.delay = delay; v.slot = -1
        v.tWave = 3; v.tFreq = accent ? 1760 : 1175; v.tEnd = v.tFreq; v.tCoef = 1; v.tAmp = accent ? 0.28 : 0.18; v.tDec = decay(0.035)
        voices[i] = v
    }

    @inline(__always) private func noiseSample() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(Int32(bitPattern: rng)) * (1.0 / 2147483648.0)
    }

    @inline(__always) private func osc(_ w: Int, _ ph: Double, _ inc: Double) -> Float {
        switch w {
        case 0: return Float(sin(ph * 2 * Double.pi))
        case 1: return Float(ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph)
        case 2: return Float(2 * ph - 1 - blep(ph, inc))
        default:
            var x = ph < 0.5 ? 1.0 : -1.0
            x += blep(ph, inc)
            x -= blep(ph + 0.5 < 1 ? ph + 0.5 : ph - 0.5, inc)
            return Float(x)
        }
    }
    @inline(__always) private func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    private func renderVoices(slot: Int, n: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        for vi in 0..<Self.maxVoices {
            if !voices[vi].active || voices[vi].slot != slot { continue }
            var v = voices[vi]
            let start = min(v.delay, n); v.delay -= start
            if start >= n { voices[vi] = v; continue }
            if v.drum {
                for i in start..<n {
                    var s: Float = 0
                    if v.tAmp > 0.0001 {
                        v.ph1 += v.tFreq / sampleRate; if v.ph1 >= 1 { v.ph1 -= 1 }
                        var t = osc(v.tWave, v.ph1, v.tFreq / sampleRate)
                        if v.t2Freq > 0 { v.ph2 += v.t2Freq / sampleRate; if v.ph2 >= 1 { v.ph2 -= 1 }; t += osc(3, v.ph2, v.t2Freq / sampleRate) }
                        s += t * v.tAmp
                        v.tAmp *= v.tDec
                        if v.tCoef != 1 { v.tFreq *= v.tCoef; if (v.tCoef < 1 && v.tFreq < v.tEnd) || (v.tCoef > 1 && v.tFreq > v.tEnd) { v.tFreq = v.tEnd; v.tCoef = 1 } }
                    }
                    if v.nAmp > 0.0001 || v.bursts > 0 {
                        let x = noiseSample()
                        let a1 = 1 / (1 + v.nG * (v.nG + v.nK)), a2 = v.nG * a1, a3 = v.nG * a2
                        let v3 = x - v.ic2, v1 = a1 * v.ic1 + a2 * v3, v2 = v.ic2 + a2 * v.ic1 + a3 * v3
                        v.ic1 = 2 * v1 - v.ic1; v.ic2 = 2 * v2 - v.ic2
                        let f: Float = v.nType == 1 ? x - v.nK * v1 - v2 : (v.nType == 2 ? v1 : v2)
                        s += f * v.nAmp
                        v.nAmp *= v.nDec
                        if v.bursts > 0 {
                            v.burstCount -= 1
                            if v.burstCount <= 0 { v.bursts -= 1; v.nAmp = v.burstLevel; v.burstCount = Int(0.012 * sampleRate); if v.bursts == 0 { v.nDec = v.tailDec } }
                        }
                    }
                    l[i] += s; r[i] += s
                }
                if v.tAmp <= 0.0001 && v.nAmp <= 0.0001 && v.bursts == 0 { v.active = false }
            } else {
                let fc = v.cutBase + (v.cutPeak - v.cutBase) * v.fenv
                v.fenv *= v.fCoef
                let g = svfG(Double(fc)), a1 = 1 / (1 + g * (g + v.k)), a2 = g * a1, a3 = g * a2
                let susLevel = v.sus * v.level
                for i in start..<n {
                    if v.remain >= 0 { if v.remain == 0 { v.stage = 2; v.remain = -1 } else { v.remain -= 1 } }
                    v.ph1 += v.inc1; if v.ph1 >= 1 { v.ph1 -= 1 }
                    v.ph2 += v.inc2; if v.ph2 >= 1 { v.ph2 -= 1 }
                    let x = osc(v.w1, v.ph1, v.inc1) * v.g1 + osc(v.w2, v.ph2, v.inc2) * v.g2
                    let v3 = x - v.ic2, v1 = a1 * v.ic1 + a2 * v3, v2 = v.ic2 + a2 * v.ic1 + a3 * v3
                    v.ic1 = 2 * v1 - v.ic1; v.ic2 = 2 * v2 - v.ic2
                    switch v.stage {
                    case 0: v.env += v.aInc; if v.env >= v.level { v.env = v.level; v.stage = 1 }
                    case 1: v.env = susLevel + (v.env - susLevel) * v.dCoef
                    default: v.env *= v.rCoef
                    }
                    let s = v2 * v.env
                    l[i] += s; r[i] += s
                }
                if v.stage == 2 && v.env < 0.0002 { v.active = false }
            }
            voices[vi] = v
        }
    }

    private func renderAudio(_ t: TrackRT, bpm: Double, n: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        let spb = 60 / bpm
        for c in t.clips {
            let t0 = (beat - c.start) * spb
            if t0 >= c.dur || t0 + Double(n) / sampleRate <= 0 { continue }
            let d = c.data, ratio = d.sampleRate / sampleRate, frames = d.frames
            if frames < 2 { continue }
            let stereo = d.channels.count > 1
            d.channels[0].withUnsafeBufferPointer { c0 in
                d.channels[stereo ? 1 : 0].withUnsafeBufferPointer { c1 in
                    for i in 0..<n {
                        let ts = t0 + Double(i) / sampleRate
                        if ts < 0 || ts >= c.dur { continue }
                        let pos = (c.off + ts) * d.sampleRate
                        let ip = Int(pos); if ip < 0 || ip >= frames - 1 { continue }
                        let fr = Float(pos - Double(ip))
                        var fade: Float = 1
                        if ts < 0.004 { fade = Float(ts / 0.004) } else if c.dur - ts < 0.004 { fade = Float((c.dur - ts) / 0.004) }
                        let g = c.gain * fade
                        l[i] += (c0[ip] + (c0[ip + 1] - c0[ip]) * fr) * g
                        r[i] += (c1[ip] + (c1[ip + 1] - c1[ip]) * fr) * g
                    }
                }
            }
            _ = ratio
        }
    }

    private func renderChunk(_ sn: Snapshot, n: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, bpf: Double) {
        for i in 0..<n { mixL[i] = 0; mixR[i] = 0; revIn[i] = 0; dlyIn[i] = 0 }
        for t in sn.tracks {
            for i in 0..<n { busL[i] = 0; busR[i] = 0 }
            if t.kind == .audio { if playing { renderAudio(t, bpm: sn.bpm, n: n, l: busL, r: busR) } }
            else { renderVoices(slot: t.slot, n: n, l: busL, r: busR) }
            let th = (t.pan + 1) * Float.pi / 4, on: Float = t.audible ? 1 : 0
            let tgl = t.vol * cos(th) * 1.4142 * on, tgr = t.vol * sin(th) * 1.4142 * on
            let g = gains + t.slot * 4
            g[0] += (tgl - g[0]) * 0.25; g[1] += (tgr - g[1]) * 0.25; g[2] += (t.rev * on - g[2]) * 0.25; g[3] += (t.dly * on - g[3]) * 0.25
            var pk: Float = 0
            for i in 0..<n {
                let a = busL[i] * g[0], b = busR[i] * g[1]
                mixL[i] += a; mixR[i] += b
                let m = (a + b) * 0.5
                revIn[i] += m * g[2]; dlyIn[i] += m * g[3]
                let x = max(abs(a), abs(b)); if x > pk { pk = x }
            }
            if pk > meters[t.slot] { meters[t.slot] = pk }
        }
        // tempo delay (dotted eighth)
        let dTime = max(1, min(dlyLen - 1, Int(0.75 / bpf)))
        for i in 0..<n {
            var rp = dlyPos - dTime; if rp < 0 { rp += dlyLen }
            let y = dlyBuf[rp]
            dlyLP += (y - dlyLP) * 0.35
            dlyBuf[dlyPos] = dlyIn[i] + dlyLP * 0.36
            dlyPos += 1; if dlyPos == dlyLen { dlyPos = 0 }
            mixL[i] += dlyLP; mixR[i] += dlyLP
        }
        reverb.process(input: revIn, n: n, left: mixL, right: mixR)
        // master, limiter, metronome
        masterGain += (sn.master - masterGain) * 0.25
        for i in 0..<n { busL[i] = 0; busR[i] = 0 }
        renderVoices(slot: -1, n: n, l: busL, r: busR)
        var pk: Float = 0
        for i in 0..<n {
            var a = mixL[i] * masterGain, b = mixR[i] * masterGain
            let x = max(abs(a), abs(b))
            limEnv = x > limEnv ? x : limEnv * 0.9995
            if limEnv > 0.89 { let gr = 0.89 / limEnv; a *= gr; b *= gr }
            a += busL[i]; b += busR[i]
            a = max(-1, min(1, a)); b = max(-1, min(1, b))
            outL[i] = a; outR[i] = b
            let y = max(abs(a), abs(b)); if y > pk { pk = y }
        }
        if pk > meters[Self.maxTracks] { meters[Self.maxTracks] = pk }
    }

    // MARK: offline bounce

    public static func bounce(_ project: Project, audio: [String: AudioData], sampleRate: Double = 44100) -> (left: [Float], right: [Float]) {
        var p = project; p.loop.on = false
        let e = DAWEngine(sampleRate: sampleRate)
        e.setProject(p, audio: audio); e.send(.play(0))
        let total = Int((p.endBeat * 60 / p.bpm + 2.5) * sampleRate)
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var done = 0
                while done < total { let n = min(4096, total - done); e.render(frames: n, left: lp.baseAddress! + done, right: rp.baseAddress! + done); done += n }
            }
        }
        return (l, r)
    }
}

public enum EngineCommandPublic {
    case play(Double)
    case stop
    case noteOn(UUID, Int, Float)
    case noteOff(UUID, Int)
    case note(UUID, Int, Float, Double)
    case metronome(Bool)
    case countIn(Double)
    case loopEnabled(Bool)
}
