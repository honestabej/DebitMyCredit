// RootView.swift
import SwiftUI

struct RootView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showRegister = false
    @State private var showSplash = true

    var body: some View {
        ZStack {
            if showSplash {
                SplashView()
                    .transition(.opacity)
            } else if authManager.isLoggedIn {
                MainTabView()
                    .transition(.opacity)
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
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showSplash)
        .onAppear {
            // Hide splash once auth state is determined and any initial load completes
            Task {
                // Give AuthManager a moment to check the keychain and kick off loading
                try? await Task.sleep(nanoseconds: 300_000_000)
                // Wait until loading finishes
                while authManager.isLoadingUserData {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                showSplash = false
            }
        }
    }
}

struct SplashView: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Color.appGreen
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // App icon-style logo mark
                ZStack {
//                    Circle()
//                        .fill(.white.opacity(0.15))
//                        .frame(width: 110, height: 110)
//                        .scaleEffect(pulsing ? 1.08 : 1.0)
//                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)

                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("DebitMyCredit")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Spend with confidence")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }

                ProgressView()
                    .tint(.white)
                    .padding(.top, 8)
            }
        }
        .onAppear { pulsing = true }
    }
}
