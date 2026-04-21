import Foundation
import SwiftUI

// Returns the card background color based on the bank
func getBankColor(bankName: String) -> Color {
    if bankName.lowercased().contains("chase") {
        return Color.ChaseBlue
    } else if bankName.lowercased().contains("wells fargo") || bankName.contains("wellsfargo") {
        return Color.WellsFargoRed
    } else if bankName.lowercased().contains("discover") {
        return Color.DiscoverOrange
    } else if bankName.lowercased().contains("apple") {
        return Color.AppleGrey
    // TODO: Add more banks
    } else {
        return Color.appPurple
    }
}

// Returns the bank logo image asset name
func getBankTextLogo(bankName: String) -> String {
    if bankName.lowercased().contains("chase") {
        return "Chase-Text-Logo"
    } else if bankName.lowercased().contains("wells fargo") || bankName.contains("wellsfargo") {
        return "WF-Text-Logo"
    } else if bankName.lowercased().contains("discover") {
        return "Discover-Text-Logo"
    } else if bankName.lowercased().contains("apple") {
        return "Apple-Text-Logo"
    // TODO: Add more banks
    } else {
        return "Default-Circle-Logo"
    }
}

// Display the corresponding logo from assets based on the bank's name
func getBankCircleLogo(bankName: String) -> String {
    if bankName.lowercased().contains("chase") {
        return "Chase-Circle-Logo"
    } else if bankName.lowercased().contains("wells fargo") || bankName.contains("wellsfargo") {
        return "WF-Circle-Logo"
    } else if bankName.lowercased().contains("discover") {
        return "Discover-Circle-Logo"
    } else if bankName.lowercased().contains("apple") {
        return "Apple-Circle-Logo"
    // TODO: Add more banks
    } else {
        return "Default-Circle-Logo"
    }
}
