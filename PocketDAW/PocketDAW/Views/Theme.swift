import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

enum Theme {
    static let uiBg = UIColor.dyn(0xEEF0F4, 0x14161C), uiPanel = UIColor.dyn(0xFFFFFF, 0x1C1F27), uiRaise = UIColor.dyn(0xE6E9F0, 0x272B36)
    static let uiLine = UIColor.dyn(0xCDD2DE, 0x353A4A), uiFg = UIColor.dyn(0x1B1E27, 0xE8EAF0), uiDim = UIColor.dyn(0x596074, 0x969DB0)
    static let uiAccent = UIColor.dyn(0xC97A00, 0xF5A524), uiKeyW = UIColor.dyn(0xFFFFFF, 0xE6E8EE), uiKeyB = UIColor.dyn(0x2B2E38, 0x23262F)

    static let bg = Color(uiBg), panel = Color(uiPanel), raise = Color(uiRaise), line = Color(uiLine), fg = Color(uiFg), dim = Color(uiDim)
    static let accent = Color(uiAccent), keyW = Color(uiKeyW), keyB = Color(uiKeyB)
    static let onAccent = Color(UIColor.dyn(0xFFFFFF, 0x1A1405))
    static let rec = Color(UIColor.dyn(0xD6283A, 0xEF4D5A))
    static let lane = Color(UIColor.dyn(0xF7F8FA, 0x181B22)), lane2 = Color(UIColor.dyn(0xECEFF5, 0x1E222B))
    static let grid = Color(UIColor.dyn(0xE3E6EE, 0x242833)), gridBar = Color(UIColor.dyn(0xBCC2D1, 0x3D4356))
    static let sel = Color(UIColor.dyn(0x10131A, 0xFFFFFF))
    static let trackColors: [Color] = ([0xE5484D, 0xF76B15, 0xE2A600, 0x46A758, 0x12A594, 0x3E8BE0, 0x8E5CD9, 0xE93D82] as [UInt32]).map { Color(UIColor(hex: $0)) }
    static func track(_ i: Int) -> Color { trackColors[((i % trackColors.count) + trackColors.count) % trackColors.count] }
}

/// Compact bordered button used across the toolbars.
struct BarButton: ButtonStyle {
    var on = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 40, minHeight: 38)
            .foregroundStyle(on ? Theme.onAccent : (tint ?? Theme.fg))
            .background(on ? (tint ?? Theme.accent) : Theme.raise, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: on ? 0 : 1))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

extension View {
    /// Reports this view's size.
    func readSize(_ f: @escaping (CGSize) -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear.onAppear { f(g.size) }.onChange(of: g.size) { _, n in f(n) }
        })
    }
}

let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
func isBlackKey(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) }
