import SwiftUI
import CoreData

struct MainTabView: View {
    @State private var selectedTab: Tab = .accounts
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackgroundTime: Date?

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
                TransfersView()
            }
            .tabItem {
                Label("Transfers", systemImage: "arrow.left.arrow.right")
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
        .tint(.appRed)
        .overlay(alignment: .top) {
            // Syncing overlay to display acorss all pages whenever a background sync is happening
            if authManager.isLoadingUserData {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Syncing...")
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
            print("📱 App entered background at \(Date())")
            
        case .active:
            // App became active
            if let backgroundTime = lastBackgroundTime {
                let timeInBackground = Date().timeIntervalSince(backgroundTime)
                print("📱 App became active after \(Int(timeInBackground))s in background")
                
                // If app was in background for more than 5 minutes, refresh data
                if timeInBackground > 300 { // 5 minutes
                    print("🔄 Refreshing data after extended background time")
                    Task {
                        await authManager.loadUserData()
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

#Preview {
    let context = PersistenceController.preview.container.viewContext
    let authManager = AuthManager(viewContext: context)
    
    return MainTabView()
        .environmentObject(authManager)
}
