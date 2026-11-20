import SwiftUI

func rollRows(_ kind: TrackKind) -> [Int] {
    kind == .drums ? drumKit.map { $0.pitch }.reversed() : Array((24...108).reversed())
}
func rollRowHeight(_ kind: TrackKind, _ h: CGFloat) -> CGFloat {
    kind == .drums ? max(24, min(34, (h / CGFloat(drumKit.count)).rounded(.down))) : 18
}

/// Note editor for the selected clip (piano roll, or a drum grid on drum tracks).
struct PianoRollView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let s = store
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("グリッド").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Picker("グリッド", selection: Binding(get: { s.grid }, set: { s.grid = $0 })) {
                        Text("1/4").tag(1.0); Text("1/8").tag(0.5); Text("1/16").tag(0.25); Text("1/32").tag(0.125)
                        Text("1/8T").tag(1.0 / 3); Text("1/16T").tag(1.0 / 6)
                    }.pickerStyle(.menu).tint(Theme.fg)
                    Button("クオンタイズ") { s.quantize() }
                    Button("全選択") { s.selectAllNotes() }
                    Button("ノート削除") { s.deleteNotes() }.buttonStyle(BarButton(tint: Theme.rec))
                    Text("強さ").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { s.newVel }, set: { s.setVelocity($0) }), in: 0.1...1) { editing in if !editing { s.commit() } }
                        .frame(width: 100).tint(Theme.accent)
                    Button("−") { s.zoomRoll(1 / 1.4) }.accessibilityLabel("縮小")
                    Button("＋") { s.zoomRoll(1.4) }.accessibilityLabel("拡大")
                }
                .buttonStyle(BarButton()).padding(.horizontal, 8).padding(.vertical, 5)
            }
            ZStack {
                Canvas { ctx, size in draw(ctx, size) }
                TouchSurface(handlers: handlers())
            }
            .readSize { s.rollSize = $0; Self.prepare(s) }
            .clipped()
        }
        .onChange(of: s.selClip, initial: true) { _, _ in Self.prepare(s) }
    }

    /// Centers the view on the clip's notes the first time a clip is shown, and keeps scroll in range.
    private static func prepare(_ s: Store) {
        guard let (ti, ci) = s.selClipPath, s.rollSize.height > 10 else { return }
        let tr = s.project.tracks[ti], cl = tr.clips[ci], rows = rollRows(tr.kind), rh = rollRowHeight(tr.kind, s.rollSize.height)
        if s.rollClip != cl.id {
            s.rollClip = cl.id; s.rollX = 0
            if tr.kind == .drums { s.rollY = 100000 }
            else {
                let ps = cl.notes.map { $0.p }
                let mid = ps.isEmpty ? 62 : (ps.min()! + ps.max()!) / 2
                s.rollY = (CGFloat(rows.firstIndex(of: mid) ?? 46) + 0.5) * rh - s.rollSize.height / 2
            }
        }
        s.rollY = min(max(0, s.rollY), max(0, CGFloat(rows.count) * rh - s.rollSize.height)); s.rollX = max(0, s.rollX)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let (ti, ci) = store.selClipPath else { return }
        let tr = store.project.tracks[ti], cl = tr.clips[ci]
        if cl.isAudio { return }
        let rows = rollRows(tr.kind), drums = tr.kind == .drums
        let w = size.width, h = size.height, KW = Store.keyW, RH = rollRowHeight(tr.kind, h), ppb = store.rollPPB, sx = store.rollX, sy = store.rollY
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.lane))
        let r0 = max(0, Int(sy / RH))
        var dark = Path(), octave = Path()
        var r = r0
        while r < rows.count && CGFloat(r) * RH - sy < h {
            let y = CGFloat(r) * RH - sy, p = rows[r]
            if drums ? r % 2 == 1 : isBlackKey(p) { dark.addRect(CGRect(x: KW, y: y, width: w, height: RH)) }
            if !drums && p % 12 == 0 { octave.addRect(CGRect(x: KW, y: y + RH - 1, width: w, height: 1)) }
            r += 1
        }
        ctx.fill(dark, with: .color(Theme.grid.opacity(0.75))); ctx.fill(octave, with: .color(Theme.gridBar))
        let g = store.grid, st = CGFloat(g) * ppb >= 7 ? g : 1.0
        var fine = Path(), beatLines = Path(), barLines = Path()
        var k = Int(Double(sx / ppb) / st)
        while CGFloat(Double(k) * st) * ppb - sx < w {
            let b = Double(k) * st, x = (KW + CGFloat(b) * ppb - sx).rounded() + 0.5
            if x >= KW {
                let onBeat = abs(b - b.rounded()) < 1e-6, bar = onBeat && Int(b.rounded()) % 4 == 0
                if bar { barLines.addRect(CGRect(x: x - 0.75, y: 0, width: 1.5, height: h)) }
                else if onBeat { beatLines.addRect(CGRect(x: x - 0.5, y: 0, width: 1, height: h)) }
                else { fine.addRect(CGRect(x: x - 0.5, y: 0, width: 1, height: h)) }
            }
            k += 1
        }
        ctx.fill(fine, with: .color(Theme.grid.opacity(0.6))); ctx.fill(beatLines, with: .color(Theme.grid)); ctx.fill(barLines, with: .color(Theme.gridBar))
        let xe = KW + CGFloat(cl.len) * ppb - sx
        if xe < w { ctx.fill(Path(CGRect(x: max(KW, xe), y: 0, width: w, height: h)), with: .color(Theme.bg.opacity(0.72))) }
        let color = Theme.track(tr.color)
        for n in cl.notes {
            guard let row = rows.firstIndex(of: n.p) else { continue }
            let x = KW + CGFloat(n.t) * ppb - sx, y = CGFloat(row) * RH - sy, nw = max(4, CGFloat(n.d) * ppb - 1)
            if x > w || x + nw < KW || y > h || y + RH < 0 { continue }
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y + 1, width: nw, height: RH - 2), cornerRadius: 3), with: .color(color.opacity(0.45 + n.v * 0.55)))
            if store.selNotes.contains(n.id) {
                ctx.stroke(Path(roundedRect: CGRect(x: x + 1, y: y + 2, width: nw - 2, height: RH - 4), cornerRadius: 2), with: .color(Theme.sel), lineWidth: 2)
            }
        }
        if let box = store.rollBox {
            ctx.fill(Path(box), with: .color(Theme.accent.opacity(0.18))); ctx.stroke(Path(box), with: .color(Theme.accent), lineWidth: 1)
        }
        let px = KW + CGFloat(store.pos - cl.start) * ppb - sx
        if px >= KW && px <= w { ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.accent)) }
        // key column
        r = r0
        while r < rows.count && CGFloat(r) * RH - sy < h {
            let y = CGFloat(r) * RH - sy, p = rows[r]
            if drums {
                ctx.fill(Path(CGRect(x: 0, y: y, width: KW, height: RH)), with: .color(Theme.panel))
                let name = drumKit.first { $0.pitch == p }?.name ?? ""
                ctx.draw(Text(name).font(.system(size: 10)).foregroundColor(Theme.fg), at: CGPoint(x: 4, y: y + RH / 2), anchor: .leading)
            } else {
                ctx.fill(Path(CGRect(x: 0, y: y, width: KW, height: RH)), with: .color(isBlackKey(p) ? Theme.keyB : Theme.keyW))
                if p % 12 == 0 { ctx.draw(Text("C\(p / 12 - 1)").font(.system(size: 10)).foregroundColor(Color(UIColor(hex: 0x555B6B))), at: CGPoint(x: 24, y: y + RH / 2), anchor: .leading) }
            }
            ctx.fill(Path(CGRect(x: 0, y: y + RH - 1, width: KW, height: 1)), with: .color(Theme.line))
            r += 1
        }
        ctx.fill(Path(CGRect(x: KW - 1, y: 0, width: 1, height: h)), with: .color(Theme.line))
        var bar = Int(Double(sx / ppb) / 4)
        while CGFloat(bar * 4) * ppb - sx < w {
            let x = KW + CGFloat(bar * 4) * ppb - sx
            if x >= KW { ctx.draw(Text("\(Int(cl.start / 4) + bar + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim), at: CGPoint(x: x + 4, y: 7), anchor: .leading) }
            bar += 1
        }
    }

    // MARK: touch

    private struct Hit { var ti: Int; var ci: Int; var rows: [Int]; var rh: CGFloat; var pitch: Int?; var t: Double; var note: Note? }
    private static func hit(_ s: Store, _ pt: CGPoint) -> Hit? {
        guard let (ti, ci) = s.selClipPath else { return nil }
        let tr = s.project.tracks[ti], cl = tr.clips[ci]
        if cl.isAudio { return nil }
        let rows = rollRows(tr.kind), rh = rollRowHeight(tr.kind, s.rollSize.height)
        let r = Int(((pt.y + s.rollY) / rh).rounded(.down)), p: Int? = r >= 0 && r < rows.count ? rows[r] : nil
        let t = Double((pt.x - Store.keyW + s.rollX) / s.rollPPB), pad = Double(3 / s.rollPPB)
        let note = cl.notes.last { $0.p == p && t >= $0.t - pad && t <= $0.t + max($0.d, pad * 2) + pad }
        return Hit(ti: ti, ci: ci, rows: rows, rh: rh, pitch: p, t: t, note: note)
    }

    private func handlers() -> TouchHandlers {
        let s = store
        var h = TouchHandlers()
        h.start = { pt in
            guard let hit = Self.hit(s, pt), pt.x >= Store.keyW else { return nil }
            let trackID = s.project.tracks[hit.ti].id, drums = s.project.tracks[hit.ti].kind == .drums
            if let n = hit.note {
                let g = s.grid
                if !s.selNotes.contains(n.id) { s.selNotes = [n.id]; s.newVel = n.v }
                s.audition(trackID, n.p, n.v)
                let nx1 = Store.keyW + CGFloat(n.t + n.d) * s.rollPPB - s.rollX
                let edge = !drums && pt.x > nx1 - min(16, CGFloat(n.d) * s.rollPPB * 0.4)
                let orig: [(id: UUID, t: Double, d: Double, row: Int)] = s.project.tracks[hit.ti].clips[hit.ci].notes
                    .filter { s.selNotes.contains($0.id) }.map { (id: $0.id, t: $0.t, d: $0.d, row: hit.rows.firstIndex(of: $0.p) ?? 0) }
                var changed = false, lastP = n.p
                return DragHandler(move: { _, d in
                    guard let (ti, ci) = s.selClipPath else { return }
                    changed = true
                    var notes = s.project.tracks[ti].clips[ci].notes
                    if edge {
                        for o in orig { if let i = notes.firstIndex(where: { $0.id == o.id }) { notes[i].d = max(g, ((o.d + Double(d.x / s.rollPPB)) / g).rounded() * g) } }
                    } else {
                        let minT = orig.map { $0.t }.min() ?? 0, minR = orig.map { $0.row }.min() ?? 0, maxR = orig.map { $0.row }.max() ?? 0
                        let dt = max((Double(d.x / s.rollPPB) / g).rounded() * g, -minT)
                        let dr = min(max(Int((d.y / hit.rh).rounded()), -minR), hit.rows.count - 1 - maxR)
                        for o in orig { if let i = notes.firstIndex(where: { $0.id == o.id }) { notes[i].t = o.t + dt; notes[i].p = hit.rows[o.row + dr] } }
                        if let cur = notes.first(where: { $0.id == n.id }), cur.p != lastP { lastP = cur.p; s.audition(trackID, cur.p, cur.v) }
                    }
                    s.project.tracks[ti].clips[ci].notes = notes
                }, end: { _ in
                    guard changed, let (ti, ci) = s.selClipPath else { return }
                    if !drums, let cur = s.project.tracks[ti].clips[ci].notes.first(where: { $0.id == n.id }) { s.lastLen = cur.d }
                    s.growClip(ti, ci); s.commit()
                })
            }
            let ox = s.rollX, oy = s.rollY
            return DragHandler(move: { _, d in s.rollX = ox - d.x; s.rollY = oy - d.y; Self.prepare(s) })
        }
        h.tap = { pt in
            guard let hit = Self.hit(s, pt), let p = hit.pitch else { return }
            let tr = s.project.tracks[hit.ti]
            if pt.x < Store.keyW { s.audition(tr.id, p); return }
            if hit.note != nil { return }
            let g = s.grid, t = (hit.t / g + 1e-6).rounded(.down) * g
            guard t >= 0 else { return }
            let n = Note(p: p, t: t, d: tr.kind == .drums ? g : s.lastLen, v: s.newVel)
            s.project.tracks[hit.ti].clips[hit.ci].notes.append(n); s.selNotes = [n.id]
            s.growClip(hit.ti, hit.ci); s.audition(tr.id, p, n.v); s.commit()
        }
        h.doubleTap = { pt in
            guard let hit = Self.hit(s, pt), let n = hit.note, pt.x >= Store.keyW else { return }
            s.project.tracks[hit.ti].clips[hit.ci].notes.removeAll { $0.id == n.id }; s.selNotes.remove(n.id); s.commit()
        }
        h.longPress = { pt in
            guard let hit = Self.hit(s, pt), hit.note == nil, pt.x >= Store.keyW else { return nil }
            s.selNotes = []; s.rollBox = CGRect(origin: pt, size: .zero)
            return DragHandler(move: { p, _ in
                let box = CGRect(x: min(pt.x, p.x), y: min(pt.y, p.y), width: abs(p.x - pt.x), height: abs(p.y - pt.y))
                s.rollBox = box
                guard let (ti, ci) = s.selClipPath else { return }
                s.selNotes = Set(s.project.tracks[ti].clips[ci].notes.filter { n in
                    let nx = Store.keyW + CGFloat(n.t) * s.rollPPB - s.rollX, ny = CGFloat(hit.rows.firstIndex(of: n.p) ?? -9) * hit.rh - s.rollY
                    return box.intersects(CGRect(x: nx, y: ny, width: CGFloat(n.d) * s.rollPPB, height: hit.rh))
                }.map { $0.id })
            }, end: { _ in s.rollBox = nil })
        }
        h.pinch = { scale, c in s.zoomRoll(scale, at: c.x) }
        return h
    }
}
