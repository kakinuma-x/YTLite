import AVFoundation

/// Connects the DSP engine to the device: output via AVAudioSourceNode, microphone via an input tap.
final class AudioHost {
    static let rate = 44100.0
    let engine = DAWEngine(sampleRate: AudioHost.rate)
    private let av = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioHost.rate, channels: 2)!
    private var observers: [NSObjectProtocol] = []

    // microphone capture
    private let recLock = NSLock()
    private var recSamples: [Float] = []
    private var recRate = 48000.0
    private var recFirstBeat: Double?
    private var recording = false
    private(set) var inputLevel: Float = 0

    init() {
        let e = engine
        source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = bufs.count > 1 ? (bufs[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            e.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        av.attach(source)
        av.connect(source, to: av.mainMixerNode, format: format)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: av, queue: .main) { [weak self] _ in self?.start() })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.start() }
        })
    }

    private func configureSession(record: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            if record { try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]) }
            else { try s.setCategory(.playback, mode: .default, options: []) }
            try s.setPreferredIOBufferDuration(0.005)
            try s.setActive(true)
        } catch { print("audio session:", error) }
    }

    func start() {
        if av.isRunning { return }
        if !recording { configureSession(record: false) }
        av.prepare()
        do { try av.start() } catch { print("audio engine:", error) }
    }

    /// Total round-trip latency estimate in seconds.
    var latency: Double {
        let s = AVAudioSession.sharedInstance()
        return s.inputLatency + s.outputLatency + s.ioBufferDuration * 2
    }

    func startMic(bpm: Double, done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self, ok else { done(false); return }
                self.av.stop()
                self.recording = true
                self.configureSession(record: true)
                let input = self.av.inputNode
                let fmt = input.outputFormat(forBus: 0)
                guard fmt.sampleRate > 0, fmt.channelCount > 0 else { self.recording = false; self.start(); done(false); return }
                self.recLock.lock(); self.recSamples = []; self.recSamples.reserveCapacity(Int(fmt.sampleRate) * 60); self.recRate = fmt.sampleRate; self.recFirstBeat = nil; self.recLock.unlock()
                let eng = self.engine
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
                    guard let self = self, let ch = buf.floatChannelData else { return }
                    let n = Int(buf.frameLength)
                    var pk: Float = 0
                    self.recLock.lock()
                    if self.recFirstBeat == nil { self.recFirstBeat = eng.positionBeats - Double(n) / fmt.sampleRate * bpm / 60 }
                    let p = ch[0]
                    for i in 0..<n { let x = p[i]; self.recSamples.append(x); if abs(x) > pk { pk = abs(x) } }
                    self.recLock.unlock()
                    self.inputLevel = pk
                }
                self.av.prepare()
                do { try self.av.start(); done(true) } catch { input.removeTap(onBus: 0); self.recording = false; self.start(); done(false) }
            }
        }
    }

    /// Stops capture. Returns samples, their rate and the beat position at which the first sample arrived.
    func stopMic() -> (samples: [Float], rate: Double, firstBeat: Double)? {
        guard recording else { return nil }
        av.inputNode.removeTap(onBus: 0)
        recording = false; inputLevel = 0
        recLock.lock(); let s = recSamples; let fb = recFirstBeat; recSamples = []; recLock.unlock()
        av.stop(); start()
        guard let first = fb, !s.isEmpty else { return nil }
        return (s, recRate, first)
    }

    /// Decodes any audio file Core Audio can read into memory.
    static func load(url: URL) throws -> AudioData {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let n = AVAudioFrameCount(min(f.length, Int64(fmt.sampleRate * 60 * 20)))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { throw CocoaError(.fileReadCorruptFile) }
        try f.read(into: buf, frameCount: n)
        guard let ch = buf.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let len = Int(buf.frameLength)
        var chans: [[Float]] = []
        for c in 0..<min(2, Int(fmt.channelCount)) { chans.append(Array(UnsafeBufferPointer(start: ch[c], count: len))) }
        return AudioData(channels: chans, sampleRate: fmt.sampleRate)
    }
}
