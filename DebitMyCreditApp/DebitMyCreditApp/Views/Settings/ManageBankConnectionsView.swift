import SwiftUI
import CoreData

enum BankConnectionDestination: Hashable {
    case simpleFin, lunchFlow, manual
}

// Holds pending edits for a single account before Save is tapped
struct PendingAccountEdit {
    var name: String
    var accountType: String
}

// MARK: Initial view -- ManageBankConnectionsView
struct ManageBankConnectionsView: View {
    // Inherit the context and authManager passed in from SettingsView
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    
    // Handle the height of the detent that the views are displayed in
    @Binding var selectedDetent: PresentationDetent
    @Binding var allowedDetents: Set<PresentationDetent>
    
    // Handle the transition between the initial view and the destination views within this detent
    @State private var activeDestination: BankConnectionDestination? = nil
    @State private var initialMenuViewOpacity: Double = 1
    @State private var destinationViewOpacity: Double = 0
    @State private var destinationContentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 800
    @State private var isManualAdding: Bool = false
    @State private var manualContentOpacity: Double = 1
    private var destinationTitle: String {
        if activeDestination == .manual && isManualAdding {
            return "Add Account"
        }
        switch activeDestination {
        case .simpleFin: return "SimpleFIN Connections"
        case .lunchFlow: return "Lunch Flow Connections"
        case .manual:    return "Manual Accounts"
        case nil:        return ""
        }
    }
    
