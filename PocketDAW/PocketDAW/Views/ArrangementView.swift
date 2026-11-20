import SwiftUI

/// Track headers plus the clip timeline.
struct ArrangementView: View {
    @Environment(Store.self) private var store
    var headWidth: CGFloat

    var body: some View {
        let s = store
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("TRACKS").font(.system(size: 11)).kerning(0.7).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    .frame(height: Store.rulerH).background(Theme.panel)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                GeometryReader { _ in
                    VStack(spacing: 0) { ForEach(store.project.tracks) { TrackHead(track: $0) } }.offset(y: -store.arrY)
                }.clipped()
            }
            .frame(width: headWidth).background(Theme.panel)
            .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
            ZStack {
                Canvas { ctx, size in draw(ctx, size) }
                TouchSurface(handlers: handlers())
            }
            .readSize { s.arrSize = $0; Self.clampScroll(s) }
            .clipped()
        }
    }

    private static func clampScroll(_ s: Store) {
        let maxY = max(0, CGFloat(s.project.tracks.count) * Store.trackH - (s.arrSize.height - Store.rulerH))
        s.arrY = min(max(0, s.arrY), maxY); s.arrX = max(0, s.arrX)
    }

    // MARK: drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let p = store.project, ppb = store.arrPPB, sx = store.arrX, sy = store.arrY
        let RUL = Store.rulerH, TH = Store.trackH, w = size.width, h = size.height, spb = 60 / p.bpm
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.bg))
        for (i, t) in p.tracks.enumerated() {
            let y = RUL + CGFloat(i) * TH - sy
            if y > h || y + TH < RUL { continue }
            ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: TH - 1)), with: .color(t.id == store.selTrack ? Theme.lane2 : Theme.lane))
        }
        var beats = Path(), bars = Path()
        let b0 = Int(sx / ppb)
        var b = b0
        while CGFloat(b) * ppb - sx < w {
            let bar = b % 4 == 0
            if (bar || ppb >= 12) && !(ppb < 4.5 && b % 16 != 0) {
                let x = (CGFloat(b) * ppb - sx).rounded() + 0.5
                if bar { bars.move(to: CGPoint(x: x, y: RUL)); bars.addLine(to: CGPoint(x: x, y: h)) }
                else { beats.move(to: CGPoint(x: x, y: RUL)); beats.addLine(to: CGPoint(x: x, y: h)) }
            }
            b += 1
        }
        ctx.stroke(beats, with: .color(Theme.grid), lineWidth: 1)
        ctx.stroke(bars, with: .color(Theme.gridBar), lineWidth: 1)

        for (i, t) in p.tracks.enumerated() {
            let y = RUL + CGFloat(i) * TH - sy + 3, ch = TH - 7
            if y > h || y + ch < RUL { continue }
            let color = Theme.track(t.color)
            for cl in t.clips {
                let x = CGFloat(cl.start) * ppb - sx, cw = max(4, CGFloat(cl.lengthBeats(bpm: p.bpm)) * ppb - 1)
                if x > w || x + cw < 0 { continue }
                let sel = cl.id == store.selClip
                let box = Path(roundedRect: CGRect(x: x, y: y, width: cw, height: ch), cornerRadius: 5)
                ctx.fill(box, with: .color(color.opacity(sel ? 1 : 0.78)))
                var c = ctx
                c.clip(to: box)
                c.fill(Path(CGRect(x: x, y: y, width: cw, height: 15)), with: .color(.black.opacity(0.28)))
                c.draw(Text(cl.name ?? t.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: x + 5, y: y + 8), anchor: .leading)
                var marks = Path()
                if let id = cl.audioID {
                    if let pk = store.audio[id]?.peaks {
                        let mid = y + 15 + (ch - 15) / 2, hh = (ch - 19) / 2
                        var px = max(0, x.rounded(.down))
                        let endX = min(w, x + cw)
                        while px < endX {
                            let idx = Int((cl.off + Double((px - x) / ppb) * spb) * 100)
                            let a = idx >= 0 && idx < pk.count ? pk[idx] : 0
                            let v = max(1, min(1, CGFloat(a) * CGFloat(cl.gain)) * hh)
                            marks.addRect(CGRect(x: px, y: mid - v, width: 1.4, height: v * 2))
                            px += 2
                        }
                    }
                } else if !cl.notes.isEmpty {
                    var lo = 127, hi = 0
                    for n in cl.notes { lo = min(lo, n.p); hi = max(hi, n.p) }
                    let span = CGFloat(max(6, hi - lo)), bh = ch - 21
                    for n in cl.notes where n.t < cl.len {
                        marks.addRect(CGRect(x: x + CGFloat(n.t) * ppb, y: y + 17 + bh - CGFloat(n.p - lo) / span * bh,
                                             width: max(2, CGFloat(min(n.d, cl.len - n.t)) * ppb - 1), height: 2.5))
                    }
                }
                c.fill(marks, with: .color(.white.opacity(0.92)))
                if sel {
                    ctx.stroke(Path(roundedRect: CGRect(x: x + 1, y: y + 1, width: cw - 2, height: ch - 2), cornerRadius: 4), with: .color(Theme.sel), lineWidth: 2)
                    ctx.fill(Path(CGRect(x: x + cw - 6, y: y + ch / 2 - 8, width: 2.5, height: 16)), with: .color(Theme.sel))
                }
            }
        }
        if store.recording, let ti = store.selTrackIndex {
            // live recording region is drawn on the selected track from the nearest bar
            let y = RUL + CGFloat(ti) * TH - sy + 3
            let from = CGFloat(max(0, store.pos - 0.001))
            ctx.fill(Path(CGRect(x: from * ppb - sx - 2, y: y, width: 4, height: TH - 7)), with: .color(Theme.rec.opacity(0.7)))
        }
        // ruler
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: RUL)), with: .color(Theme.panel))
        let L = p.loop
        if L.on {
            let x0 = CGFloat(L.start) * ppb - sx, x1 = CGFloat(L.end) * ppb - sx
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: RUL)), with: .color(Theme.accent.opacity(0.3)))
            ctx.fill(Path(CGRect(x: x0, y: 0, width: 3, height: RUL)), with: .color(Theme.accent))
            ctx.fill(Path(CGRect(x: x1 - 3, y: 0, width: 3, height: RUL)), with: .color(Theme.accent))
        }
        let barPx = ppb * 4, every = barPx >= 34 ? 1 : (barPx >= 17 ? 2 : (barPx >= 9 ? 4 : 8))
        var bar = b0 / 4
        while CGFloat(bar) * barPx - sx < w {
            if bar % every == 0 {
                ctx.draw(Text("\(bar + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim), at: CGPoint(x: CGFloat(bar) * barPx - sx + 4, y: RUL / 2), anchor: .leading)
            }
            bar += 1
        }
        ctx.fill(Path(CGRect(x: 0, y: RUL - 1, width: w, height: 1)), with: .color(Theme.line))
        let px = (CGFloat(store.pos) * ppb - sx).rounded() + 0.5
        if px >= 0 && px <= w {
            ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.accent))
            var tri = Path(); tri.move(to: CGPoint(x: px - 6, y: 0)); tri.addLine(to: CGPoint(x: px + 6, y: 0)); tri.addLine(to: CGPoint(x: px, y: 9)); tri.closeSubpath()
            ctx.fill(tri, with: .color(Theme.accent))
        }
    }

    // MARK: touch

    private struct Hit { var ti: Int; var ci: Int?; var edge = false }
    private static func hit(_ s: Store, _ pt: CGPoint) -> Hit? {
        guard pt.y >= Store.rulerH else { return nil }
        let i = Int((pt.y - Store.rulerH + s.arrY) / Store.trackH)
        guard i >= 0, i < s.project.tracks.count else { return nil }
        let clips = s.project.tracks[i].clips
        for k in clips.indices.reversed() {
            let x0 = CGFloat(clips[k].start) * s.arrPPB - s.arrX, x1 = x0 + CGFloat(clips[k].lengthBeats(bpm: s.project.bpm)) * s.arrPPB
            if pt.x >= x0 - 2 && pt.x <= x1 + 4 { return Hit(ti: i, ci: k, edge: pt.x > x1 - min(18, (x1 - x0) * 0.35)) }
        }
        return Hit(ti: i, ci: nil)
    }

    private func handlers() -> TouchHandlers {
        let s = store
        var h = TouchHandlers()
        h.start = { pt in
            let sn = s.snapA
            let beat: (CGFloat) -> Double = { x in max(0, (Double((x + s.arrX) / s.arrPPB) / sn).rounded() * sn) }
            if pt.y < Store.rulerH {
                if s.project.loop.on {
                    for isEnd in [true, false] {
                        let v = isEnd ? s.project.loop.end : s.project.loop.start
                        if abs(CGFloat(v) * s.arrPPB - s.arrX - pt.x) < 16 {
                            return DragHandler(move: { p, _ in
                                let b = beat(p.x)
                                if isEnd { s.project.loop.end = max(b, s.project.loop.start + sn) } else { s.project.loop.start = min(b, s.project.loop.end - sn) }
                                s.sync()
                            }, end: { tap in if !tap { s.commit() } })
                        }
                    }
                }
                return DragHandler(move: { p, _ in s.setPos(beat(p.x)) }, end: { tap in if tap { s.setPos(beat(pt.x)) } })
            }
            if let hit = Self.hit(s, pt), let ci = hit.ci, s.project.tracks[hit.ti].clips[ci].id == s.selClip {
                let orig = s.project.tracks[hit.ti].clips[ci]
                var changed = false
                if hit.edge {
                    return DragHandler(move: { _, d in
                        guard let (ti, ci) = s.selClipPath else { return }
                        changed = true
                        if let id = orig.audioID {
                            let total = s.audio[id]?.duration ?? orig.dur
                            s.project.tracks[ti].clips[ci].dur = min(max(0.05, orig.dur + Double(d.x / s.arrPPB) * 60 / s.project.bpm), total - orig.off)
                        } else {
                            s.project.tracks[ti].clips[ci].len = max(sn, ((orig.len + Double(d.x / s.arrPPB)) / sn).rounded() * sn)
                        }
                        s.sync()
                    }, end: { _ in if changed { s.commit() } })
                }
                return DragHandler(move: { p, d in
                    guard var (ti, ci) = s.selClipPath else { return }
                    changed = true
                    let t2 = Int((p.y - Store.rulerH + s.arrY) / Store.trackH)
                    if t2 != ti, t2 >= 0, t2 < s.project.tracks.count, (s.project.tracks[t2].kind == .audio) == (s.project.tracks[ti].kind == .audio) {
                        let c = s.project.tracks[ti].clips.remove(at: ci)
                        s.project.tracks[t2].clips.append(c); ti = t2; ci = s.project.tracks[t2].clips.count - 1
                        s.selTrack = s.project.tracks[t2].id
                    }
                    s.project.tracks[ti].clips[ci].start = max(0, ((orig.start + Double(d.x / s.arrPPB)) / sn).rounded() * sn)
                    s.sync()
                }, end: { _ in if changed { s.commit() } })
            }
            let ox = s.arrX, oy = s.arrY
            return DragHandler(move: { _, d in s.arrX = ox - d.x; s.arrY = oy - d.y; Self.clampScroll(s) })
        }
        h.tap = { pt in
            guard pt.y >= Store.rulerH else { return }
            guard let hit = Self.hit(s, pt) else { s.selClip = nil; return }
            s.selTrack = s.project.tracks[hit.ti].id
            s.selClip = hit.ci.map { s.project.tracks[hit.ti].clips[$0].id }
            s.selNotes = []
        }
        h.doubleTap = { pt in
            guard let hit = Self.hit(s, pt) else { return }
            s.selTrack = s.project.tracks[hit.ti].id
            if let ci = hit.ci { s.selClip = s.project.tracks[hit.ti].clips[ci].id; s.openPanel(.edit) }
            else if s.project.tracks[hit.ti].kind != .audio { s.addClip(at: (Double((pt.x + s.arrX) / s.arrPPB) / 4).rounded(.down) * 4) }
        }
        h.pinch = { scale, c in s.zoomArr(scale, at: c.x) }
        return h
    }
}

