import UIKit

extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)
        let r, g, b: CGFloat
        if hexString.count == 6 {
            r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgbValue & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: alpha)
        } else if hexString.count == 8 { // ARGB
            let a = CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0
            let rr = CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0
            let gg = CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0
            let bb = CGFloat(rgbValue & 0x000000FF) / 255.0
            self.init(red: rr, green: gg, blue: bb, alpha: a)
        } else {
            self.init(white: 1.0, alpha: alpha)
        }
    }

    // Hex-based palette
    static let appLightGrey = UIColor(hex: "#F8F8F8")
    static let appGrey = UIColor(hex: "#EAEAEA")
    static let appCancelRed = UIColor(hex: "#FF7C7C")
    static let appRed = UIColor(hex: "#FF3B30")
    static let appOrange = UIColor(hex: "#FF9500")
    static let appPurple = UIColor(hex: "#8E44AD")
    static let appGreen = UIColor(hex: "#40C174")
    static let appYellow = UIColor(hex: "#F4B552")
    
    LinearGradient(
        gradient: Gradient(colors: [
            Color(hex: "#FF3B30"),
            Color(hex: "#FF9500"),
            Color(hex: "#8E44AD")
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
