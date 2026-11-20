import Foundation

// Project model. Times are in beats (quarter notes) unless stated otherwise.

public enum TrackKind: String, Codable, Sendable { case synth, drums, audio }

public enum Wave: String, Codable, CaseIterable, Sendable {
    case sine, triangle, saw, square
    public var label: String {
        switch self { case .sine: return "サイン"; case .triangle: return "三角"; case .saw: return "ノコギリ"; case .square: return "矩形" }
    }
    var index: Int { switch self { case .sine: return 0; case .triangle: return 1; case .saw: return 2; case .square: return 3 } }
}

public struct SynthParams: Codable, Equatable, Sendable {
    public var preset: String
    public var w1: Wave, w2: Wave
    public var oct2: Int
    public var det: Double      // cents
    public var mix: Double      // 0...1 osc2 share
    public var cut: Double      // Hz
    public var res: Double
    public var env: Double      // filter envelope amount 0...1
    public var a: Double, d: Double, s: Double, r: Double

    public static let presetNames = ["エレピ", "ベース", "リード", "パッド", "プラック", "オルガン", "ベル"]
    public static func preset(_ name: String) -> SynthParams {
        switch name {
        case "ベース":   return .init(preset: name, w1: .saw, w2: .square, oct2: -1, det: 0, mix: 0.4, cut: 420, res: 3, env: 0.6, a: 0.004, d: 0.25, s: 0.6, r: 0.12)
        case "リード":   return .init(preset: name, w1: .saw, w2: .saw, oct2: 0, det: 12, mix: 0.5, cut: 3200, res: 2, env: 0.3, a: 0.01, d: 0.3, s: 0.8, r: 0.2)
        case "パッド":   return .init(preset: name, w1: .saw, w2: .saw, oct2: 0, det: 16, mix: 0.5, cut: 1400, res: 0.7, env: 0.1, a: 0.5, d: 1.2, s: 0.8, r: 1.2)
        case "プラック": return .init(preset: name, w1: .square, w2: .saw, oct2: 0, det: 6, mix: 0.5, cut: 900, res: 2.5, env: 0.9, a: 0.002, d: 0.22, s: 0.0, r: 0.2)
        case "オルガン": return .init(preset: name, w1: .sine, w2: .sine, oct2: 1, det: 0, mix: 0.45, cut: 6000, res: 0.3, env: 0, a: 0.006, d: 0.1, s: 1, r: 0.06)
        case "ベル":     return .init(preset: name, w1: .sine, w2: .sine, oct2: 2, det: 7, mix: 0.35, cut: 8000, res: 0.3, env: 0, a: 0.002, d: 1.6, s: 0.0, r: 1.2)
        default:         return .init(preset: "エレピ", w1: .sine, w2: .triangle, oct2: 1, det: 3, mix: 0.3, cut: 2600, res: 0.5, env: 0.5, a: 0.004, d: 0.9, s: 0.25, r: 0.35)
        }
    }
}

public struct Note: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var p: Int       // MIDI pitch
    public var t: Double    // start, relative to clip
    public var d: Double    // length
    public var v: Double    // velocity 0...1
    public init(p: Int, t: Double, d: Double, v: Double = 0.8) { self.p = p; self.t = t; self.d = d; self.v = v }
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var len: Double = 4          // note clips
    public var notes: [Note] = []
    public var audioID: String?         // audio clips
    public var off: Double = 0          // seconds into the audio
    public var dur: Double = 0          // seconds
    public var gain: Double = 1
    public var name: String?
    public init(start: Double, len: Double = 4, notes: [Note] = []) { self.start = start; self.len = len; self.notes = notes }
    public init(start: Double, audioID: String, dur: Double, name: String?) { self.start = start; self.audioID = audioID; self.dur = dur; self.name = name }
    public var isAudio: Bool { audioID != nil }
    public func lengthBeats(bpm: Double) -> Double { isAudio ? dur * bpm / 60 : len }
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var kind: TrackKind
    public var color: Int
    public var vol: Double = 0.8
    public var pan: Double = 0
    public var mute = false
    public var solo = false
    public var rev: Double = 0.12
    public var dly: Double = 0
    public var inst: SynthParams = .preset("エレピ")
    public var clips: [Clip] = []
    public init(name: String, kind: TrackKind, color: Int, preset: String = "エレピ") {
        self.name = name; self.kind = kind; self.color = color; self.inst = .preset(preset)
        if kind == .drums { rev = 0.04 }
    }
}

public struct LoopRange: Codable, Equatable, Sendable {
    public var on = false
    public var start: Double = 0
    public var end: Double = 16
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var bpm: Double = 120
    public var master: Double = 0.9
    public var loop = LoopRange()
    public var tracks: [Track] = []
    public var saved = Date()
    public init(name: String) { self.name = name }

    public var endBeat: Double {
        var e = 0.0
        for t in tracks { for c in t.clips { e = max(e, c.start + c.lengthBeats(bpm: bpm)) } }
        return e
    }

