import SwiftUI

extension Color {
    init(hex: String, alpha: Double = 1.0) {
        var hexClean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexClean = hexClean.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexClean).scanHexInt64(&rgb)

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self = Color(red: r, green: g, blue: b, opacity: alpha)
    }
    
    // App Colors
    static let appLightGrey = Color(hex: "#F8F8F8")
    static let appGrey = Color(hex: "#EAEAEA")
    static let appCancelRed = Color(hex: "#FF7C7C")
    static let appRed = Color(hex: "#FF3B30")
    static let appOrange = Color(hex: "#FF9500")
    static let appPurple = Color(hex: "#8E44AD")
    static let appGreen = Color(hex: "#40C174")
    static let appYellow = Color(hex: "#F4B552")
}

// Default background gradients
struct AppGradients {
    static let mainGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.appRed,
            Color.appOrange,
            Color.appPurple
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let horizontalGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.appRed,
            Color.appOrange,
            Color.appPurple
        ]),
        startPoint: .leading,
        endPoint: .trailing
    )
}
