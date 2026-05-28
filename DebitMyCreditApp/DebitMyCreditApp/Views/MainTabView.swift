import SwiftUI
import CoreData

struct MainTabView: View {
    @State private var selectedTab: Tab = .accounts
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackgroundTime: Date?
    @State private var currentSimpleFINMessage: String? = nil

    enum Tab: Hashable {
        case accounts
        case transactions
        case transfers
        case settings
    }
    
    init(selectedTab: Tab = .accounts) {
        self._selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                AccountsView()
            }
            .tabItem {
                Label("Accounts", systemImage: "creditcard")
            }
            .tag(Tab.accounts)

            NavigationStack {
                TransactionsView()
            }
            .tabItem {
                Label("Transactions", systemImage: "list.bullet.rectangle")
            }
            .tag(Tab.transactions)

            NavigationStack {
                PaymentGroupsView()
            }
            .tabItem {
                Label("Payments", systemImage: "arrow.left.arrow.right")
            }
            .tag(Tab.transfers)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .tint(.appOrange)
        .overlay(alignment: .top) {
            // Syncing overlay to display acorss all pages whenever a background sync is happening
            if authManager.isRefreshing || authManager.isSyncingSimpleFIN || authManager.isLoadingUserData {
                let syncText: String = authManager.isSyncingSimpleFIN ? "Syncing Bank Connections..." :
                                       authManager.isLoadingUserData ? "Loading Data..." : "Refreshing..."
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(syncText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let message = currentSimpleFINMessage {
                Text("SimpleFIN Msg: \(message)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(Color.errorRed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentSimpleFINMessage)
        .onChange(of: authManager.simpleFINMessages) { _, messages in
            guard !messages.isEmpty else { return }
            var remaining = messages
            func showNext() {
                guard !remaining.isEmpty else { return }
                currentSimpleFINMessage = remaining.removeFirst()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    currentSimpleFINMessage = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showNext()
                    }
                }
            }
            showNext()
            authManager.simpleFINMessages = []
        }
        .animation(.easeInOut(duration: 0.3), value: authManager.isLoadingUserData)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
        }
    }
    
    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            // App went to background - record the time
            lastBackgroundTime = Date()
            
        case .active:
            // App became active
            if let backgroundTime = lastBackgroundTime {
                let timeInBackground = Date().timeIntervalSince(backgroundTime)
                
                // If app was in background for more than 5 minutes, refresh data
                if timeInBackground > 300 { // 5 minutes
                    print("Refreshing data after extended background time")
                    Task {
                        await authManager.fetchAndLoadUserData()
                    }
                }
            }
            
        case .inactive:
            // App is temporarily inactive (e.g., phone call, control center)
            break
            
        @unknown default:
            break
        }
    }
}

#Preview("With Data") {
    return MainTabView()
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Empty State") {
    return MainTabView()
        .environmentObject(PersistenceController.previewEmptyAuthManager())
}
