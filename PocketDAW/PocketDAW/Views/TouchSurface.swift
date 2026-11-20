import SwiftUI
import UIKit

/// What a touch that began on the surface does while it moves.
struct DragHandler {
    var move: (_ point: CGPoint, _ delta: CGPoint) -> Void = { _, _ in }
    var end: (_ wasTap: Bool) -> Void = { _ in }
}

struct TouchHandlers {
    var start: (CGPoint) -> DragHandler? = { _ in nil }
    var tap: (CGPoint) -> Void = { _ in }
    var doubleTap: (CGPoint) -> Void = { _ in }
    var longPress: ((CGPoint) -> DragHandler?)? = nil
    var pinch: (_ scale: CGFloat, _ center: CGPoint) -> Void = { _, _ in }
}

/// Transparent multi-touch layer: tap, double tap, drag, long-press drag and two-finger pinch.
struct TouchSurface: UIViewRepresentable {
    var handlers: TouchHandlers
    func makeUIView(context: Context) -> TouchView { let v = TouchView(); v.h = handlers; return v }
    func updateUIView(_ v: TouchView, context: Context) { v.h = handlers }
}

final class TouchView: UIView {
    var h = TouchHandlers()
    private var active: [UITouch] = []
    private var drag: DragHandler?
    private var startPt = CGPoint.zero
    private var moved = false, longed = false
    private var lastTap: TimeInterval = 0
    private var lastTapPt = CGPoint.zero
    private var pinchDist: CGFloat = 1
    private var longWork: DispatchWorkItem?

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }

    private func dist() -> CGFloat {
        guard active.count >= 2 else { return 1 }
        let a = active[0].location(in: self), b = active[1].location(in: self)
        return max(1, hypot(a.x - b.x, a.y - b.y))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { active.append(t) }
        if active.count == 1 {
            moved = false; longed = false; startPt = active[0].location(in: self)
            drag = h.start(startPt)
            longWork?.cancel()
            if let lp = h.longPress {
                let w = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.moved, self.active.count == 1 else { return }
                    if let d = lp(self.startPt) { self.drag = d; self.longed = true }
                }
                longWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: w)
            }
        } else if active.count == 2 {
            longWork?.cancel()
            if moved { drag?.end(false) }
            drag = nil; moved = true; pinchDist = dist()
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if active.count >= 2 {
            let d = dist(), a = active[0].location(in: self), b = active[1].location(in: self)
            h.pinch(d / pinchDist, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)); pinchDist = d
            return
        }
        guard let t = active.first else { return }
        let p = t.location(in: self)
        if !moved && hypot(p.x - startPt.x, p.y - startPt.y) > 8 { moved = true; longWork?.cancel() }
        if moved || longed { drag?.move(p, CGPoint(x: p.x - startPt.x, y: p.y - startPt.y)) }
    }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let p = touches.first?.location(in: self) ?? startPt
        active.removeAll { touches.contains($0) }
        guard active.isEmpty else { return }
        longWork?.cancel()
        if moved || longed { drag?.end(false) }
        else if !cancelled {
            drag?.end(true)
            let now = CACurrentMediaTime()
            if now - lastTap < 0.33 && hypot(p.x - lastTapPt.x, p.y - lastTapPt.y) < 24 { lastTap = 0; h.doubleTap(p) }
            else { lastTap = now; lastTapPt = p; h.tap(p) }
        }
        drag = nil
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
}

/// Piano keyboard or drum pads with real multi-touch.
struct PlaySurface: UIViewRepresentable {
    var drums: Bool
    var octave: Int
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void
    func makeUIView(context: Context) -> PlaySurfaceView { let v = PlaySurfaceView(); apply(v); return v }
    func updateUIView(_ v: PlaySurfaceView, context: Context) { apply(v) }
    private func apply(_ v: PlaySurfaceView) {
        if v.drums != drums || v.octave != octave { v.drums = drums; v.octave = octave; v.setNeedsDisplay() }
        v.onDown = onDown; v.onUp = onUp
    }
}

