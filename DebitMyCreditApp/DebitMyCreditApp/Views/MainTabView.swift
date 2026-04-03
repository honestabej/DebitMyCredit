import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .accounts

    enum Tab: Hashable {
        case accounts
        case transactions
        case transfers
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            AccountsView()
                .tabItem {
                    Label("Accounts", systemImage: "creditcard")
                }
                .tag(Tab.accounts)

            TransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }
                .tag(Tab.transactions)

            TransfersView()
                .tabItem {
                    Label("Transfers", systemImage: "arrow.left.arrow.right")
                }
                .tag(Tab.transfers)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }.tint(.appRed)
    }
}

#Preview {
    MainTabView()
}