    // Function to smoothly animate transition from ManageBankConnectionsView to one of the destinations
    private func showDestination(_ destination: BankConnectionDestination) {
        destinationContentHeight = 0
        // First fade out the ManageBankConnectionsView
        withAnimation(.easeOut(duration: 0.15)) {
            initialMenuViewOpacity = 0
        }
        // Ensure that the detent resizes BEFORE the new destination view fades in so that it renders at the correct size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            activeDestination = destination
            withAnimation(.easeIn(duration: 0.2)) {
                destinationViewOpacity = 1
            }
        }
    }

    // Function to smoothly animate transition from a destination view back to ManageBankAccountConnectionsView
    private func hideDestination() {
        // First fade out the destination view
        withAnimation(.easeOut(duration: 0.2)) {
            destinationViewOpacity = 0
        }
        // After fade, open allowedDetents to include 220 so the sheet can animate down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            allowedDetents = [selectedDetent, .height(220)]
            withAnimation(.easeInOut(duration: 0.35)) {
                selectedDetent = .height(220)
            }
        }
        // After detent settles, lock to 220 and swap to menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            activeDestination = nil
            allowedDetents = [.height(220)]
            withAnimation(.easeIn(duration: 0.2)) {
                initialMenuViewOpacity = 1
            }
        }
    }
    
    // Fetch the counts of each accountSource
    var accountSourceCounts: [String: Int] { (try? CoreDataService.shared.getAccountSourceCounts(context: viewContext)) ?? [:] }
    
    var body: some View {
        NavigationStack {
            // ZStack holds initial and destination views on top of each other, toggling opacity for visibilty
            ZStack {
                // Initial Menu layer
                VStack(spacing: 0) {
                    menuRow(title: "SimpleFIN Connections", count: accountSourceCounts["simpleFINAccountsCount"] ?? 0, credentialsSet: authManager.currentUser?.simpleFinCredentialsSet, destination: .simpleFin)
                    menuRow(title: "Lunch Flow Connections", count: accountSourceCounts["lunchFlowAccountsCount"] ?? 0, credentialsSet: authManager.currentUser?.lunchFlowCredentialsSet, destination: .lunchFlow)
                    menuRow(title: "Manual Connections", count: accountSourceCounts["manualAccountsCount"] ?? 0, destination: .manual)
                }
                .opacity(initialMenuViewOpacity)
                
                // Specific bank source layer
                if let destination = activeDestination {
                    Group {
                        switch destination {
                        case .simpleFin:
                            BankConnectionView(onBack: hideDestination, contentHeight: $destinationContentHeight, connectionType: .simpleFin)
                        case .lunchFlow:
                            BankConnectionView(onBack: hideDestination, contentHeight: $destinationContentHeight, connectionType: .lunchFlow)
                        case .manual:
                            ManualConnectionView(onBack: hideDestination, contentHeight: $destinationContentHeight, connectionType: .manual, isAdding: $isManualAdding, contentOpacity: $manualContentOpacity)
                        }
                    }
                    .opacity(destinationViewOpacity)
                }
                
            }
            .navigationTitle(activeDestination == nil ? "Manage Bank Connections" : destinationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // If on the BankConnectionView, display a back button
                if activeDestination != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            if activeDestination == .manual && isManualAdding {
                                withAnimation(.easeOut(duration: 0.15)) { manualContentOpacity = 0 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isManualAdding = false }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                    withAnimation(.easeIn(duration: 0.2)) { manualContentOpacity = 1 }
                                }
                            } else {
                                hideDestination()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .onChange(of: destinationContentHeight) { _, height in
                // Change the height of the detent whenever the content height changes
                guard height > 0 else { return }

                let maxHeight = screenHeight * 0.75
                let target = min(height + 70, maxHeight)
                // Include both current and target in allowedDetents so the sheet can animate between them
                allowedDetents = [selectedDetent, .height(target)]
                withAnimation(.easeInOut(duration: 0.35)) {
                    selectedDetent = .height(target)
                }
                // After animation settles, lock to just the target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    allowedDetents = [.height(target)]
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).height + $0.frame(in: .global).minY
            } action: {
                screenHeight = $0
            }
        }
    }
    
    // Create the menu row for each account source
    @ViewBuilder
    func menuRow(title: String, count: Int, credentialsSet: Bool? = false, destination: BankConnectionDestination) -> some View {
        Button {
            showDestination(destination)
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if destination == .manual {
                    Text(count == 1 ? "1 account" : "\(count) accounts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 6)
                } else {
                    if credentialsSet ?? false {
                        Text(count == 1 ? "1 account" : "\(count) accounts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.trailing, 6)
                    } else {
                        Text("Not Connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.trailing, 6)
                    }
                }
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Destination view for Manual accounts
struct ManualConnectionView: View {
    // Inherits these from parent view ManageBankConnectionView
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    
    // Handle detent sizing
    let onBack: () -> Void
    @Binding var contentHeight: CGFloat
    let connectionType: BankConnectionDestination
    @Binding var isAdding: Bool
    @Binding var contentOpacity: Double
    
    // Hold the accounts
    private var accounts: [Account] {
        let _ = refreshToken  // depend on refreshToken so SwiftUI re-evaluates when it changes
        return (try? CoreDataService.shared.getAccountsOfAccountSource(context: viewContext, accountSource: "Manual")) ?? []
    }
    
    // Determine whether there are pending edits that can be saved
    var hasUnsavedChanges: Bool {
        !pendingEdits.isEmpty
    }
    
    // Easily accesible userID variable
    var userID: UUID? { authManager.currentUser?.id }
    
    // State variables to control UI eleents
    @State private var refreshToken = UUID()
    @State private var accountName: String = ""
    @State private var accountNum: String = ""
    @State private var bankName: String = ""
    @State private var startingBalance: String = ""
    @State private var isSyncing = false
    @State private var showSyncSuccess = false
    @State private var isSaving = false
    @State private var isEditingAnyName = false
    @State private var isSavingMessage: String = "Saving Account..."
    @State private var showSuccessAlert = false
    @State private var successfulMessage: String = "Success"
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var pendingEdits: [UUID: PendingAccountEdit] = [:]
    @State private var accountToDelete: Account? = nil
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                if !isAdding {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(accounts) { account in
                                SwipeToDeleteRow {
                                    accountToDelete = account
                                    showDeleteConfirmation = true
                                } content: {
                                    ManageAccountRow(
                                        account: account,
                                        pendingEdit: Binding(
                                            get: { account.id.flatMap { pendingEdits[$0] } },
                                            set: { if let id = account.id { pendingEdits[id] = $0 } }
                                        ),
                                        isEditingName: $isEditingAnyName
                                    )
                                    .padding(.vertical, 10)
                                }

                                if account != accounts.last {
                                    Divider()
                                }
                            }
                            // Add Manual account button to end of list
                            Button {
                                transitionIsAdding(to: true)
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(width: 35, height: 35)
                                        Image(systemName: "plus")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                    Text("Add a Manually Tracked Account")
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !isSaving && !isEditingAnyName { contentHeight = max($0 + 65, 200) } }
                    }
                    .alert("Delete Account", isPresented: $showDeleteConfirmation) {
                        Button("Delete", role: .destructive) {
                            if let account = accountToDelete { deleteAccount(account) }
                        }
                        Button("Cancel", role: .cancel) { accountToDelete = nil }
                    } message: {
                        Text("Are you sure you want to delete \(accountToDelete?.name ?? "this account")?")
                    }
                    
                    HStack {
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
                        .disabled(!hasUnsavedChanges)
                    }
                } else {
                    // Fields pinned to top — measured for detent sizing
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Enter Account Name", text: $accountName)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.primary)
                            .font(.system(size: 14))
                            .frame(height: 20)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        
                        HStack {
                            Text("••••")
                                .font(.system(size: 20))
                            TextField("Acct #", text: $accountNum)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.primary)
                                .font(.system(size: 14))
                                .frame(height: 20)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                .frame(width: 70)
                                .keyboardType(.numberPad)
                                .onChange(of: accountNum) { _, newValue in
                                    let digits = newValue.filter { $0.isNumber }
                                    accountNum = String(digits.prefix(4))
                                }

                            TextField("Bank/Institution", text: $bankName)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.primary)
                                .font(.system(size: 14))
                                .frame(height: 20)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }

                        HStack {
                            Spacer()
                            Text("$")
                                .fontWeight(.bold)
                                .font(.system(size: 25))
                            TextField("Starting Balance", text: $startingBalance)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.primary)
                                .font(.system(size: 14))
                                .frame(width: 150, height: 20)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                .keyboardType(.decimalPad)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = max($0 + 110, 200) }
                    
                    Spacer()
                    
                    // Save button pinned to bottom
                    Button(action: saveAccount) {
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
                        .background(Color.appOrange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .fontWeight(.bold)
                    }
                }
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity)
            .opacity(contentOpacity)
            .animation(.easeInOut(duration: 0.2), value: contentOpacity)
            .toolbar {
                // Show a refresh button when not on the adding view
                if !isAdding {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: triggerSync) {
                            ZStack {
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
                Text(successfulMessage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            refreshToken = UUID()
        }
        
        // Overlay during saving
        if isSaving {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            ProgressView(isSavingMessage)
                .padding(16)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .tint(.white)
                .foregroundStyle(.white)
        }
    }
    
    // Fade out current content, let detent resize, then fade in new content
    private func transitionIsAdding(to newValue: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            contentOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isAdding = newValue
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeIn(duration: 0.2)) {
                contentOpacity = 1
            }
        }
    }

    // Sends pending edits to the server, and saves to Core Data on success
    private func saveAllChanges() {
        isSaving = true

        var accountsToUpdate: [APIModels.Account] = []
        var editsToApply: [(account: Account, name: String, accountType: String)] = []

        for account in accounts {
            guard let id = account.id, let edit = pendingEdits[id] else { continue }
            let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (account.name ?? "") : trimmedName

            editsToApply.append((account: account, name: finalName, accountType: edit.accountType))
            accountsToUpdate.append(APIModels.Account(
                id: id,
                externalID: account.externalID ?? "",
                name: finalName,
                bank: account.bank ?? "",
                accountSource: account.accountSource,
                accountNumber: account.accountNumber,
                availableBalance: account.availableBalance?.doubleValue ?? 0,
                balance: account.balance?.doubleValue ?? 0,
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
                _ = try await APIService.shared.updateAccountInfo(userID: userUUID, token: token, accounts: accountsToUpdate)
                print("[BankConnectionView] Server sync complete for \(accountsToUpdate.count) accounts")

                for edit in editsToApply {
                    edit.account.name = edit.name
                    edit.account.accountType = edit.accountType
                    edit.account.updatedAt = Date()
                }
                if viewContext.hasChanges {
                    try viewContext.save()
                    print("[BankConnectionView] Core Data saved \(editsToApply.count) account edits")
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
    
    // Add a new manual account
    private func saveAccount() {
        let trimmedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Account name is required"
            showErrorAlert = true
            return
        }

        guard let balance = Double(startingBalance.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Please enter a valid starting balance"
            showErrorAlert = true
            return
        }

        guard let userID else {
            errorMessage = "User not found. Please log in again."
            showErrorAlert = true
            return
        }

        let trimmedAccountNum = accountNum.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountNumber = trimmedAccountNum.isEmpty ? nil : trimmedAccountNum
        let trimmedBankName = bankName.trimmingCharacters(in: .whitespacesAndNewlines)

        isSavingMessage = "Saving Account..."
        isSaving = true

        let newID = UUID()
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let nowString = isoFormatter.string(from: now)

        // Build CoreData account dict
        var accountData: [String: Any] = [
            "id": newID,
            "externalID": newID.uuidString,
            "name": trimmedName,
            "bank": trimmedBankName,
            "accountSource": "Manual",
            "availableBalance": balance,
            "balance": balance,
            "balanceDate": nowString
        ]
        if let accountNumber { accountData["accountNumber"] = accountNumber }

        // Save to CoreData first
        let savedAccount: Account?
        do {
            savedAccount = try CoreDataService.shared.saveBankConnectionAccount(accountData, forUserID: userID, in: viewContext)
            // Set balanceDate directly since the string format won't match CoreDataService's Azure parser
            savedAccount?.balanceDate = now
            if viewContext.hasChanges { try viewContext.save() }
        } catch {
            isSaving = false
            errorMessage = "Failed to create account: \(error.localizedDescription)"
            showErrorAlert = true
            return
        }

        guard let savedAccount else {
            isSaving = false
            errorMessage = "Failed to create account"
            showErrorAlert = true
            return
        }

        Task {
            let apiAccount = APIModels.Account(
                id: newID,
                externalID: newID.uuidString,
                name: trimmedName,
                bank: trimmedBankName,
                accountSource: "Manual",
                accountNumber: accountNumber,
                availableBalance: balance,
                balance: balance,
                accountType: "-",
                balanceDate: .string(nowString),
                createdAt: .string(nowString),
                updatedAt: .string(nowString)
            )

            do {
                _ = try await APIService.shared.addManualAccount(userID: userID, account: apiAccount, createdAt: nowString, updatedAt: nowString)

                await MainActor.run {
                    isSaving = false
                    successfulMessage = "Account added successfully!"
                    showSuccessAlert = true
                    accountName = ""
                    accountNum = ""
                    bankName = ""
                    startingBalance = ""
                    transitionIsAdding(to: false)
                }
            } catch {
                // Revert CoreData save
                viewContext.delete(savedAccount)
                try? viewContext.save()

                await MainActor.run {
                    isSaving = false
                    errorMessage = "Failed to save account to server: \(error.localizedDescription)"
                    showErrorAlert = true
                }
            }
        }
    }

    // Delete a manual account, reverting CoreData if the server call fails
    private func deleteAccount(_ account: Account) {
        guard let accountID = account.id, let userID else {
            errorMessage = "Unable to delete account"
            showErrorAlert = true
            return
        }

        isSavingMessage = "Deleting Account..."
        isSaving = true

        // Snapshot enough data to restore the account if the server call fails
        let snapshot: [String: Any] = [
            "id": accountID,
            "externalID": account.externalID ?? accountID.uuidString,
            "name": account.name ?? "",
            "bank": account.bank ?? "",
            "accountSource": account.accountSource ?? "Manual",
            "availableBalance": account.availableBalance?.doubleValue ?? 0,
            "balance": account.balance?.doubleValue ?? 0
        ]

        // Delete from CoreData first
        viewContext.delete(account)
        do {
            try viewContext.save()
        } catch {
            isSaving = false
            errorMessage = "Failed to delete account: \(error.localizedDescription)"
            showErrorAlert = true
            return
        }

        Task {
            do {
                _ = try await APIService.shared.deleteManualAccount(userID: userID, accountID: accountID)

                await MainActor.run {
                    isSaving = false
                    accountToDelete = nil
                    successfulMessage = "Account deleted successfully!"
                    showSuccessAlert = true
                }
            } catch {
                // Revert CoreData deletion by re-inserting the account
                try? CoreDataService.shared.saveBankConnectionAccount(snapshot, forUserID: userID, in: viewContext)

                await MainActor.run {
                    isSaving = false
                    accountToDelete = nil
                    errorMessage = "Failed to delete account from server: \(error.localizedDescription)"
                    showErrorAlert = true
                }
            }
        }
    }

    // Triggers a sync from Bank Connection > AzureDB > Application
    private func triggerSync() {
        isSyncing = true

        isSavingMessage = "Saving account edits..."

        Task {
            do {
                await authManager.refreshData()

                await MainActor.run {
                    isSyncing = false
                    showSyncSuccess = true
                }

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

// Destination view for SimpleFIN and Lunch Flow connections
struct BankConnectionView: View {
    // Inherits these from parent view ManageBankConnectionView
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    
    // Handle detent sizing
    let onBack: () -> Void
    @Binding var contentHeight: CGFloat
    let connectionType: BankConnectionDestination
    
    // Get the connection status of the corresponding account source
    private var credentialsSet: Bool {
        switch connectionType {
        case .simpleFin: return authManager.currentUser?.simpleFinCredentialsSet == true
        case .lunchFlow: return authManager.currentUser?.lunchFlowCredentialsSet == true
        case .manual:    return true
        }
    }
    
    // Hold the accounts of each account source
    private var accounts: [Account] {
        let _ = refreshToken  // depend on refreshToken so SwiftUI re-evaluates when it changes
        switch connectionType {
        case .simpleFin: return (try? CoreDataService.shared.getAccountsOfAccountSource(context: viewContext, accountSource: "SimpleFIN")) ?? []
        case .lunchFlow: return (try? CoreDataService.shared.getAccountsOfAccountSource(context: viewContext, accountSource: "Lunch Flow")) ?? []
        case .manual: return (try? CoreDataService.shared.getAccountsOfAccountSource(context: viewContext, accountSource: "Manual")) ?? []
        }
    }
    
    // Determine whether there are pending edits that can be saved
    var hasUnsavedChanges: Bool {
        !pendingEdits.isEmpty
    }
    
    // Easily accesible userID variable
    var userID: UUID? { authManager.currentUser?.id }

    // Configure the strings to used in the credential-entry form
    private var credentialFormConfig: (placeholder: String, externalURL: URL?, externalButtonLabel: String) {
        switch connectionType {
        case .simpleFin:
            return ("Enter SimpleFIN Setup Token",
                    URL(string: "https://bridge.simplefin.org/simplefin/create"),
                    "Open SimpleFIN Bridge")
        case .lunchFlow:
            return ("Enter Lunch Flow API Key",
                    URL(string: "https://www.lunchflow.app/dashboard"),
                    "Open Lunch Flow Dashboard")
        case .manual:
            return ("", nil, "")
        }
    }
    
    // State variables to control UI eleents
    @State private var refreshToken = UUID()
    @State private var credentialInput: String = ""
    @State private var isSyncing = false
    @State private var showSyncSuccess = false
    @State private var isSaving = false
    @State private var isEditingAnyName = false
    @State private var isSavingMessage: String = "Saving Credentials..."
    @State private var showSuccessAlert = false
    @State private var successfulMessage: String = "Success"
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var showDeleteConfirmation = false
    @State private var connectionConfirmed: Bool = false
    @State private var pendingEdits: [UUID: PendingAccountEdit] = [:]
    
    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                if connectionConfirmed {
                    if !accounts.isEmpty {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(accounts) { account in
                                    ManageAccountRow(
                                        account: account,
                                        pendingEdit: Binding(
                                            get: { account.id.flatMap { pendingEdits[$0] } },
                                            set: { if let id = account.id { pendingEdits[id] = $0 } }
                                        ),
                                        isEditingName: $isEditingAnyName
                                    )
                                    .padding(.vertical, 10)
                                    
                                    if account != accounts.last {
                                        Divider()
                                    }
                                }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !isSaving && !isEditingAnyName { contentHeight = $0 + 50 } }
                        }
                        
                        HStack {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Text("Disconnect")
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .fontWeight(.bold)
                            }
                            .confirmationDialog(
                                {
                                    switch connectionType {
                                    case .simpleFin:
                                        return "Are you sure you want to disconnect your SimpleFIN account?"
                                    case .lunchFlow:
                                        return "Are you sure you want to disconnect your Lunch Flow account?"
                                    case .manual:
                                        return ""
                                    }
                                }(),
                                isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible,
                                actions: {
                                    Button("Remove", role: .destructive) { deleteCredential() }
                                    Button("Cancel", role: .cancel) {}
                                }
                            )
                            
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
                            .disabled(!hasUnsavedChanges)
                        }
                    } else {
                        EmptyAccountsView(connectionType: connectionType)
                            .padding(.top, 25)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 16) {
                        TextField(credentialFormConfig.placeholder, text: $credentialInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.primary)
                            .font(.system(size: 14))
                            .frame(height: 20)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        
                        Button(action: saveCredential) {
                            Text("Save")
                        }
                        .frame(maxWidth: .infinity, minHeight: 37)
                        .background(Color.appOrange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .fontWeight(.bold)
                        
                        if let url = credentialFormConfig.externalURL {
                            Button {
                                openURL(url)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(credentialFormConfig.externalButtonLabel)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                            .padding()
                            .frame(width: 320, height: 30)
                            .background(.clear)
                            .foregroundColor(Color.appOrange)
                            .cornerRadius(12)
                            .fontWeight(.medium)
                            .padding(.bottom, 20)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !isSaving { contentHeight = $0 } }
                }
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity)
            .toolbar {
                // Show a refresh button only when connected
                if (connectionType == .simpleFin || connectionType == .lunchFlow) && connectionConfirmed {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: triggerSync) {
                            ZStack {
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
                Text(successfulMessage)
            }
            .onAppear {
                // When view first appears, set this based on the current coredata state
                connectionConfirmed = credentialsSet
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            refreshToken = UUID()
        }
        
        // Overlay during saving
        if isSaving {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            ProgressView(isSavingMessage)
                .padding(16)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .tint(.white)
                .foregroundStyle(.white)
        }
    }
    
    // Saves the entered credential for the active connection type
    private func saveCredential() {
        guard let userID else { return }
        
        // Ensure that a credential was entered
        errorMessage = nil
        guard !credentialInput.isEmpty else {
            errorMessage = "Credentials required"
            showErrorAlert = true
            return
        }
        
        switch connectionType {
        case .simpleFin:
            isSavingMessage = "Connecting to SimpleFIN..."
        case .lunchFlow:
            isSavingMessage = "Connecting to Lunch Flow..."
        case .manual:
            isSavingMessage = "Saving account..."
        }
        
        isSaving = true
        
        // Optimistically write the flag to CoreData now so server and CoreData stay in sync
        // even if the view update later fails. Reverted below if the API call itself fails.
        do {
            switch connectionType {
            case .simpleFin:
                try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
            case .lunchFlow:
                try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: true, in: viewContext)
            case .manual:
                break
            }
        } catch {
            isSaving = false
            print("[BankConnectionView] Failed to write optimistic CoreData flag:", error)
            errorMessage = "Core Data error, please try again later"
            showErrorAlert = true
            return
        }
        
        Task {
            var response: APIModels.BankConnectionResponse?
            
            // Call out to the appropriate API to save the changes
            do {
                switch connectionType {
                case .simpleFin:
                    response = try await APIService.shared.connectSimpleFin(userID: userID, credential: credentialInput)
                    successfulMessage = "SimpleFIN account connected successfully!" // Set here, wont show up unless successful
                case .lunchFlow:
                    response = try await APIService.shared.connectLunchFlow(userID: userID, credential: credentialInput)
                    successfulMessage = "Lunch Flow account connected successfully!" // Set here, wont show up unless successful
                case .manual:
                    break
                }
                
                // Update the view to show newly connected accounts if successful, or error message
                await MainActor.run {
                    isSaving = false
                    
                    if response?.success == true {
                        // Save any returned accounts to CoreData
                        if let accounts = response?.accounts, !accounts.isEmpty {
                            // Convert Account objects to dictionaries
                            let accountsData = accounts.map { $0.toDictionary }
                            
                            do {
                                // Save accounts to CoreData
                                try CoreDataService.shared.saveBankConnectionAccounts(accountsData, forUserID: userID, in: viewContext)
                                // Alert User of successful connection
                                showSuccessAlert = true
                            } catch {
                                // Alert the user that although the connection went through successfully, there is an issue with parsing the returned accounts and saving them to coredata to display properly
                                switch connectionType {
                                case .simpleFin:
                                    errorMessage = "SimpleFIN account connection successful, but an error occurred saving the retrived bank accounts"
                                case .lunchFlow:
                                    errorMessage = "Lunch Flow account connection successful, but an error occurred saving the retrived bank accounts"
                                case .manual:
                                    break
                                }
                                showErrorAlert = true
                                print("[BankConnectionView] Failed to save Accounts to Core Data:", error)
                            }
                        } else {
                            // Alert User of successful connection
                            showSuccessAlert = true
                        }
                        
                        // Set the CoreData flag now that the server confirmed success
                        do {
                            switch connectionType {
                            case .simpleFin:
                                try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                            case .lunchFlow:
                                try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: true, in: viewContext)
                            case .manual:
                                break
                            }
                        } catch {
                            print("[BankConnectionView] Failed to update Core Data connection flag:", error)
                        }
                        
                        // Refresh authManager.currentUser and flip connectionConfirmed to switch the view to connected state
                        let fetchRequest = User.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
                        fetchRequest.fetchLimit = 1
                        if let updatedUser = try? viewContext.fetch(fetchRequest).first {
                            authManager.currentUser = updatedUser
                        }
                        connectionConfirmed = true
                        
                    } else {
                        // Revert the optimistic CoreData flag write since the server rejected the connection
                        do {
                            switch connectionType {
                            case .simpleFin:
                                try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                            case .lunchFlow:
                                try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: false, in: viewContext)
                            case .manual:
                                break
                            }
                        } catch {
                            print("[BankConnectionView] Failed to revert CoreData flag after connection failure:", error)
                        }
                        
                        switch connectionType {
                        case .simpleFin:
                            errorMessage = "Error connecting to SimpleFIN account: \(response?.message ?? "No error message returned")"
                        case .lunchFlow:
                            errorMessage = "Error connecting to Lunch Flow account: \(response?.message ?? "No error message returned")"
                        case .manual:
                            break
                        }
                        showErrorAlert = true
                        print("[BankConnectionView] Failed to connect to external provider:", response?.message ?? "No error message returned")
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    
                    // Revert the optimistic CoreData flag write since the API call threw an error
                    do {
                        switch connectionType {
                        case .simpleFin:
                            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                        case .lunchFlow:
                            try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: false, in: viewContext)
                        case .manual:
                            break
                        }
                    } catch {
                        print("[BankConnectionView] Failed to revert CoreData flag after connection error:", error)
                    }
                    
                    switch connectionType {
                    case .simpleFin:
                        errorMessage = "Error occurred while connecting to SimpleFIN: \(error.localizedDescription)"
                    case .lunchFlow:
                        errorMessage = "Error occurred while connecting to Lunch Flow: \(error.localizedDescription)"
                    case .manual:
                        break
                    }
                    showErrorAlert = true
                    print("[BankConnectionView] Failed to connect to external provider:", error.localizedDescription)
                }
            }
        }
    }
    
    // Deletes the entered credentials for the active connection type
    private func deleteCredential() {
        guard let userID else { return }
        
        switch connectionType {
        case .simpleFin:
            isSavingMessage = "Disconnecting SimpleFIN..."
        case .lunchFlow:
            isSavingMessage = "Disconnecting Lunch Flow..."
        case .manual:
            isSavingMessage = "Deleting account..."
        }
        
        // Update the flag in CoreData indicating credential status for the corresponding connection type, will be reverted later if a failure occurs in the server
        isSaving = true
        do {
            switch connectionType {
            case .simpleFin:
                try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: false, in: viewContext)
                successfulMessage = "SimpleFIN account disconnected successfully!" // Set here, wont show up unless successful
            case .lunchFlow:
                try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: false, in: viewContext)
                successfulMessage = "Lunch Flow account disconnected successfully!" // Set here, wont show up unless successful
            case .manual:
                break
            }
        } catch {
            isSaving = false
            print("[BankConnectionView] Failed to update Core Data:", error)
            errorMessage = "Core Data error, please try again later"
            showErrorAlert = true
            return
        }
        
        Task {
            do {
                var response: APIModels.GenericResponse?
                
                // Call out to appropriate API to save changes on server
                switch connectionType {
                case .simpleFin:
                    response = try await APIService.shared.disconnectSimpleFin(userID: userID)
                case .lunchFlow:
                    response = try await APIService.shared.disconnectLunchFlow(userID: userID)
                case .manual:
                    break
                }
                
                // Update view to approriate status after disconnecting accounts
                await MainActor.run {
                    isSaving = false
                    
                    if response?.success == true {
                        // Delete the disconnected accounts from CoreData (cascades to transactions)
                        do {
                            switch connectionType {
                            case .simpleFin:
                                try CoreDataService.shared.deleteAccounts(withSource: "SimpleFIN", in: viewContext)
                            case .lunchFlow:
                                try CoreDataService.shared.deleteAccounts(withSource: "Lunch Flow", in: viewContext)
                            case .manual:
                                break
                            }
                        } catch {
                            print("[BankConnectionView] Failed to delete accounts from Core Data:", error)
                        }
                        
                        showSuccessAlert = true
                        
                        // Refresh authManager.currentUser and flip connectionConfirmed to switch the view to disconnected state
                        let fetchRequest = User.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
                        fetchRequest.fetchLimit = 1
                        if let updatedUser = try? viewContext.fetch(fetchRequest).first {
                            authManager.currentUser = updatedUser
                        }
                        connectionConfirmed = false
                        
                    } else {
                        // Set corresponding connection flag in CoreData flag back to false after the connection failed
                        do {
                            switch connectionType {
                            case .simpleFin:
                                try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                            case .lunchFlow:
                                try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: true, in: viewContext)
                            case .manual:
                                break
                            }
                        } catch {
                            // Alert the user that there was an issue reverting the CoreData connection status after the disconnection returned an error
                            switch connectionType {
                            case .simpleFin:
                                errorMessage = "Error occurred while reverting connection status after failing to disconnect SimpleFIN"
                            case .lunchFlow:
                                errorMessage = "Error occurred while reverting connection status after failing to disconnect Lunch Flow"
                            case .manual:
                                break
                            }
                            showErrorAlert = true
                            print("[BankConnectionView] Failed to update Core Data:", error)
                        }
                        
                        switch connectionType {
                        case .simpleFin:
                            errorMessage = "Error disconnecting SimpleFIN account: \(response?.message ?? "No error message returned")"
                        case .lunchFlow:
                            errorMessage = "Error disconnecting Lunch Flow account: \(response?.message ?? "No error message returned")"
                        case .manual:
                            break
                        }
                        showErrorAlert = true
                        print("[BankConnectionView] Failed to disconnect from external provider:", response?.message ?? "No error message returned")
                    }
                }
            } catch {
                // If the call to the APIService errored, ensure that CoreData connection status flags are reverted
                await MainActor.run {
                    isSaving = false
                    
                    // Revert Core Data flag back to true since API failed
                    do {
                        switch connectionType {
                        case .simpleFin:
                            try CoreDataService.shared.updateUserSimpleFinStatus(userID: userID, simpleFinCredentialsSet: true, in: viewContext)
                        case .lunchFlow:
                            try CoreDataService.shared.updateUserLunchFlowStatus(userID: userID, lunchFlowCredentialsSet: true, in: viewContext)
                        case .manual:
                            break
                        }
                    } catch {
                        // Alert the user that after an error occurred trying to disconnect the account, an error also occurred while reverting the connection status flag
                        switch connectionType {
                        case .simpleFin:
                            errorMessage = "Error occurred while reverting connection status after error also occurred while disconnecting SimpleFIN"
                        case .lunchFlow:
                            errorMessage = "Error occurred while reverting connection status after error also occurred while disconnecting Lunch Flow"
                        case .manual:
                            break
                        }
                        showErrorAlert = true
                        print("[BankConnectionView] Failed to update Core Data:", error)
                    }
                    
                    // Alert the user that an error occurred trying to disconnect the account
                    switch connectionType {
                    case .simpleFin:
                        errorMessage = "Error occurred while disconnecting SimpleFIN"
                    case .lunchFlow:
                        errorMessage = "Error occurred while disconnecting Lunch Flow"
                    case .manual:
                        break
                    }
                    showErrorAlert = true
                    print("[BankConnectionView] Failed to disconnect from external provider:", error.localizedDescription)
                }
            }
        }
    }

    // Sends pending edits to the server, and saves to Core Data on success
    private func saveAllChanges() {
        isSaving = true

        var accountsToUpdate: [APIModels.Account] = []
        var editsToApply: [(account: Account, name: String, accountType: String)] = []

        for account in accounts {
            guard let id = account.id, let edit = pendingEdits[id] else { continue }
            let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (account.name ?? "") : trimmedName

            editsToApply.append((account: account, name: finalName, accountType: edit.accountType))
            accountsToUpdate.append(APIModels.Account(
                id: id,
                externalID: account.externalID ?? "",
                name: finalName,
                bank: account.bank ?? "",
                accountSource: account.accountSource,
                accountNumber: account.accountNumber,
                availableBalance: account.availableBalance?.doubleValue ?? 0,
                balance: account.balance?.doubleValue ?? 0,
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
                _ = try await APIService.shared.updateAccountInfo(userID: userUUID, token: token, accounts: accountsToUpdate)
                print("[BankConnectionView] Server sync complete for \(accountsToUpdate.count) accounts")

                for edit in editsToApply {
                    edit.account.name = edit.name
                    edit.account.accountType = edit.accountType
                    edit.account.updatedAt = Date()
                }
                if viewContext.hasChanges {
                    try viewContext.save()
                    print("[BankConnectionView] Core Data saved \(editsToApply.count) account edits")
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

    // Triggers a sync from Bank Connection > AzureDB > Application
    private func triggerSync() {
        isSyncing = true
        
        isSavingMessage = "Saving account edits..."

        Task {
            do {
                await authManager.refreshData()

                await MainActor.run {
                    isSyncing = false
                    showSyncSuccess = true
                }

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

// Displayed when there are no accounts to display
struct EmptyAccountsView: View {
    @Environment(\.openURL) private var openURL
    let connectionType: BankConnectionDestination
    
    private var displayParams: (text: String, externalURL: URL?, externalButtonLabel: String) {
        switch connectionType {
        case .simpleFin:
            return ("Login to your connected SimpleFIN account to connect your banks",
                    URL(string: "https://www.beta-bridge.simplefin.org"),
                    "Open SimpleFIN Bridge")
        case .lunchFlow:
            return ("Login to your connected Lunch Flow account to connect your banks",
                    URL(string: "https://www.lunchflow.app/dashboard"),
                    "Open Lunch Flow Dashboard")
        case .manual:
            return ("", nil, "")
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            
            Image(systemName: "creditcard.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.3))
            
            Text("No Accounts")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            
            Text(displayParams.text)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            
            if (displayParams.externalURL != nil) && (connectionType == .simpleFin || connectionType == .lunchFlow) {
                Button {
                    openURL(displayParams.externalURL!)
                } label: {
                    HStack(spacing: 8) {
                        Text(displayParams.externalButtonLabel)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding()
                .frame(width: 320, height: 30)
                .background(.clear)
                .foregroundColor(Color.appOrange)
                .cornerRadius(12)
                .fontWeight(.medium)
                .padding(.bottom, 20)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The view to display each connected account
struct ManageAccountRow: View {
    @ObservedObject var account: Account
    @Binding var pendingEdit: PendingAccountEdit?
    @Binding var isEditingName: Bool

    @State private var editingName: String = ""
    @State private var isEditingNameLocal = false
    @FocusState private var isNameFieldFocused: Bool
    @State private var showTypePicker = false
    @State private var buttonGlobalY: CGFloat = 0

    // The screen's vertical midpoint, used to decide which way the type picker popover opens
    private var screenMidY: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.midY ?? 400
    }

    // The AccountName that is displayed in the row (before saving)
    private var displayName: String {
        pendingEdit?.name ?? account.name ?? ""
    }

    // The AccountType that is displayed in the row (before saving)
    private var displayAccountType: String {
        pendingEdit?.accountType ?? account.accountType ?? "-"
    }

    private var accountTypeColor: Color {
        switch displayAccountType {
        case "Hide":       return .gray
        case "Cash":       return .green
        case "Credit":     return .orange
        case "Investment": return .blue
        case "Loan":       return .red
        case "Other":      return .purple
        default:           return .gray
        }
    }

    var body: some View {
        HStack() {
            // Display corresponding Bank Logo
            Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 35, height: 35)
                .clipShape(Circle())

            // Display the account name, edit button, number, and time since last update
            VStack(alignment: .leading, spacing: 3) {
                
                // Display name and edit button
                HStack() {
                    if isEditingNameLocal {
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
                        HStack {
                            Text(displayName.isEmpty ? "Unknown Account" : displayName)
                                .fontWeight(.bold)
                                .font(.system(size: 16))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Button(action: {
                                editingName = displayName
                                isEditingNameLocal = true
                                isEditingName = true
                                isNameFieldFocused = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 16))
                                    .foregroundColor(.appPurple)
                                    .frame(width: 21, height: 21)
                            }
                        }
                    }
                }
                
                // Display the account number if available, and the time since last update
                HStack {
                    if let accountNumber = account.accountNumber, !accountNumber.isEmpty {
                        Text("•••• \(accountNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                    }
                    
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                        Text(timeSinceLastUpdate(from: account.balanceDate))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Display the drop down to choose the acount type
            Button {
                showTypePicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(displayAccountType)
                        .font(.system(size: 15))
                        .animation(nil, value: displayAccountType)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(accountTypeColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(accountTypeColor)
                .fontWeight(.bold)
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).midY
            } action: {
                buttonGlobalY = $0
            }
            .popover(isPresented: $showTypePicker, arrowEdge: buttonGlobalY > screenMidY ? .bottom : .top) {
                let types = ["Hide", "Cash", "Credit", "Investment", "Loan", "Other"]
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(types, id: \.self) { type in
                        if type != types.first {
                            Divider()
                        }
                        Button {
                            if pendingEdit == nil {
                                pendingEdit = PendingAccountEdit(name: displayName, accountType: type)
                            } else {
                                pendingEdit?.accountType = type
                            }
                            showTypePicker = false
                        } label: {
                            HStack {
                                Text(type)
                                    .foregroundStyle(displayAccountType == type ? Color.appOrange : .primary)
                                    .fontWeight(displayAccountType == type ? .semibold : .regular)
                                Spacer()
                                if displayAccountType == type {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.appOrange)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 160)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    // Create a pending name change
    private func commitNameEdit() {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingNameLocal = false
            isEditingName = false
            return
        }
        if pendingEdit == nil {
            pendingEdit = PendingAccountEdit(name: trimmed, accountType: displayAccountType)
        } else {
            pendingEdit?.name = trimmed
        }
        isEditingNameLocal = false
        isEditingName = false
    }
}

// Wraps any row content with a swipe-left-to-reveal-delete gesture
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var currentOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    private let revealWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            // Only render the delete button when fully open and not mid-drag
            if currentOffset <= -revealWidth && !isDragging {
                Button(role: .destructive) {
                    withAnimation(.spring(response: 0.3)) { currentOffset = 0 }
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(width: revealWidth)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }

            // Row content slides left to reveal the button
            content()
                .background(Color.clear)
                .contentShape(Rectangle())
                .offset(x: currentOffset)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if !isDragging {
                                isDragging = true
                                dragStartOffset = currentOffset
                            }
                            currentOffset = max(-revealWidth, min(0, dragStartOffset + value.translation.width))
                        }
                        .onEnded { value in
                            isDragging = false
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            withAnimation(.spring(response: 0.3)) {
                                currentOffset = currentOffset < -(revealWidth / 2) ? -revealWidth : 0
                            }
                        }
                )
        }
        .clipped()
    }
}

#Preview("Settings - W/ Conn & Accounts") {
    return SettingsView()
        .environmentObject(PersistenceController.previewAuthManager())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Settings - W/ Conn But No Accounts") {
    return SettingsView()
        .environmentObject(PersistenceController.previewConnectedNoAccountsAuthManager())
        .environment(\.managedObjectContext, PersistenceController.previewConnectedNoAccounts.container.viewContext)
}

#Preview("Settings - W/O Conn or Accounts") {
    return SettingsView()
        .environmentObject(PersistenceController.previewEmptyAuthManager())
        .environment(\.managedObjectContext, PersistenceController.previewEmpty.container.viewContext)
}
