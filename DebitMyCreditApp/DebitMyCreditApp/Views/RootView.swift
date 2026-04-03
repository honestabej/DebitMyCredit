// RootView.swift
import SwiftUI

struct RootView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showRegister = false

    var body: some View {
        if authManager.isLoggedIn {
            MainTabView()
        } else {
            if showRegister {
                RegisterView()
            } else {
                LoginView()
            }
        }
    }
}
