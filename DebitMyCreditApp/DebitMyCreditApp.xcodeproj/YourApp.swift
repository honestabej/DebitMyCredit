import SwiftUI

@main
struct YourApp: App {
    @StateObject private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(auth)
        }
    }
}

struct AppView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
    }
}
