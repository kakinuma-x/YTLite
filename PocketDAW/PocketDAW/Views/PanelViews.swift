import SwiftUI

struct LabeledSlider: View {
    var label: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var done: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.dim).frame(width: 64, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
            Slider(value: value, in: range) { editing in if !editing { done() } }.tint(Theme.accent).accessibilityLabel(label)
            Text(format(value.wrappedValue)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 44, alignment: .trailing)
        }
        .frame(minHeight: 32)
    }
}

private let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }

/// Keyboard / drum pads for the selected track.
struct KeysView: View {
    @Environment(Store.self) private var store
    @Binding var importing: Bool
    var body: some View {
        let s = store
        if let t = s.selectedTrack {
            switch t.kind {
            case .audio:
                VStack(alignment: .leading, spacing: 12) {
                    Button("音声ファイルを読み込む") { importing = true }.buttonStyle(BarButton())
                    Text("オーディオトラックです。● を押すとマイク録音が始まり、もう一度押すと止まります。伴奏の回り込みを防ぐため、録音中はイヤホンの使用をおすすめします。")
                        .font(.system(size: 14)).foregroundStyle(Theme.dim)
                    Spacer()
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            case .drums:
                VStack(spacing: 0) {
                    Text("\(t.name)　パッドを叩いて演奏。● で録音").font(.system(size: 12)).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                    PlaySurface(drums: true, octave: 0, onDown: { s.liveOn($0) }, onUp: { s.liveOff($0) })
                }
            case .synth:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Button("オクターブ −") { s.octave = max(0, s.octave - 1) }
                        Text("C\(s.octave)").font(.system(size: 14, design: .monospaced)).frame(width: 32)
                        Button("オクターブ ＋") { s.octave = min(7, s.octave + 1) }
                        Text(t.name).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }.buttonStyle(BarButton()).padding(.horizontal, 8).padding(.vertical, 5)
                    PlaySurface(drums: false, octave: s.octave, onDown: { s.liveOn($0) }, onUp: { s.liveOff($0) })
                }
            }
        } else {
            Text("トラックを追加すると、ここで演奏できます。").foregroundStyle(Theme.dim).padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct MeterBar: View {
    var meters: Meters
    var id: UUID?
    var body: some View {
        let pk = id.map { meters.levels[$0] ?? 0 } ?? meters.master
        let db = 20 * log10(Double(pk) + 1e-5), f = CGFloat(min(1, max(0, (db + 48) / 48)))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Theme.raise
                LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7), .init(color: .orange, location: 0.71), .init(color: .orange, location: 0.9), .init(color: .red, location: 0.91)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width).mask(alignment: .leading) { Rectangle().frame(width: g.size.width * f) }
            }
        }
        .frame(height: 5).clipShape(Capsule())
    }
}

struct MixerView: View {
    @Environment(Store.self) private var store
    var body: some View {
        let s = store
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], spacing: 8) {
                ForEach(s.project.tracks) { t in
                    strip(title: t.name, color: Theme.track(t.color), id: t.id) {
                        flag("M", t.mute) { $0.mute.toggle() }
                        flag("S", t.solo) { $0.solo.toggle() }
                    } sliders: {
                        LabeledSlider(label: "音量", value: bind(t.id, \.vol), range: 0...1.2, format: pct, done: s.commit)
                        LabeledSlider(label: "パン", value: bind(t.id, \.pan), range: -1...1, format: { abs($0) < 0.02 ? "C" : ($0 < 0 ? "L" : "R") + "\(Int(abs($0) * 100))" }, done: s.commit)
                        LabeledSlider(label: "リバーブ", value: bind(t.id, \.rev), range: 0...1, format: pct, done: s.commit)
                        LabeledSlider(label: "ディレイ", value: bind(t.id, \.dly), range: 0...1, format: pct, done: s.commit)
                    }
                }
                strip(title: "マスター", color: Theme.accent, id: nil) { EmptyView() } sliders: {
                    LabeledSlider(label: "音量", value: Binding(get: { s.project.master }, set: { s.project.master = $0; s.sync() }), range: 0...1.2, format: pct, done: s.commit)
                }
            }.padding(8)
        }
    }
    private func bind(_ id: UUID, _ key: WritableKeyPath<Track, Double>) -> Binding<Double> {
        let s = store
        return Binding(get: { s.trackIndex(id).map { s.project.tracks[$0][keyPath: key] } ?? 0 },
                       set: { v in if let i = s.trackIndex(id) { s.project.tracks[i][keyPath: key] = v; s.sync() } })
    }
    private func flag(_ label: String, _ on: Bool, _ change: @escaping (inout Track) -> Void) -> some View {
        FlagButton(label: label, on: on, change: change)
    }
    private func strip<A: View, B: View>(title: String, color: Color, id: UUID?, @ViewBuilder buttons: () -> A, @ViewBuilder sliders: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                buttons().environment(\.mixTrack, id)
            }
            MeterBar(meters: store.meters, id: id).padding(.bottom, 4)
            sliders()
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) { color.frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(.vertical, 6) }
    }
}