final class PlaySurfaceView: UIView {
    var drums = false
    var octave = 4
    var onDown: (Int) -> Void = { _ in }
    var onUp: (Int) -> Void = { _ in }
    private var held: [ObjectIdentifier: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true; contentMode = .redraw; backgroundColor = Theme.uiBg
    }
    required init?(coder: NSCoder) { fatalError() }

    private struct Key { var rect: CGRect; var pitch: Int; var black: Bool; var label: String }
    private func keys() -> [Key] {
        let w = bounds.width, h = bounds.height
        if drums {
            let cols = 4, rows = 3, gap: CGFloat = 6
            let cw = (w - gap * CGFloat(cols + 1)) / CGFloat(cols), ch = (h - gap * CGFloat(rows + 1)) / CGFloat(rows)
            return drumKit.enumerated().map { i, d in
                // kick row at the bottom
                let c = i % cols, r = rows - 1 - i / cols
                return Key(rect: CGRect(x: gap + CGFloat(c) * (cw + gap), y: gap + CGFloat(r) * (ch + gap), width: cw, height: ch), pitch: d.pitch, black: false, label: d.name)
            }
        }
        let n = max(8, min(22, Int(w / 42))), kw = w / CGFloat(n)
        var out: [Key] = [], blacks: [Key] = []
        var p = octave * 12 + 12
        for i in 0..<n {
            while isBlackKey(p) { p += 1 }
            out.append(Key(rect: CGRect(x: CGFloat(i) * kw, y: 0, width: kw, height: h), pitch: p, black: false, label: p % 12 == 0 ? "C\(p / 12 - 1)" : ""))
            if i < n - 1 && isBlackKey(p + 1) {
                blacks.append(Key(rect: CGRect(x: CGFloat(i + 1) * kw - kw * 0.3, y: 0, width: kw * 0.6, height: h * 0.58), pitch: p + 1, black: true, label: ""))
            }
            p += 1
        }
        return out + blacks
    }
    private func pitch(at pt: CGPoint) -> Int? {
        let ks = keys()
        if let b = ks.last(where: { $0.black && $0.rect.contains(pt) }) { return b.pitch }
        return ks.first(where: { !$0.black && $0.rect.contains(pt) })?.pitch
    }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let down = Set(held.values)
        for k in keys() {
            let on = down.contains(k.pitch)
            let r = drums ? k.rect : k.rect.insetBy(dx: 0.5, dy: 0)
            let path = UIBezierPath(roundedRect: r, byRoundingCorners: drums ? .allCorners : [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: drums ? 10 : 5, height: drums ? 10 : 5))
            c.setFillColor((on ? Theme.uiAccent : (drums ? Theme.uiRaise : (k.black ? Theme.uiKeyB : Theme.uiKeyW))).cgColor)
            c.addPath(path.cgPath); c.fillPath()
            c.setStrokeColor(Theme.uiLine.cgColor); c.setLineWidth(1); c.addPath(path.cgPath); c.strokePath()
            if !k.label.isEmpty {
                let attr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: drums ? 12 : 10, weight: drums ? .semibold : .regular),
                                                           .foregroundColor: drums ? Theme.uiFg : UIColor(hex: 0x555B6B)]
                let s = k.label as NSString, sz = s.size(withAttributes: attr)
                s.draw(at: CGPoint(x: k.rect.midX - sz.width / 2, y: drums ? k.rect.midY - sz.height / 2 : k.rect.maxY - sz.height - 6), withAttributes: attr)
            }
        }
    }
    private func set(_ t: UITouch, _ p: Int?) {
        let id = ObjectIdentifier(t)
        if held[id] == p { return }
        if let old = held[id] { held[id] = nil; if !held.values.contains(old) { onUp(old) } }
        if let p = p { let already = held.values.contains(p); held[id] = p; if !already { onDown(p) } }
        setNeedsDisplay()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { set(t, pitch(at: t.location(in: self))) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if !drums { for t in touches { set(t, pitch(at: t.location(in: self))) } } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { set(t, nil) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { set(t, nil) } }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) { super.traitCollectionDidChange(previous); setNeedsDisplay() }
}
