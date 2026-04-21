import SwiftUI
import CoreData

// Holds pending edits for a single account before Save is tapped
struct PendingAccountEdit {
    var name: String
    var accountType: String
}

struct ManageAccountsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        animation: .default
    )
    private var accounts: FetchedResults<Account>

    @State private var isSyncing = false
    @State private var showSyncSuccess = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var isSaving = false
    @State private var showSuccessAlert = false
    
    // List of edits that have
    @State private var pendingEdits: [String: PendingAccountEdit] = [:]

    var hasUnsavedChanges: Bool {
        !pendingEdits.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if accounts.isEmpty || authManager.currentUser?.simpleFinCredentialsSet == false {
                // Display the emptyStateView if the user doesnt have SimpleFIN connected, or has no banks connected to their SimpleFIN account
                emptyStateView
            } else {
                accountsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Save button pinned to bottom
                Button(action: saveAllChanges) {
                    HStack {
                        Text("Save")
                        if (isSaving){
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)
                                .opacity(isSaving ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(hasUnsavedChanges ? Color.appOrange : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .fontWeight(.bold)
                }
                .disabled(!hasUnsavedChanges || isSaving)
                .padding(.horizontal, 80)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Manage Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDragIndicator(.visible)
        .toolbar {
            
            // Refresh button in the navigation bar if user has simpleFIN connected AND accounts
            if authManager.currentUser?.simpleFinCredentialsSet == true && !accounts.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: triggerSync) {
                        ZStack {
                            // Display the refresh icon or the progress indicator depending on if syncing is happening
                            ProgressView()
                                .controlSize(.regular)
                                .opacity(isSyncing ? 1 : 0)
                            Image(systemName: "arrow.clockwise")
                                .opacity(isSyncing ? 0 : 1)
                        }
                    }
                    .disabled(isSyncing)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong")
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") {}
                .tint(.blue)
        } message: {
            Text("Account info updated successfully!")
        }
    }
    
    // View that is displayed when user has not connected SimpleFIN or bank accounts
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "creditcard.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.3))
            
            Text("No Accounts")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Text(accounts.isEmpty ? "Visit www.beta-bridge.simplefin.org to connect your banks and manage accounts" : "Connect your SimpleFIN account in Settings to manage your accounts")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // View to display the user's accounts as a scrollable list
    private var accountsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(accounts) { account in
                    ManageAccountRow(
                        account: account,
                        pendingEdit: Binding(
                            get: { pendingEdits[account.id ?? ""] },
                            set: { pendingEdits[account.id ?? ""] = $0 }
                        )
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    if account != accounts.last {
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            }
        }
    }

    // Sends pending edits to the server, and saves to Core Data on success
    private func saveAllChanges() {
        // Show the Progress view in the button
        isSaving = true
        
        // Build the server payload and a local list of edits to apply after server confirms
        var accountsToUpdate: [APIModels.Account] = []
        var editsToApply: [(account: Account, name: String, accountType: String)] = []

        for account in accounts {
            guard let id = account.id, let edit = pendingEdits[id] else { continue }
            let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (account.name ?? "") : trimmedName

            editsToApply.append((account: account, name: finalName, accountType: edit.accountType))
            accountsToUpdate.append(APIModels.Account(
                id: id,
                name: finalName,
                bank: account.bank ?? "",
                accountNumber: account.accountNumber,
                accountBalance: account.accountBalance?.doubleValue ?? 0,
                accountType: edit.accountType,
                balanceDate: nil,
                createdAt: nil,
                updatedAt: nil
            ))
        }

        guard !accountsToUpdate.isEmpty,
              let token = KeychainHelper.get("auth_token"),
              let userUUID = authManager.currentUser?.id else {
            pendingEdits = [:]
            return
        }

        Task {
            do {
                // Call API to save edits to the AzureDB
                _ = try await APIService.shared.updateAccountInfo(userID: userUUID, token: token, accounts: accountsToUpdate)
                print("[ManageAccountsView] Server sync complete for \(accountsToUpdate.count) accounts")

                // If the server has been updated, write data to CoreData
                for edit in editsToApply {
                    edit.account.name = edit.name
                    edit.account.accountType = edit.accountType
                    edit.account.updatedAt = Date()
                }
                if viewContext.hasChanges {
                    try viewContext.save()
                    print("[ManageAccountsView] Core Data saved \(editsToApply.count) account edits")
                }

                await MainActor.run {
                    pendingEdits = [:]
                    isSaving = false
                }

            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    // Triggers a sync from SimpleFIN > AzureDB > Application
    private func triggerSync() {
        isSyncing = true
        
        Task {
            do {
                await authManager.refreshData()
                
                await MainActor.run {
                    isSyncing = false
                    showSyncSuccess = true
                }
                
                // Hide success message after 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    showSyncSuccess = false
                }
                
            } catch {
                await MainActor.run {
                    isSyncing = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
}

// MARK: - Account Row
struct ManageAccountRow: View {
    @ObservedObject var account: Account
    @Binding var pendingEdit: PendingAccountEdit?

    @State private var editingName: String = ""
    @State private var isEditingName = false
    @FocusState private var isNameFieldFocused: Bool

    // The AccountName that is displayed in the row (before saving)
    private var displayName: String {
        pendingEdit?.name ?? account.name ?? ""
    }

    // The AccountType that is displayed in the row (before saving)
    private var displayAccountType: String {
        pendingEdit?.accountType ?? account.accountType ?? "N/A"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Display corresponding Bank Logo
            Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            // Name, acct#, and type container
            VStack(alignment: .leading, spacing: 12) {

                // Top row of account, containing name and account number
                HStack(spacing: 12) {
                    if isEditingName {
                        // When editing accountName
                        TextField("Account name", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFieldFocused)
                            .onSubmit {
                                commitNameEdit()
                            }

                        Button("Done") {
                            commitNameEdit()
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                    } else {
                        // When not editing accountName
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(displayName.isEmpty ? "Unknown Account" : displayName)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Button(action: {
                                    editingName = displayName
                                    isEditingName = true
                                    isNameFieldFocused = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 16))
                                        .foregroundColor(.appPurple)
                                        .frame(width: 25, height: 25)
                                }

                                if let accountNumber = account.accountNumber, !accountNumber.isEmpty {
                                    Text("\(accountNumber)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // Bottom row of account, containing accountType picker
                HStack {
                    Text("Acct Type:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    Picker("Account Type", selection: Binding(
                        get: { displayAccountType },
                        set: { newValue in
                            
                            // Create a pending account type change
                            if pendingEdit == nil {
                                pendingEdit = PendingAccountEdit(name: displayName, accountType: newValue)
                            } else {
                                pendingEdit?.accountType = newValue
                            }
                        }
                    )) {
                        Text("N/A").tag("N/A")
                        Text("Debit").tag("Debit")
                        Text("Credit").tag("Credit")
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                }
            }
        }
    }

    // Create a pending name change
    private func commitNameEdit() {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingName = false
            return
        }
        if pendingEdit == nil {
            pendingEdit = PendingAccountEdit(name: trimmed, accountType: displayAccountType)
        } else {
            pendingEdit?.name = trimmed
        }
        isEditingName = false
    }
}

// MARK: - Preview
#Preview("With Accounts") {
    // Create a fresh preview controller each time
    let persistence = PersistenceController(inMemory: true)
    let context = persistence.container.viewContext
    
    // Clear any existing data
    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "Account")
    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    try? context.execute(deleteRequest)
    
    let userFetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "User")
    let userDeleteRequest = NSBatchDeleteRequest(fetchRequest: userFetchRequest)
    try? context.execute(userDeleteRequest)
    
    context.reset()
    
    // Create a test user
    let user = User(context: context)
    user.id = UUID()
    user.email = "test@example.com"
    user.simpleFinCredentialsSet = true
    user.createdAt = Date()
    user.updatedAt = Date()
    
    // Create sample accounts
    let checkingAccount = Account(context: context)
    checkingAccount.id = "acc_1"
    checkingAccount.name = "Wells Fargo Checking"
    checkingAccount.bank = "Wells Fargo"
    checkingAccount.accountNumber = "1234"
    checkingAccount.accountBalance = NSDecimalNumber(value: 2_543.67)
    checkingAccount.accountType = "Debit"
    checkingAccount.balanceDate = Date()
    checkingAccount.createdAt = Date()
    checkingAccount.updatedAt = Date()
    checkingAccount.user = user
    
    let savingsAccount = Account(context: context)
    savingsAccount.id = "acc_2"
    savingsAccount.name = "Savings Account"
    savingsAccount.bank = "Wells Fargo"
    savingsAccount.accountBalance = NSDecimalNumber(value: 15_234.89)
    savingsAccount.accountType = "N/A"
    savingsAccount.balanceDate = Date()
    savingsAccount.createdAt = Date()
    savingsAccount.updatedAt = Date()
    savingsAccount.user = user
    
    let creditCard = Account(context: context)
    creditCard.id = "acc_3"
    creditCard.name = "Chase Sapphire Preferred"
    creditCard.bank = "Chase"
    creditCard.accountBalance = NSDecimalNumber(value: -1_234.56)
    creditCard.accountType = "Credit"
    creditCard.balanceDate = Date().addingTimeInterval(-86400)
    creditCard.createdAt = Date()
    creditCard.updatedAt = Date()
    creditCard.user = user
    
    try? context.save()
    
    let authManager = AuthManager(viewContext: context)
    authManager.currentUser = user
    authManager.isLoggedIn = true
    
    return NavigationStack {
        ManageAccountsView()
            .environmentObject(authManager)
            .environment(\.managedObjectContext, context)
    }
}

#Preview("Empty State") {
    let persistence = PersistenceController(inMemory: true)
    let context = persistence.container.viewContext
    
    // Clear any existing data
    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "Account")
    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    try? context.execute(deleteRequest)
    
    let userFetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "User")
    let userDeleteRequest = NSBatchDeleteRequest(fetchRequest: userFetchRequest)
    try? context.execute(userDeleteRequest)
    
    context.reset()
    
    let user = User(context: context)
    user.id = UUID()
    user.email = "empty@example.com"
    user.simpleFinCredentialsSet = false
    user.createdAt = Date()
    user.updatedAt = Date()
    
    try? context.save()
    
    let authManager = AuthManager(viewContext: context)
    authManager.currentUser = user
    authManager.isLoggedIn = true
    
    return NavigationStack {
        ManageAccountsView()
            .environmentObject(authManager)
            .environment(\.managedObjectContext, context)
    }
}
