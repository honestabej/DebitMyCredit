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
    
    // Bank Colors
    static let WellsFargoRed = Color(hex: "#B31E30")
    static let ChaseBlue = Color(hex: "#005EB8")
    static let DiscoverOrange = Color(hex: "#FB8C13")
    static let AppleGrey = Color(hex: "A2AAAD")
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
    
    static let appleCardGradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: Color(hex: "F2F2F2"), location: 0.0),
            .init(color: Color(hex: "E8E8E8"), location: 0.3),
            .init(color: Color(hex: "F5F5F0"), location: 0.6),
            .init(color: Color(hex: "DCDCDC"), location: 1.0)
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
