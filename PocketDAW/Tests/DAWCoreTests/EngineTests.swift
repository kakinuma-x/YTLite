import XCTest
@testable import DAWCore

final class EngineTests: XCTestCase {
    func testBounceDemoProducesBoundedAudio() {
        let p = Project.demo()
        let out = DAWEngine.bounce(p, audio: [:])
        let expected = Int((p.endBeat * 60 / p.bpm + 2.5) * 44100)
        XCTAssertEqual(out.left.count, expected)
        let peak = out.left.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertLessThanOrEqual(peak, 1.0)
        XCTAssertFalse(out.left.contains { $0.isNaN })
        // the tail after the last note must die away
        let tail = out.left.suffix(2000).map { abs($0) }.max() ?? 1
        XCTAssertLessThan(tail, 0.05)
    }

    func testMuteSilencesTrack() {
        var p = Project(name: "t")
        var t = Track(name: "s", kind: .synth, color: 0)
        t.clips = [Clip(start: 0, len: 4, notes: [Note(p: 60, t: 0, d: 1)])]
        t.rev = 0
        p.tracks = [t]
        XCTAssertGreaterThan(DAWEngine.bounce(p, audio: [:]).left.map { abs($0) }.max() ?? 0, 0.02)
        p.tracks[0].mute = true
        XCTAssertLessThan(DAWEngine.bounce(p, audio: [:]).left.map { abs($0) }.max() ?? 1, 0.0001)
    }

    func testLoopWrapsPosition() {
        var p = Project(name: "t"); p.bpm = 120; p.loop = LoopRange(on: true, start: 0, end: 4)
        p.tracks = [Track(name: "s", kind: .synth, color: 0)]
        let e = DAWEngine(sampleRate: 44100)
        e.setProject(p, audio: [:]); e.send(.play(3))
        var l = [Float](repeating: 0, count: 44100), r = l
        e.render(frames: 44100, left: &l, right: &r)   // 1 s = 2 beats: 3 -> 5 -> wraps to 1
        XCTAssertEqual(e.positionBeats, 1, accuracy: 0.01)
    }

    func testAudioClipPlaysAndRoundTrips() {
        let tone = (0..<44100).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.5 }
        let data = AudioData(channels: [tone], sampleRate: 44100)
        let back = AudioData(serialized: data.serialized())
        XCTAssertEqual(back?.frames, 44100)
        XCTAssertEqual(back?.channels[0][1000], tone[1000])
        var p = Project(name: "t")
        var t = Track(name: "a", kind: .audio, color: 0); t.rev = 0
        t.clips = [Clip(start: 2, audioID: "x", dur: 1, name: nil)]
        p.tracks = [t]
        let out = DAWEngine.bounce(p, audio: ["x": data])
        XCTAssertLessThan(out.left[0..<40000].map { abs($0) }.max() ?? 1, 0.0001)      // silent before beat 2 (1 s)
        XCTAssertGreaterThan(out.left[44100..<88200].map { abs($0) }.max() ?? 0, 0.3)
    }

    func testWavHeader() {
        let d = encodeWav16(left: [0, 0.5], right: [0, -0.5], sampleRate: 44100)
        XCTAssertEqual(d.count, 44 + 8)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
    }
}
