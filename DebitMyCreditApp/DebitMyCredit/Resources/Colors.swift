import SwiftUI
import UIKit

// UIColor Hex Extension
extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexClean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexClean = hexClean.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexClean).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

// App Colors
struct AppColors {
    static let lightGrey = UIColor(hex: "#F8F8F8")
    static let grey = UIColor(hex: "#EAEAEA")
    static let cancelRed = UIColor(hex: "#FF7C7C")
    static let red = UIColor(hex: "#FF3B30")
    static let orange = UIColor(hex: "#FF9500")
    static let purple = UIColor(hex: "#8E44AD")
    static let green = UIColor(hex: "#40C174")
    static let yellow = UIColor(hex: "#F4B552")
}

// SwiftUI Color equivalents
extension Color {
    static let appLightGrey = Color(AppColors.lightGrey)
    static let appGrey = Color(AppColors.grey)
    static let appCancelRed = Color(AppColors.cancelRed)
    static let appRed = Color(AppColors.red)
    static let appOrange = Color(AppColors.orange)
    static let appPurple = Color(AppColors.purple)
    static let appGreen = Color(AppColors.green)
    static let appYellow = Color(AppColors.yellow)
}

// Default background gradient
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
}
