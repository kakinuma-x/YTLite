import SwiftUI
import Observation

enum PanelTab: String, CaseIterable, Identifiable {
    case edit, keys, mix, inst
    var id: String { rawValue }
    var title: String { switch self { case .edit: return "エディタ"; case .keys: return "演奏"; case .mix: return "ミキサー"; case .inst: return "音色" } }
}
enum PanelSize { case normal, big, min }

@Observable final class Meters {
    var levels: [UUID: Float] = [:]
    var master: Float = 0
}

/// App state: the project, selection, transport, undo history and persistence.
@Observable final class Store {
    var project = Project(name: "新しい曲")
    var selTrack: UUID?
    var selClip: UUID?
    var selNotes: Set<UUID> = []
    var pos = 0.0
    var playing = false
    var recording = false
    var tab: PanelTab = .edit
    var panelSize: PanelSize = .normal
    var grid = 0.25
    var lastLen = 0.5
    var newVel = 0.8
    var octave = 4
    var metro = false
    var toast: String?
    var canUndo = false, canRedo = false

    // view state (kept here so playback can follow the playhead)
    var arrPPB: CGFloat = 22, arrX: CGFloat = 0, arrY: CGFloat = 0, arrSize: CGSize = .zero
    var rollPPB: CGFloat = 56, rollX: CGFloat = 0, rollY: CGFloat = 0, rollSize: CGSize = .zero
    var rollBox: CGRect?
    @ObservationIgnored var rollClip: UUID?

