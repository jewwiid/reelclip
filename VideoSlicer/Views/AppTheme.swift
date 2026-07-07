import SwiftUI

enum AppPalette {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let surface = Color(red: 0.093, green: 0.098, blue: 0.109)
    static let raisedSurface = Color(red: 0.128, green: 0.134, blue: 0.148)
    static let controlSurface = Color(red: 0.155, green: 0.162, blue: 0.178)
    static let disabledSurface = Color(red: 0.19, green: 0.195, blue: 0.207).opacity(0.58)
    static let mediaWell = Color(red: 0.033, green: 0.036, blue: 0.043)
    static let primaryText = Color(red: 0.94, green: 0.945, blue: 0.93)
    static let secondaryText = Color(red: 0.65, green: 0.67, blue: 0.67)
    static let mutedText = Color(red: 0.43, green: 0.45, blue: 0.45)
    static let accent = Color(red: 0.77, green: 0.94, blue: 0.20)
    static let success = Color(red: 0.33, green: 0.78, blue: 0.47)
    static let danger = Color(red: 0.91, green: 0.31, blue: 0.31)
    static let hairline = Color.white.opacity(0.08)
    static let timelineBlock = Color.white.opacity(0.14)
}

extension CutMode {
    var symbolName: String {
        switch self {
        case .fixed:
            return "scissors"
        case .highlight:
            return "sparkles.tv"
        }
    }

    var shortTitle: String {
        switch self {
        case .fixed:
            return "Fixed"
        case .highlight:
            return "Highlight"
        }
    }
}

extension View {
    func premiumSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
    }
}