import SwiftUI

// SwiftUI Color Hex Initializer (cross-platform)
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
}

// App Colors (as SwiftUI Colors)
struct AppColors {
    static let lightGrey = Color(hex: "#F8F8F8")
    static let grey = Color(hex: "#EAEAEA")
    static let cancelRed = Color(hex: "#FF7C7C")
    static let red = Color(hex: "#FF3B30")
    static let orange = Color(hex: "#FF9500")
    static let purple = Color(hex: "#8E44AD")
    static let green = Color(hex: "#40C174")
    static let yellow = Color(hex: "#F4B552")
}

// SwiftUI Color equivalents (convenience statics)
extension Color {
    static let appLightGrey = AppColors.lightGrey
    static let appGrey = AppColors.grey
    static let appCancelRed = AppColors.cancelRed
    static let appRed = AppColors.red
    static let appOrange = AppColors.orange
    static let appPurple = AppColors.purple
    static let appGreen = AppColors.green
    static let appYellow = AppColors.yellow
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
