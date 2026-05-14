// RootView.swift
import SwiftUI

struct RootView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showRegister = false

    var body: some View {
        if authManager.isLoggedIn {
            MainTabView()
        } else {
            ZStack {
                if showRegister {
                    RegisterView(showRegister: $showRegister)
                        .transition(.opacity)
                } else {
                    LoginView(showRegister: $showRegister)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showRegister)
        }
    }
}
