import SwiftUI
import UniformTypeIdentifiers

enum SheetKind: String, Identifiable { case menu, projects, settings, help, bpm, addTrack, export; var id: String { rawValue } }

/// One-screen studio: transport on top, timeline in the middle, a tabbed work panel below.
/// The same layout serves the narrow outer display and the unfolded inner display; only proportions change.
struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var sheet: SheetKind?
    @State private var importing = false
    @State private var confirmDeleteTrack = false

    var body: some View {
        let s = store
        GeometryReader { geo in
            let wide = geo.size.width >= 600
            VStack(spacing: 0) {
                TransportBar(sheet: $sheet)
                ArrangementView(headWidth: wide ? 150 : 104).frame(maxHeight: .infinity)
                clipBar
                tabBar
                if s.panelSize != .min {
                    panel.frame(height: max(150, geo.size.height * (s.panelSize == .big ? 0.62 : (geo.size.height < 520 ? 0.36 : 0.42))))
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.fg)
        .overlay(alignment: .bottom) {
            if let t = s.toast {
                Text(t).font(.system(size: 13)).foregroundStyle(Theme.bg).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.fg, in: Capsule()).padding(.bottom, 24).padding(.horizontal, 20).allowsHitTesting(false)
            }
        }
        .sheet(item: $sheet) { kind in
            SheetView(kind: kind, sheet: $sheet).environment(s).presentationDetents(kind == .bpm || kind == .addTrack ? [.medium] : [.medium, .large])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { s.importAudio(url) }
        }
        .confirmationDialog("選択中のトラックを削除します。", isPresented: $confirmDeleteTrack, titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let id = s.selTrack { s.deleteTrack(id) } }
        }
    }

    private var clipBar: some View {
        let s = store
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("↶") { s.undo() }.disabled(!s.canUndo).accessibilityLabel("元に戻す")
                Button("↷") { s.redo() }.disabled(!s.canRedo).accessibilityLabel("やり直す")
                Theme.line.frame(width: 1, height: 22)
                Button("＋トラック") { sheet = .addTrack }
                Button("＋クリップ") { if s.selectedTrack?.kind == .audio { importing = true } else { s.addClip() } }
                Theme.line.frame(width: 1, height: 22)
                Button("複製") { s.duplicateClip() }.disabled(s.selClip == nil)
                Button("分割") { s.splitClip() }.disabled(s.selClip == nil)
                Button("削除") { if s.selClip != nil { s.deleteClip() } else if s.selTrack != nil { confirmDeleteTrack = true } }.buttonStyle(BarButton(tint: Theme.rec))
                Theme.line.frame(width: 1, height: 22)
                Button("−") { s.zoomArr(1 / 1.4) }.accessibilityLabel("縮小")
                Button("＋") { s.zoomArr(1.4) }.accessibilityLabel("拡大")
            }
            .buttonStyle(BarButton()).padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var tabBar: some View {
        let s = store
        return HStack(spacing: 0) {
            ForEach(PanelTab.allCases) { t in
                let on = s.tab == t && s.panelSize != .min
                Button { s.openPanel(t) } label: {
                    Text(t.title).font(.system(size: 14, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.fg : Theme.dim)
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .overlay(alignment: .bottom) { (on ? Theme.accent : Color.clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Button { s.cyclePanel() } label: { Image(systemName: "arrow.up.and.down").frame(width: 44, height: 38).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim).accessibilityLabel("パネルの大きさ")
        }
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    @ViewBuilder private var panel: some View {
        let s = store
        switch s.tab {
        case .edit:
            if let c = s.selectedClip, !c.isAudio { PianoRollView() } else { ClipInfoView() }
        case .keys: KeysView(importing: $importing)
        case .mix: MixerView()
        case .inst: SoundView(importing: $importing)
        }
    }
}

struct TransportBar: View {
    @Environment(Store.self) private var store
    @Binding var sheet: SheetKind?
    var body: some View {
        let s = store
        let b = max(0, s.pos), sec = b * 60 / s.project.bpm
        let barNo = Int(b / 4) + 1, beatNo = Int(b.truncatingRemainder(dividingBy: 4)) + 1
        let sixteenth = Int(b.truncatingRemainder(dividingBy: 1) * 4 + 1e-6) + 1
        let position = "\(barNo).\(beatNo).\(sixteenth)"
        HStack(spacing: 6) {
            icon("line.3.horizontal", "メニュー") { sheet = .menu }
            icon("backward.end.fill", "先頭へ") { s.goHome() }
            icon(s.playing ? "stop.fill" : "play.fill", "再生／停止", on: s.playing && !s.recording) { s.togglePlay() }
            icon("circle.fill", "録音", on: s.recording, tint: Theme.rec) { s.toggleRecord() }
            icon("repeat", "ループ", on: s.project.loop.on) { s.project.loop.on.toggle(); s.commit() }
            icon("metronome", "メトロノーム", on: s.metro) { s.toggleMetro() }
            Spacer(minLength: 2)
            VStack(spacing: 2) {
                Text(position)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced)).monospacedDigit()
                Text(String(format: "%d:%04.1f", Int(sec / 60), sec.truncatingRemainder(dividingBy: 60)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            .frame(minWidth: 72).lineLimit(1)
            Button { sheet = .bpm } label: {
                HStack(spacing: 3) { Text("\(Int(s.project.bpm))").font(.system(size: 14, design: .monospaced)); Text("BPM").font(.system(size: 9)).foregroundStyle(Theme.dim) }
            }.buttonStyle(BarButton()).accessibilityLabel("テンポ")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
    private func icon(_ name: String, _ label: String, on: Bool = false, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Theme.onAccent : (tint ?? Theme.fg)) }
            .buttonStyle(BarButton(on: on, tint: tint)).accessibilityLabel(label)
    }
}

struct SheetView: View {
    @Environment(Store.self) private var store
    var kind: SheetKind
    @Binding var sheet: SheetKind?
    @State private var projects: [Project] = []
    @State private var naming: String?           // "rename" or "new"
    @State private var text = ""
    @State private var exportURL: URL?
    @State private var exportFailed = false
    @State private var taps: [Date] = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { sheet = nil } } }
        }
    }
    private var title: String {
        switch kind {
        case .menu: return store.project.name
        case .projects: return "保存した曲"
        case .settings: return "設定"
        case .help: return "使い方"
        case .bpm: return "テンポ"
        case .addTrack: return "トラックを追加"
        case .export: return "WAVで書き出す"
        }
    }

    @ViewBuilder private var content: some View {
        let s = store
        switch kind {
        case .menu:
            List {
                Button("曲名を変更") { text = s.project.name; naming = "rename" }
                Button("新しい曲を作る") { text = "新しい曲"; naming = "new" }
                Button("保存した曲を開く") { sheet = .projects }
                Button("デモ曲を開く") { s.load(Project.demo()); s.save(); sheet = nil }
                Button("WAVで書き出す") { sheet = .export }
                Button("設定") { sheet = .settings }
                Button("使い方") { sheet = .help }
            }
            .alert(naming == "new" ? "新しい曲の名前" : "曲名", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("名前", text: $text)
                Button("OK") {
                    let v = text.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { if naming == "new" { s.newProject(name: v); sheet = nil } else { s.project.name = v; s.commit() } }
                    naming = nil
                }
                Button("キャンセル", role: .cancel) { naming = nil }
            }
        case .projects:
            List {
                if projects.isEmpty { Text("この端末に保存された曲はまだありません。編集内容は自動で保存されます。").foregroundStyle(.secondary) }
                ForEach(projects) { p in
                    Button {
                        if p.id != s.project.id { s.load(p) }
                        sheet = nil
                    } label: {
                        VStack(alignment: .leading) {
                            Text(p.name + (p.id == s.project.id ? "（編集中）" : ""))
                            Text(p.saved.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { if p.id != s.project.id { Button("削除", role: .destructive) { s.deleteProject(p); projects.removeAll { $0.id == p.id } } } }
                }
            }
            .onAppear { projects = Store.allProjects() }
        case .settings:
            Form {
                Toggle("録音前に1小節のカウントを入れる", isOn: Binding(get: { s.countIn }, set: { s.countIn = $0; s.saveSettings() }))
                Toggle("鍵盤・パッドの録音をグリッドに揃える", isOn: Binding(get: { s.quantRec }, set: { s.quantRec = $0; s.saveSettings() }))
            }
        case .help:
            List {
                Text("上段：▶ 再生／停止、● 録音（選択中のトラックへ）、ループ、メトロノーム。ルーラーをタップすると再生位置が移動し、ループの両端はドラッグで動かせます。")
                Text("タイムライン：クリップをタップで選択、選択中のクリップをドラッグで移動、右端ドラッグで長さ変更、ダブルタップでエディタを開きます。2本指のピンチで拡大縮小。")
                Text("エディタ：空きマスをタップでノート追加、ドラッグで移動、右端で長さ変更、ダブルタップで削除、長押ししてドラッグで範囲選択。")
                Text("演奏：鍵盤やパッドを弾きながら ● で録音できます。オーディオトラックではマイク録音か音声ファイルの読み込みができます。")
                Text("曲は編集のたびにこの端末へ自動保存されます。完成したらメニューの「WAVで書き出す」で書き出せます。")
            }
        case .bpm:
            VStack(spacing: 16) {
                Text("\(Int(s.project.bpm))").font(.system(size: 54, weight: .semibold, design: .monospaced))
                Slider(value: Binding(get: { s.project.bpm }, set: { s.setBpm($0) }), in: 40...240, step: 1).tint(Theme.accent).accessibilityLabel("テンポ")
                HStack(spacing: 8) {
                    Button("−5") { s.setBpm(s.project.bpm - 5) }; Button("−1") { s.setBpm(s.project.bpm - 1) }
                    Button("＋1") { s.setBpm(s.project.bpm + 1) }; Button("＋5") { s.setBpm(s.project.bpm + 5) }
                    Button("タップ") {
                        let now = Date(); taps = taps.filter { now.timeIntervalSince($0) < 2.5 } + [now]
                        if taps.count > 1 { s.setBpm(60 / (now.timeIntervalSince(taps[0]) / Double(taps.count - 1))) }
                    }
                }.buttonStyle(BarButton())
                Spacer()
            }
            .padding(20)
            .onDisappear { s.commit() }
        case .addTrack:
            List {
                Button { s.addTrack(.synth); sheet = nil } label: { row("シンセ", "鍵盤で弾く・ピアノロールで打ち込む") }
                Button { s.addTrack(.drums); sheet = nil } label: { row("ドラム", "12パーツのドラムキット") }
                Button { s.addTrack(.audio); sheet = nil } label: { row("オーディオ", "マイク録音・音声ファイル") }
            }
        case .export:
            VStack(spacing: 16) {
                if let url = exportURL {
                    Text("44.1kHz / 16bit ステレオで書き出しました。").foregroundStyle(.secondary)
                    ShareLink(item: url) { Label("保存・共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                } else if exportFailed {
                    Text(s.project.endBeat <= 0 ? "書き出す内容がありません。" : "書き出しに失敗しました。").foregroundStyle(.secondary)
                } else {
                    ProgressView("ミックスを書き出しています…")
                }
                Spacer()
            }
            .padding(20)
            .task {
                guard s.project.endBeat > 0 else { exportFailed = true; return }
                if let u = await s.exportWav() { exportURL = u } else { exportFailed = true }
            }
        }
    }
    private func row(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(a).font(.headline); Text(b).font(.subheadline).foregroundStyle(.secondary) }
    }
}