private struct MixTrackKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues { var mixTrack: UUID? { get { self[MixTrackKey.self] } set { self[MixTrackKey.self] = newValue } } }

private struct FlagButton: View {
    @Environment(Store.self) private var store
    @Environment(\.mixTrack) private var id
    var label: String
    var on: Bool
    var change: (inout Track) -> Void
    var body: some View {
        Button {
            if let i = store.trackIndex(id) { change(&store.project.tracks[i]); store.commit() }
        } label: {
            Text(label).font(.system(size: 11, weight: .bold)).frame(width: 30, height: 26)
                .foregroundStyle(on ? Theme.onAccent : Theme.fg)
                .background(on ? Theme.accent : Theme.raise, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: on ? 0 : 1))
        }.buttonStyle(.plain).accessibilityLabel(label == "M" ? "ミュート" : "ソロ")
    }
}

/// Track settings: name, colour, synth parameters.
struct SoundView: View {
    @Environment(Store.self) private var store
    @Binding var importing: Bool
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        let s = store
        ScrollView {
            if let t = s.selectedTrack, let ti = s.selTrackIndex {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("名前: \(t.name)") { newName = t.name; renaming = true }.buttonStyle(BarButton())
                        ForEach(Theme.trackColors.indices, id: \.self) { i in
                            Button { s.project.tracks[ti].color = i; s.commit() } label: {
                                Circle().fill(Theme.trackColors[i]).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Theme.fg, lineWidth: t.color == i ? 2 : 0).padding(-3))
                            }.buttonStyle(.plain).accessibilityLabel("色 \(i + 1)")
                        }
                    }
                    if t.kind == .synth { synth(t, ti) }
                    else if t.kind == .drums {
                        Text("内蔵ドラムキット（キック、スネア、クラップ、ハイハット、タム、シンバルなど12パーツ）。音量・リバーブはミキサーで調整します。").font(.system(size: 14)).foregroundStyle(Theme.dim)
                    } else {
                        Button("音声ファイルを読み込む") { importing = true }.buttonStyle(BarButton())
                        LabeledSlider(label: "録音補正", value: Binding(get: { s.latencyMs }, set: { s.latencyMs = ($0 / 5).rounded() * 5 }), range: -200...300, format: { "\(Int($0))ms" }, done: s.saveSettings)
                        Text("録音が伴奏より遅れて聞こえるときは「録音補正」を増やしてください（次の録音から反映）。").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                    Button("トラック削除") { confirmDelete = true }.buttonStyle(BarButton(tint: Theme.rec)).padding(.top, 4)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .alert("トラック名", isPresented: $renaming) {
                    TextField("名前", text: $newName)
                    Button("OK") { let v = newName.trimmingCharacters(in: .whitespaces); if !v.isEmpty, let i = s.trackIndex(t.id) { s.project.tracks[i].name = v; s.commit() } }
                    Button("キャンセル", role: .cancel) {}
                }
                .confirmationDialog("「\(t.name)」とその中のクリップをすべて削除します。", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("削除", role: .destructive) { s.deleteTrack(t.id) }
                }
            } else {
                Text("トラックがありません。「＋トラック」で追加してください。").foregroundStyle(Theme.dim).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func synth(_ t: Track, _ ti: Int) -> some View {
        let s = store
        let P = t.inst
        let b: (WritableKeyPath<SynthParams, Double>) -> Binding<Double> = { key in
            Binding(get: { s.trackIndex(t.id).map { s.project.tracks[$0].inst[keyPath: key] } ?? 0 },
                    set: { v in if let i = s.trackIndex(t.id) { s.project.tracks[i].inst[keyPath: key] = v; s.sync() } })
        }
        // curved mappings so short times and low cutoffs get fine control
        let curve: (WritableKeyPath<SynthParams, Double>, Double, Double) -> Binding<Double> = { key, lo, k in
            Binding(get: { sqrt(max(0, ((s.trackIndex(t.id).map { s.project.tracks[$0].inst[keyPath: key] } ?? lo) - lo) / k)) },
                    set: { x in if let i = s.trackIndex(t.id) { s.project.tracks[i].inst[keyPath: key] = lo + x * x * k; s.sync() } })
        }
        let cutoff = Binding<Double>(get: { log(max(80, P.cut) / 80) / log(150) }, set: { x in s.project.tracks[ti].inst.cut = 80 * pow(150, x); s.sync() })
        let sec: (Double) -> String = { $0 < 1 ? "\(Int($0 * 1000))ms" : String(format: "%.1fs", $0) }
        HStack(spacing: 8) {
            Menu {
                ForEach(SynthParams.presetNames, id: \.self) { name in
                    Button(name) { s.project.tracks[ti].inst = .preset(name); s.commit(); s.audition(t.id, 60) }
                }
            } label: { Text("プリセット: \(P.preset)") }.buttonStyle(BarButton())
            wavePicker("波形1", \.w1, t.id)
            wavePicker("波形2", \.w2, t.id)
            Button("試聴") { s.audition(t.id, 60) }.buttonStyle(BarButton())
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18)], spacing: 0) {
            LabeledSlider(label: "ミックス", value: b(\.mix), range: 0...1, format: pct, done: s.commit)
            LabeledSlider(label: "デチューン", value: b(\.det), range: 0...40, format: { "\(Int($0))c" }, done: s.commit)
            LabeledSlider(label: "波形2 Oct", value: Binding(get: { Double(P.oct2) }, set: { s.project.tracks[ti].inst.oct2 = Int($0.rounded()); s.sync() }), range: -2...2, format: { ($0 > 0 ? "+" : "") + "\(Int($0.rounded()))" }, done: s.commit)
            LabeledSlider(label: "カットオフ", value: cutoff, range: 0...1, format: { let hz = 80 * pow(150, $0); return hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz))" }, done: s.commit)
            LabeledSlider(label: "レゾナンス", value: b(\.res), range: 0.1...12, format: { String(format: "%.1f", $0) }, done: s.commit)
            LabeledSlider(label: "フィルタEnv", value: b(\.env), range: 0...1, format: pct, done: s.commit)
            LabeledSlider(label: "アタック", value: curve(\.a, 0.002, 2), range: 0...1, format: { sec(0.002 + $0 * $0 * 2) }, done: s.commit)
            LabeledSlider(label: "ディケイ", value: curve(\.d, 0.02, 3), range: 0...1, format: { sec(0.02 + $0 * $0 * 3) }, done: s.commit)
            LabeledSlider(label: "サステイン", value: b(\.s), range: 0...1, format: pct, done: s.commit)
            LabeledSlider(label: "リリース", value: curve(\.r, 0.02, 3), range: 0...1, format: { sec(0.02 + $0 * $0 * 3) }, done: s.commit)
        }
    }

    private func wavePicker(_ label: String, _ key: WritableKeyPath<SynthParams, Wave>, _ id: UUID) -> some View {
        let s = store
        return Menu {
            ForEach(Wave.allCases, id: \.self) { w in
                Button(w.label) { if let i = s.trackIndex(id) { s.project.tracks[i].inst[keyPath: key] = w; s.commit() } }
            }
        } label: { Text("\(label): \(s.trackIndex(id).map { s.project.tracks[$0].inst[keyPath: key].label } ?? "")") }.buttonStyle(BarButton())
    }
}

