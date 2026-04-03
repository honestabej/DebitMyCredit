import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "creditcard") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }

            TransfersView()
                .tabItem { Label("Transfers", systemImage: "arrow.left.arrow.right") }
            
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct AccountsView: View {
    var body: some View {
        NavigationStack {
            Text("Checking Accounts")
                .navigationTitle("Checking Accounts")
        }
    }
}

struct TransactionsView: View {
    var body: some View {
        NavigationStack {
            Text("Credit Transactions")
                .navigationTitle("Credit Transactions")
        }
    }
}

struct TransfersView: View {
    var body: some View {
        NavigationStack {
            Text("Transfer Groups")
                .navigationTitle("Transfer Groups")
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