    public static func demo() -> Project {
        var p = Project(name: "デモ曲"); p.bpm = 104; p.loop = LoopRange(on: true, start: 0, end: 32)
        var dr = Track(name: "ドラム", kind: .drums, color: 0)
        var bs = Track(name: "ベース", kind: .synth, color: 1, preset: "ベース")
        var ch = Track(name: "コード", kind: .synth, color: 5, preset: "エレピ")
        var ld = Track(name: "メロディ", kind: .synth, color: 3, preset: "プラック")
        var dn: [Note] = []
        for b in 0..<16 {
            let x = Double(b)
            if b % 4 == 0 || b % 8 == 5 { dn.append(Note(p: 36, t: x, d: 0.25, v: 0.95)) }
            if b % 8 == 2 { dn.append(Note(p: 36, t: x + 0.5, d: 0.25, v: 0.8)) }
            if b % 2 == 1 { dn.append(Note(p: 38, t: x, d: 0.25, v: 0.9)) }
            dn.append(Note(p: 42, t: x, d: 0.25, v: 0.7))
            dn.append(Note(p: b % 4 == 3 ? 46 : 42, t: x + 0.5, d: 0.25, v: 0.5))
        }
        dn.append(Note(p: 39, t: 15.5, d: 0.25, v: 0.7))
        let fresh: ([Note]) -> [Note] = { $0.map { Note(p: $0.p, t: $0.t, d: $0.d, v: $0.v) } }
        dr.clips = [Clip(start: 0, len: 16, notes: dn), Clip(start: 16, len: 16, notes: fresh(dn))]
        let roots = [45, 41, 48, 43], tri = [[57, 60, 64], [57, 60, 65], [55, 60, 64], [55, 59, 62]]
        var bn: [Note] = [], cn: [Note] = []
        for i in 0..<4 {
            let o = Double(i) * 4, r = roots[i]
            bn += [Note(p: r - 12, t: o, d: 0.75), Note(p: r - 12, t: o + 1, d: 0.4, v: 0.6), Note(p: r, t: o + 1.5, d: 0.4, v: 0.7),
                   Note(p: r - 12, t: o + 2.5, d: 0.5), Note(p: r - 12, t: o + 3.5, d: 0.4, v: 0.6)]
            for pp in tri[i] { cn += [Note(p: pp, t: o, d: 1.5, v: 0.55), Note(p: pp, t: o + 2.5, d: 1.25, v: 0.5)] }
        }
        bs.clips = [Clip(start: 0, len: 16, notes: bn), Clip(start: 16, len: 16, notes: fresh(bn))]
        ch.clips = [Clip(start: 0, len: 16, notes: cn), Clip(start: 16, len: 16, notes: fresh(cn))]
        let mel: [(Int, Double, Double)] = [(76, 0, 1), (72, 1, 0.5), (74, 1.5, 0.5), (76, 2, 1.5), (69, 4, 1), (72, 5, 0.5), (77, 5.5, 1), (76, 6.5, 1),
                                           (79, 8, 1), (76, 9, 0.5), (72, 9.5, 0.5), (74, 10, 1.5), (71, 12, 1), (74, 13, 0.5), (79, 13.5, 1), (74, 14.5, 1.25)]
        ld.clips = [Clip(start: 16, len: 16, notes: mel.map { Note(p: $0.0, t: $0.1, d: $0.2, v: 0.75) })]
        ld.dly = 0.3; ch.rev = 0.25
        p.tracks = [dr, bs, ch, ld]
        return p
    }
}

public struct DrumPiece: Sendable { public let pitch: Int; public let name: String }
public let drumKit: [DrumPiece] = [
    .init(pitch: 36, name: "Kick"), .init(pitch: 37, name: "Rim"), .init(pitch: 38, name: "Snare"), .init(pitch: 39, name: "Clap"),
    .init(pitch: 41, name: "Tom L"), .init(pitch: 42, name: "HH Cl"), .init(pitch: 45, name: "Tom M"), .init(pitch: 46, name: "HH Op"),
    .init(pitch: 48, name: "Tom H"), .init(pitch: 49, name: "Crash"), .init(pitch: 51, name: "Ride"), .init(pitch: 56, name: "Cowbell"),
]

/// Decoded audio held in memory (one or two channels).
public final class AudioData: @unchecked Sendable {
    public let channels: [[Float]]
    public let sampleRate: Double
    public let peaks: [Float]           // 100 peak values per second, for waveform drawing
    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels; self.sampleRate = sampleRate
        let d = channels.first ?? [], step = max(1, Int(sampleRate / 100))
        var pk = [Float](); pk.reserveCapacity(d.count / step + 1)
        var i = 0
        while i < d.count { var m: Float = 0; var j = i; let e = min(d.count, i + step); while j < e { m = max(m, abs(d[j])); j += 4 }; pk.append(m); i += step }
        peaks = pk
    }
    public var frames: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frames) / sampleRate }

    public func serialized() -> Data {
        var out = Data()
        var sr = sampleRate, ch = Int32(channels.count), n = Int32(frames)
        withUnsafeBytes(of: &sr) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        for c in channels { c.withUnsafeBytes { out.append(contentsOf: $0) } }
        return out
    }
    public convenience init?(serialized data: Data) {
        guard data.count >= 16 else { return nil }
        let sr: Double = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Double.self) }
        let ch = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int32.self) })
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Int32.self) })
        guard ch >= 1, ch <= 2, n >= 0, data.count >= 16 + ch * n * 4, sr > 1000 else { return nil }
        var chans: [[Float]] = []
        for c in 0..<ch {
            var a = [Float](repeating: 0, count: n)
            a.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[(16 + c * n * 4)..<(16 + (c + 1) * n * 4)]))
            } }
            chans.append(a)
        }
        self.init(channels: chans, sampleRate: sr)
    }
}

public func encodeWav16(left: [Float], right: [Float], sampleRate: Int) -> Data {
    let n = min(left.count, right.count)
    var d = Data(capacity: 44 + n * 4)
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 4); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(sampleRate); u32(sampleRate * 4); u16(4); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(n * 4)
    var pcm = [Int16](repeating: 0, count: n * 2)
    for i in 0..<n {
        pcm[i * 2] = Int16(max(-1, min(1, left[i])) * 32767)
        pcm[i * 2 + 1] = Int16(max(-1, min(1, right[i])) * 32767)
    }
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}