/// Shown in the editor tab when no note clip is selected.
struct ClipInfoView: View {
    @Environment(Store.self) private var store
    @State private var renaming = false
    @State private var newName = ""
    var body: some View {
        let s = store
        ScrollView {
            if let (ti, ci) = s.selClipPath, s.project.tracks[ti].clips[ci].isAudio {
                let cl = s.project.tracks[ti].clips[ci]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("名前: \(cl.name ?? "オーディオ")") { newName = cl.name ?? ""; renaming = true }.buttonStyle(BarButton())
                        Text(String(format: "長さ %.2f 秒", cl.dur)).font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                    LabeledSlider(label: "ゲイン", value: Binding(get: { s.selectedClip?.gain ?? 1 }, set: { v in if let (a, b) = s.selClipPath { s.project.tracks[a].clips[b].gain = v; s.sync() } }), range: 0...2, format: pct, done: s.commit)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .alert("クリップ名", isPresented: $renaming) {
                    TextField("名前", text: $newName)
                    Button("OK") { if let (a, b) = s.selClipPath, !newName.isEmpty { s.project.tracks[a].clips[b].name = newName; s.commit() } }
                    Button("キャンセル", role: .cancel) {}
                }
            } else {
                Text("クリップを選ぶとここで編集できます。タイムラインの空き部分をダブルタップ、または「＋クリップ」で新しいクリップを作成。クリップはタップで選択、選択中のクリップをドラッグで移動、右端のドラッグで長さ変更。")
                    .font(.system(size: 14)).foregroundStyle(Theme.dim).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