    // settings
    var countIn = UserDefaults.standard.object(forKey: "countIn") as? Bool ?? true
    var quantRec = UserDefaults.standard.bool(forKey: "quantRec")
    var latencyMs = UserDefaults.standard.double(forKey: "latencyMs")
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(countIn, forKey: "countIn"); d.set(quantRec, forKey: "quantRec"); d.set(latencyMs, forKey: "latencyMs")
    }

    @ObservationIgnored let host = AudioHost()
    @ObservationIgnored let meters = Meters()
    @ObservationIgnored var audio: [String: AudioData] = [:]
    @ObservationIgnored private var committed = Project(name: "")
    @ObservationIgnored private var undoStack: [Project] = []
    @ObservationIgnored private var redoStack: [Project] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var ticker: Timer?

    private struct RecNote { var p: Int; var t: Double; var d: Double }
    private struct RecState { var track: UUID; var start: Double; var notes: [RecNote] = []; var held: [Int: Double] = [:] }
    @ObservationIgnored private var rec: RecState?
    @ObservationIgnored private var live: Set<Int> = []

    var engine: DAWEngine { host.engine }
    static let rulerH: CGFloat = 26, trackH: CGFloat = 56, keyW: CGFloat = 46

    init() {
        let last = UserDefaults.standard.string(forKey: "lastProject").flatMap(UUID.init(uuidString:))
        if let id = last, let p = Self.read(id) { load(p) } else { let p = Project.demo(); load(p); save() }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); ticker = t
    }

    // MARK: lookups

    func trackIndex(_ id: UUID?) -> Int? { project.tracks.firstIndex { $0.id == id } }
    var selTrackIndex: Int? { trackIndex(selTrack) }
    var selectedTrack: Track? { selTrackIndex.map { project.tracks[$0] } }
    var selClipPath: (Int, Int)? {
        guard let id = selClip else { return nil }
        for (i, t) in project.tracks.enumerated() { if let j = t.clips.firstIndex(where: { $0.id == id }) { return (i, j) } }
        return nil
    }
    var selectedClip: Clip? { selClipPath.map { project.tracks[$0.0].clips[$0.1] } }
    var snapA: Double { arrPPB >= 44 ? 0.25 : (arrPPB >= 13 ? 1 : 4) }
    func say(_ s: String) {
        toast = s; toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
    }

    // MARK: history & persistence

    /// Pushes the current project to the audio engine without recording an undo step (use during drags).
    func sync() { engine.setProject(project, audio: audio) }

    func commit() {
        guard project != committed else { return }
        undoStack.append(committed); if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []; committed = project
        canUndo = true; canRedo = false
        sync(); save()
    }
    private func restore(_ p: Project) {
        project = p; committed = p; selNotes = []
        if trackIndex(selTrack) == nil { selTrack = p.tracks.first?.id }
        if selClipPath == nil { selClip = nil }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        sync(); save()
    }
    func undo() { guard let p = undoStack.popLast() else { return }; redoStack.append(committed); restore(p) }
    func redo() { guard let p = redoStack.popLast() else { return }; undoStack.append(committed); restore(p) }

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func dir(_ name: String) -> URL {
        let u = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func read(_ id: UUID) -> Project? {
        guard let d = try? Data(contentsOf: dir("projects").appendingPathComponent(id.uuidString + ".json")) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: d)
    }
    static func allProjects() -> [Project] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir("projects"), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(Project.self, from: Data(contentsOf: $0)) }.sorted { $0.saved > $1.saved }
    }
    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var p = self.project; p.saved = Date()
            if let d = try? JSONEncoder().encode(p) { try? d.write(to: Self.dir("projects").appendingPathComponent(p.id.uuidString + ".json"), options: .atomic) }
            UserDefaults.standard.set(p.id.uuidString, forKey: "lastProject")
        }
        saveWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
    private func audioURL(_ id: String) -> URL { Self.dir("audio").appendingPathComponent(id + ".pcm") }
    private func storeAudio(_ data: AudioData) -> String {
        let id = project.id.uuidString + "-" + UUID().uuidString
        audio[id] = data
        let url = audioURL(id)
        DispatchQueue.global(qos: .utility).async { try? data.serialized().write(to: url, options: .atomic) }
        return id
    }
    func load(_ p: Project) {
        if playing { stopAll() }
        project = p; committed = p; undoStack = []; redoStack = []; canUndo = false; canRedo = false
        pos = 0; selTrack = p.tracks.first?.id; selClip = nil; selNotes = []; arrX = 0; arrY = 0
        for t in p.tracks { for c in t.clips { if let id = c.audioID, audio[id] == nil, let d = try? Data(contentsOf: audioURL(id)), let a = AudioData(serialized: d) { audio[id] = a } } }
        sync()
        UserDefaults.standard.set(p.id.uuidString, forKey: "lastProject")
    }
    func newProject(name: String) {
        var p = Project(name: name); p.tracks = [Track(name: "シンセ", kind: .synth, color: 0)]
        load(p); save()
    }
    func deleteProject(_ p: Project) {
        try? FileManager.default.removeItem(at: Self.dir("projects").appendingPathComponent(p.id.uuidString + ".json"))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir("audio"), includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(p.id.uuidString + "-") { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: transport

    private func tick() {
        if playing {
            pos = engine.positionBeats
            let px = CGFloat(pos) * arrPPB - arrX
            if arrSize.width > 60, px > arrSize.width - 24 || px < 0 { arrX = max(0, CGFloat(pos) * arrPPB - 40) }
            if tab == .edit, let c = selectedClip, !c.isAudio, pos >= c.start, pos < c.start + c.len, rollSize.width > 80 {
                let rp = CGFloat(pos - c.start) * rollPPB - rollX
                if rp > rollSize.width - Self.keyW - 24 || rp < 0 { rollX = max(0, CGFloat(pos - c.start) * rollPPB - 30) }
            }
            if !recording && !project.loop.on && pos > project.endBeat + 8 { stopAll() }
        }
        if tab == .mix && panelSize != .min {
            for t in project.tracks { let v = engine.takeMeter(t.id); meters.levels[t.id] = max(v, (meters.levels[t.id] ?? 0) * 0.86) }
            meters.master = max(engine.takeMeter(nil), meters.master * 0.86)
        }
    }

    func setPos(_ b: Double) {
        pos = max(0, b)
        if playing && !recording { engine.send(.play(pos)) }
    }
    func togglePlay() {
        if playing { stopAll(); return }
        host.start()
        engine.send(.metronome(metro)); engine.send(.countIn(-.infinity)); engine.send(.loopEnabled(true))
        let e = project.endBeat, L = project.loop
        if !(L.on && pos < L.end) && e > 0 && pos >= e { pos = 0 }
        engine.send(.play(pos)); playing = true
    }
    func stopAll() {
        if playing { pos = max(0, engine.positionBeats) }
        engine.send(.stop); playing = false
        for p in live { liveOff(p) }
        if recording { finishRec() }
    }
    func goHome() {
        let L = project.loop
        setPos(L.on && pos > L.start + 0.01 ? L.start : 0)
        arrX = max(0, CGFloat(pos) * arrPPB - 40)
    }
    func setBpm(_ v: Double) { project.bpm = min(240, max(40, v.rounded())); sync() }
    func toggleMetro() { metro.toggle(); engine.send(.metronome(metro)) }

    func toggleRecord() {
        if recording { stopAll(); return }
        guard let t = selectedTrack else { say("録音するトラックを選んでください"); return }
        if playing { stopAll() }
        host.start()
        let begin = { [weak self] in
            guard let self = self else { return }
            let start = self.pos, pre = self.countIn ? 4.0 : 0
            self.rec = RecState(track: t.id, start: start)
            self.engine.send(.metronome(self.metro)); self.engine.send(.countIn(start)); self.engine.send(.loopEnabled(false))
            self.engine.send(.play(start - pre))
            self.playing = true; self.recording = true
            if t.kind != .audio && self.tab != .keys { self.tab = .keys; if self.panelSize == .min { self.panelSize = .normal } }
        }
        if t.kind == .audio {
            host.startMic(bpm: project.bpm) { [weak self] ok in
                if ok { begin() } else { self?.say("マイクを使用できません。設定アプリでマイクの許可を確認してください") }
            }
        } else { begin() }
    }

    private func finishRec() {
        recording = false
        guard let r = rec else { return }
        rec = nil
        guard let ti = trackIndex(r.track) else { return }
        let spb = 60 / project.bpm
        if project.tracks[ti].kind != .audio {
            let notes = r.notes.filter { $0.t >= r.start - 0.15 }
            if notes.isEmpty { say("ノートは録音されませんでした"); return }
            let cs = (r.start / 4).rounded(.down) * 4
            var last = 0.0
            let out: [Note] = notes.map { n in
                var t = max(r.start, n.t) - cs, d = n.d
                if quantRec { t = (t / grid).rounded() * grid; d = max(grid, (d / grid).rounded() * grid) }
                last = max(last, t + d)
                return Note(p: n.p, t: t, d: d, v: 0.85)
            }
            let cl = Clip(start: cs, len: max(4, ((last - 0.01) / 4).rounded(.up) * 4), notes: out)
            project.tracks[ti].clips.append(cl); selClip = cl.id; selNotes = []
            commit()
        } else {
            guard let m = host.stopMic() else { say("録音できませんでした"); return }
            let lat = host.latency + latencyMs / 1000
            let firstBeat = m.firstBeat - lat / spb
            var skip = Int(((r.start - firstBeat) * spb * m.rate).rounded()), start = r.start
            if skip < 0 { start += Double(-skip) / m.rate / spb; skip = 0 }
            guard skip < m.samples.count, Double(m.samples.count - skip) > m.rate * 0.15 else { say("録音が短すぎます"); return }
            let data = AudioData(channels: [Array(m.samples[skip...])], sampleRate: m.rate)
            let id = storeAudio(data)
            let cl = Clip(start: start, audioID: id, dur: data.duration, name: "録音")
            project.tracks[ti].clips.append(cl); selClip = cl.id
            commit()
        }
    }

    // MARK: live playing

    func liveOn(_ pitch: Int) {
        guard let t = selectedTrack, t.kind != .audio else { return }
        host.start()
        if live.contains(pitch) { liveOff(pitch) }
        live.insert(pitch)
        engine.send(.noteOn(t.id, pitch, 0.85))
        if recording, playing, rec?.track == t.id {
            let b = engine.positionBeats
            if t.kind == .drums { rec?.notes.append(RecNote(p: pitch, t: b, d: grid)) } else { rec?.held[pitch] = b }
        }
    }
    func liveOff(_ pitch: Int) {
        guard live.remove(pitch) != nil else { return }
        if let t = selectedTrack { engine.send(.noteOff(t.id, pitch)) }
        if let t0 = rec?.held[pitch] {
            rec?.held[pitch] = nil
            let b = playing ? engine.positionBeats : pos
            rec?.notes.append(RecNote(p: pitch, t: t0, d: max(0.06, b - t0)))
        }
    }
    func audition(_ track: UUID, _ pitch: Int, _ vel: Double = 0.8) {
        host.start(); engine.send(.note(track, pitch, Float(vel), 0.22))
    }

    // MARK: editing

    func openPanel(_ t: PanelTab) { tab = t; if panelSize == .min { panelSize = .normal } }
    func cyclePanel() { panelSize = panelSize == .normal ? .big : (panelSize == .big ? .min : .normal) }

    func addTrack(_ kind: TrackKind) {
        guard project.tracks.count < DAWEngine.maxTracks else { say("トラックは\(DAWEngine.maxTracks)本までです"); return }
        let name = kind == .synth ? "シンセ" : (kind == .drums ? "ドラム" : "オーディオ")
        let t = Track(name: name, kind: kind, color: project.tracks.count % Theme.trackColors.count)
        project.tracks.append(t); selTrack = t.id; selClip = nil; arrY = 100000
        commit()
    }
    func addClip(at: Double? = nil) {
        guard let ti = selTrackIndex else { say("先にトラックを追加してください"); return }
        guard project.tracks[ti].kind != .audio else { say("オーディオトラックには録音か読み込みで追加します"); return }
        let cl = Clip(start: at ?? (pos / 4).rounded(.down) * 4, len: 4)
        project.tracks[ti].clips.append(cl); selClip = cl.id; selNotes = []
        commit(); openPanel(.edit)
    }
    func duplicateClip() {
        guard let (ti, ci) = selClipPath else { say("クリップを選んでください"); return }
        let src = project.tracks[ti].clips[ci], sn = snapA
        var c2 = src; c2.id = UUID(); c2.notes = src.notes.map { Note(p: $0.p, t: $0.t, d: $0.d, v: $0.v) }
        c2.start = src.start + max(sn, (src.lengthBeats(bpm: project.bpm) / sn - 1e-6).rounded(.up) * sn)
        project.tracks[ti].clips.append(c2); selClip = c2.id; selNotes = []
        commit()
    }
    func splitClip() {
        guard let (ti, ci) = selClipPath else { say("クリップを選んでください"); return }
        var cl = project.tracks[ti].clips[ci]
        let rel = pos - cl.start
        guard rel > 0.01, rel < cl.lengthBeats(bpm: project.bpm) - 0.01 else { say("再生位置をクリップの途中に置いてください"); return }
        var c2 = cl; c2.id = UUID(); c2.start = pos
        if cl.isAudio { let sec = rel * 60 / project.bpm; c2.off = cl.off + sec; c2.dur = cl.dur - sec; cl.dur = sec }
        else {
            c2.notes = cl.notes.filter { $0.t >= rel }.map { Note(p: $0.p, t: $0.t - rel, d: $0.d, v: $0.v) }
            c2.len = cl.len - rel; cl.notes = cl.notes.filter { $0.t < rel }; cl.len = rel
        }
        project.tracks[ti].clips[ci] = cl; project.tracks[ti].clips.append(c2); selNotes = []
        commit()
    }
    func deleteClip() {
        guard let (ti, ci) = selClipPath else { return }
        project.tracks[ti].clips.remove(at: ci); selClip = nil; selNotes = []
        commit()
    }
    func deleteTrack(_ id: UUID) {
        guard let ti = trackIndex(id) else { return }
        project.tracks.remove(at: ti); selTrack = project.tracks.first?.id; selClip = nil
        commit()
    }
    func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? AudioHost.load(url: url), data.frames > 1 else { say("この音声ファイルは読み込めませんでした"); return }
        let id = storeAudio(data)
        var ti = selTrackIndex
        if ti == nil || project.tracks[ti!].kind != .audio {
            guard project.tracks.count < DAWEngine.maxTracks else { say("トラックは\(DAWEngine.maxTracks)本までです"); return }
            let t = Track(name: "オーディオ", kind: .audio, color: project.tracks.count % Theme.trackColors.count)
            project.tracks.append(t); selTrack = t.id; ti = project.tracks.count - 1
        }
        let cl = Clip(start: pos, audioID: id, dur: data.duration, name: String(url.deletingPathExtension().lastPathComponent.prefix(24)))
        project.tracks[ti!].clips.append(cl); selClip = cl.id
        commit(); say("読み込みました")
    }

    func zoomArr(_ f: CGFloat, at cx: CGFloat? = nil) {
        let c = cx ?? arrSize.width / 2, b = (c + arrX) / arrPPB
        arrPPB = min(170, max(3, arrPPB * f)); arrX = max(0, b * arrPPB - c)
    }
    func zoomRoll(_ f: CGFloat, at cx: CGFloat? = nil) {
        let c = cx ?? rollSize.width / 2, b = (c - Self.keyW + rollX) / rollPPB
        rollPPB = min(320, max(10, rollPPB * f)); rollX = max(0, b * rollPPB - (c - Self.keyW))
    }

    // MARK: note editing helpers

    func growClip(_ ti: Int, _ ci: Int) {
        var e = 0.0
        for n in project.tracks[ti].clips[ci].notes { e = max(e, n.t + n.d) }
        if e > project.tracks[ti].clips[ci].len + 1e-6 { project.tracks[ti].clips[ci].len = (e / 4 - 1e-6).rounded(.up) * 4 }
    }
    func quantize() {
        guard let (ti, ci) = selClipPath else { return }
        for i in project.tracks[ti].clips[ci].notes.indices {
            let n = project.tracks[ti].clips[ci].notes[i]
            if selNotes.isEmpty || selNotes.contains(n.id) { project.tracks[ti].clips[ci].notes[i].t = max(0, (n.t / grid).rounded() * grid) }
        }
        commit()
    }
    func selectAllNotes() {
        guard let c = selectedClip else { return }
        selNotes = selNotes.count == c.notes.count ? [] : Set(c.notes.map { $0.id })
    }
    func deleteNotes() {
        guard let (ti, ci) = selClipPath, !selNotes.isEmpty else { say("削除するノートを選んでください"); return }
        project.tracks[ti].clips[ci].notes.removeAll { selNotes.contains($0.id) }; selNotes = []
        commit()
    }
    func setVelocity(_ v: Double) {
        newVel = v
        guard let (ti, ci) = selClipPath else { return }
        for i in project.tracks[ti].clips[ci].notes.indices where selNotes.contains(project.tracks[ti].clips[ci].notes[i].id) { project.tracks[ti].clips[ci].notes[i].v = v }
    }

    // MARK: export

    func exportWav() async -> URL? {
        if playing { stopAll() }
        let p = project, a = audio
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let out = DAWEngine.bounce(p, audio: a)
            let data = encodeWav16(left: out.left, right: out.right, sampleRate: 44100)
            let safe = p.name.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined(separator: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "song" : safe) + ".wav")
            do { try data.write(to: url, options: .atomic); return url } catch { return nil }
        }.value
    }
}
