import SwiftUI
import CoreData

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State private var notificationsEnabled: Bool = true
    @State private var showingAccountInfoView = false
    @State private var showingSimpleFinView = false
    @State private var showingManageAccountsView = false
    @State private var showLogOutConfirmation = false
    
    var body: some View {
        ZStack {
            // Background gradient
            AppGradients.horizontalGradient.ignoresSafeArea()
            
            // White background behind tab bar
            VStack {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, 70)
            
            // Actual content
            VStack {
                Text("Settings")
                    .font(.system(size: 25))
                    .fontWeight(.bold)
                    .padding(.top)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                
                Spacer().frame(height: 45)
                
                VStack(spacing: 20) {                    
                    HStack {
                        Toggle("Notifications Enabled: ", isOn: $notificationsEnabled)
                            .onChange(of: notificationsEnabled) { oldValue, newValue in
                                print("Old:", oldValue)
                                print("New:", newValue)
                                // TODO: Notification logic
                            }.fontWeight(.medium)
                    }.padding(.horizontal, 20)
                    
                    // Display account email on button to transition to AccountInfoView
                    Button {
                        showingAccountInfoView = true
                    } label: {
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

                    // Display connection status on button to transition to SetSimpleFinView
                    Button {
                        showingSimpleFinView = true
                    } label: {
                        HStack {
                            Text("SimpleFIN Connection").fontWeight(.medium).foregroundColor(.primary)
                            Spacer()
                            Text(authManager.currentUser?.simpleFinCredentialsSet == true ? "Connected" : "Not Connected")
                                .foregroundColor(authManager.currentUser?.simpleFinCredentialsSet == true ? .secondary : .gray)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Display arrow on button to transition to ManageAccountsView
                    Button {
                        showingManageAccountsView = true
                    } label: {
                        HStack {
                            Text("Manage bank accounts").fontWeight(.medium).foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(role: .destructive) {
                        showLogOutConfirmation = true
                    } label: {
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
            }
        }
        .sheet(isPresented: $showingAccountInfoView) {
            NavigationStack {
                AccountInfoView()
            }
            .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showingSimpleFinView) {
            NavigationStack {
                SetSimpleFinView()
            }
            .presentationDetents([.height(320)])
        }
        .sheet(isPresented: $showingManageAccountsView) {
            NavigationStack {
                ManageAccountsView()
            }
            .presentationDetents([.medium, .large])
        }
    }
}

#Preview {
    let context = PersistenceController.preview.container.viewContext
    let authManager = AuthManager(viewContext: context)
    
    return SettingsView()
        .environmentObject(authManager)
}

