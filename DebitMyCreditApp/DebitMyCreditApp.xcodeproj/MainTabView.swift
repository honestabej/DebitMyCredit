import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            Text("Home")
                .navigationTitle("Home")
        }
    }
}

struct ProfileView: View {
    var body: some View {
        NavigationStack {
            Text("Profile")
                .navigationTitle("Profile")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(role: .destructive) { auth.logout() } label: { Text("Sign Out") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    MainTabView().environmentObject(AuthManager())
}
