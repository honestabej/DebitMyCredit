import SwiftUI
import CoreData

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State private var notificationsEnabled: Bool = true
    @State private var showingAccountInfoView = false
    @State private var showingManageBankConnectionsView = false
    @State private var showingManageAccountsView = false
    @State private var showLogOutConfirmation = false
    @State private var bankConnectionsDetent: PresentationDetent = .height(220)
    @State private var bankConnectionsDetents: Set<PresentationDetent> = [.height(220)]
    
    var body: some View {
        // Background color
        ZStack {
            Color.appGreen.ignoresSafeArea()
            
            // Actual content
            VStack {
                PageHeaderView(title: "Settings", leftButton: EmptyView?.none, includeRefresh: false)
                
                VStack(spacing: 20) {
                    // Notification toggle row
                    HStack {
                        Toggle("Notifications Enabled: ", isOn: $notificationsEnabled)
                            .onChange(of: notificationsEnabled) { oldValue, newValue in
                                print("Old:", oldValue)
                                print("New:", newValue)
                                // TODO: Notification logic
                            }
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    
                    // View edit account info row
                    Button { showingAccountInfoView = true } label: {
                        HStack {
                            Text("Account Info:").fontWeight(.medium).foregroundColor(.primary)
                            Spacer()
                            Text(authManager.currentUser?.email ?? "No Email")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    // Manage bank account connections row
                    Button { showingManageBankConnectionsView = true } label: {
                        HStack {
                            Text("Manage Bank Connections").fontWeight(.medium).foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    // Logout button row
                    Button(role: .destructive) { showLogOutConfirmation = true } label: {
                        Text("Log Out")
                            .padding()
                            .frame(width: 225, height: 40)
                            .background(Color.appRed)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .fontWeight(.bold)
                            .padding(.bottom, 20)
                    }
                    .confirmationDialog(
                        "Are you sure you want to log out?",
                        isPresented: $showLogOutConfirmation,
                        titleVisibility: .visible,
                        actions: {
                            Button("Log Out", role: .destructive) { authManager.logout() }
                            Button("Cancel", role: .cancel) {}
                        }
                    )
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.lightBackground)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .sheet(isPresented: $showingAccountInfoView) {
            NavigationStack {
                AccountInfoView()
            }
            .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showingManageBankConnectionsView, onDismiss: {
            bankConnectionsDetent = .height(220)
            bankConnectionsDetents = [.height(220)]
        }) {
            ManageBankConnectionsView(selectedDetent: $bankConnectionsDetent, allowedDetents: $bankConnectionsDetents)
                .environmentObject(authManager)
                .environment(\.managedObjectContext, viewContext)
                .presentationDetents(bankConnectionsDetents, selection: $bankConnectionsDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
    }
}

#Preview("With Data") {
    return SettingsView()
        .environmentObject(PersistenceController.previewAuthManager())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty State") {
    return SettingsView()
        .environmentObject(PersistenceController.previewEmptyAuthManager())
        .environment(\.managedObjectContext, PersistenceController.previewEmpty.container.viewContext)
}