private struct TrackHead: View {
    @Environment(Store.self) private var store
    var track: Track
    var body: some View {
        let kind = track.kind == .synth ? "SYN" : (track.kind == .drums ? "DRM" : "AUD")
        VStack(alignment: .leading, spacing: 4) {
            Text(track.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 4) {
                flag("M", track.mute, Color(UIColor(hex: 0x6B7386))) { $0.mute.toggle() }
                flag("S", track.solo, Theme.accent) { $0.solo.toggle() }
                Spacer(minLength: 0)
                Text(kind).font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: Store.trackH - 1)
        .background(track.id == store.selTrack ? Theme.raise : Theme.panel)
        .overlay(alignment: .leading) { Theme.track(track.color).frame(width: 4) }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1).offset(y: 1) }
        .frame(height: Store.trackH, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selTrack = track.id
            if !track.clips.contains(where: { $0.id == store.selClip }) { store.selClip = nil }
        }
    }
    private func flag(_ label: String, _ on: Bool, _ tint: Color, _ change: @escaping (inout Track) -> Void) -> some View {
        Button {
            if let i = store.trackIndex(track.id) { change(&store.project.tracks[i]); store.commit() }
        } label: {
            Text(label).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 24)
                .foregroundStyle(on ? Color.white : Theme.fg)
                .background(on ? tint : Theme.raise, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: on ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label == "M" ? "ミュート" : "ソロ")
    }
}
