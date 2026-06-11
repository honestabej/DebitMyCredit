import SwiftUI
import CoreData

struct TransactionView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    
    var transaction: Transaction

    @State private var editedNote: String = ""
    @State private var hasUnsavedNoteChanges: Bool = false
    @State private var isSavingNote: Bool = false
    @State private var noteIsLoaded: Bool = false

    @State private var selectedGroup: TransferGroup? = nil
    @State private var hasGroupChange: Bool = false
    @State private var showGroupPicker: Bool = false
    @State private var groupButtonGlobalY: CGFloat = 0

    var body: some View {
        let bankColor = getBankColor(bankName: transaction.account?.bank?.lowercased() ?? "")
        let bankLogo = getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? "")
        
        ZStack(alignment: .top) {
            Color.lightBackground.ignoresSafeArea()
            
            // Gradient background: bank color at top, fading to clear ~25% down
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: bankColor.opacity(0.85), location: 0),
                        .init(color: bankColor.opacity(0), location: 0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 900)
                .ignoresSafeArea()
            }
            
            VStack() {
                // Transaction name
                HStack {
                    Image(bankLogo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                    
                    Text(transaction.name ?? "")
                        .fontWeight(.heavy)
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(transaction.isOrphaned)
                }
                .padding(.horizontal, 5)
                .padding(.top, 25)
                
                // Transaction amount
                let displayAmount = transaction.amount
                let isUnpaid = transaction.account?.accountType == "Credit"
                    && (transaction.amount?.decimalValue ?? 0) < 0
                    && (transaction.transferGroup == nil || transaction.transferGroup?.completed == false)
                Text(displayAmount.map {
                    $0.decimalValue as Decimal
                } .map {
                    $0.formatted(.currency(code: "USD"))
                } ?? "")
                .fontWeight(.bold)
                .font(.system(size: 45))
                .scaleEffect(x: 1.0, y: 1.05, anchor: .center)
                .foregroundStyle(isUnpaid ? Color.appOrange.opacity(0.8) : .primary)
                .strikethrough(transaction.isOrphaned)
                //                .padding(.top, 5)
                
                // Transaction date
                Text(!transaction.pending ? transaction.transactionDate.map { $0.formatted(.dateTime.month(.wide).day().year()) } ?? "" : "Pending")
                    .font(.subheadline)
                
                TextField("Add Note", text: $editedNote, axis: .vertical)
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 15)
                    .fontWeight(.semibold)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onChange(of: editedNote) { _, _ in
                        if noteIsLoaded { hasUnsavedNoteChanges = true }
                    }

                if hasUnsavedNoteChanges {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.appOrange)
                            .frame(width: 6, height: 6)
                        Text(isSavingNote ? "Saving..." : "Dismiss to save changes")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.top, 2)
                }
                
                // Only display the payment group and allocation logic for credit card transactions
                if (transaction.account?.accountType == "Credit" && (transaction.amount?.decimalValue ?? 0) < 0) {
                    let screenMidY: CGFloat = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.midY ?? 400

                    if !transaction.isOrphaned {
                        HStack {
                            Text("Payment Group: ")
                            
                            Button {
                                showGroupPicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(selectedGroup?.name ?? "None")
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12))
                                }
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .onGeometryChange(for: CGFloat.self) {
                                $0.frame(in: .global).midY
                            } action: {
                                groupButtonGlobalY = $0
                            }
                            .popover(isPresented: $showGroupPicker, arrowEdge: groupButtonGlobalY > screenMidY ? .bottom : .top) {
                                let groups: [TransferGroup] = {
                                    guard let userID = authManager.currentUser?.id else { return [] }
                                    return CoreDataService.shared.fetchTransferGroups(forUserID: userID, in: viewContext)
                                }()
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        // "None" option to deselect
                                        Button {
                                            if selectedGroup != nil {
                                                selectedGroup = nil
                                                hasGroupChange = true
                                            }
                                            showGroupPicker = false
                                        } label: {
                                            HStack {
                                                Text("None")
                                                    .foregroundStyle(selectedGroup == nil ? Color.appOrange : .primary)
                                                    .fontWeight(selectedGroup == nil ? .semibold : .regular)
                                                Spacer()
                                                if selectedGroup == nil {
                                                    Image(systemName: "checkmark")
                                                        .foregroundStyle(Color.appOrange)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        
                                        ForEach(groups) { group in
                                            Divider()
                                            Button {
                                                if selectedGroup?.id == group.id {
                                                    selectedGroup = nil
                                                } else {
                                                    selectedGroup = group
                                                }
                                                hasGroupChange = true
                                                showGroupPicker = false
                                            } label: {
                                                HStack {
                                                    Text(group.name ?? "")
                                                        .foregroundStyle(selectedGroup?.id == group.id ? Color.appOrange : .primary)
                                                        .fontWeight(selectedGroup?.id == group.id ? .semibold : .regular)
                                                    Spacer()
                                                    if selectedGroup?.id == group.id {
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
                                }
                                .frame(minWidth: 200)
                                .presentationCompactAdaptation(.popover)
                            }
                        }
                        .padding(.top, 7)
                        .padding(.horizontal, 15)
                        

                    } else {
                        VStack(alignment: .center, spacing: 5) {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.orange)
                                Text("Transaction No Longer Exists")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            Text("This was likely replaced after posting and can be safely deleted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                            
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    AllocationSectionView(transaction: transaction)
                }
            }
        }
        .onAppear {
            editedNote = transaction.notes ?? ""
            selectedGroup = transaction.transferGroup
            DispatchQueue.main.async { noteIsLoaded = true }
        }
        .onDisappear {
            if hasUnsavedNoteChanges {
                saveNote()
            }
            if hasGroupChange {
                saveTransferGroup()
            }
        }
    }

    private func saveTransferGroup() {
        guard let token = KeychainHelper.get("auth_token"),
              let txID = transaction.id?.uuidString else { return }

        let previousGroup = transaction.transferGroup
        transaction.transferGroup = selectedGroup
        try? viewContext.save()

        Task {
            do {
                let _ = try await APIService.shared.updateTransactionTransferGroup(
                    transactionID: txID,
                    transferGroupID: selectedGroup?.id,
                    token: token
                )
                print("[TransactionView] Transfer group saved to server")
            } catch {
                print("[TransactionView] Failed to save transfer group, reverting: \(error.localizedDescription)")
                await MainActor.run {
                    transaction.transferGroup = previousGroup
                    try? viewContext.save()
                }
            }
        }
    }

    private func saveNote() {
        guard let token = KeychainHelper.get("auth_token"),
              let txID = transaction.id?.uuidString else { return }

        let previousNote = transaction.notes
        isSavingNote = true
        transaction.notes = editedNote
        try? viewContext.save()

        Task {
            do {
                let _ = try await APIService.shared.updateTransactionNote(
                    transactionID: txID,
                    notes: editedNote,
                    token: token
                )
                print("[TransactionView] Note saved to server")
                await MainActor.run {
                    isSavingNote = false
                    hasUnsavedNoteChanges = false
                }
            } catch {
                print("[TransactionView] Failed to save note to server, reverting: \(error.localizedDescription)")
                await MainActor.run {
                    transaction.notes = previousNote
                    try? viewContext.save()
                    isSavingNote = false
                    hasUnsavedNoteChanges = true
                }
            }
        }
    }
}

// Allocation - fetches cash accounts to allocate this transaction against
struct AllocationSectionView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authManager: AuthManager

    var transaction: Transaction

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType == %@", "Cash"),
        animation: .default
    )
    private var cashAccounts: FetchedResults<Account>

    // Keyed by account objectID string
    @State private var checkedIDs: Set<String> = []
    @State private var amounts: [String: String] = [:]
    @State private var userEditedIDs: Set<String> = []
    @State private var hasUnsavedChanges: Bool = false
    @State private var isSaving: Bool = false

    private var totalCents: Int {
        let d = abs(transaction.amount?.doubleValue ?? 0)
        return Int((d * 100).rounded())
    }

    private var allocatedCents: Int {
        checkedIDs.reduce(0) { sum, key in
            sum + Int(((Double(amounts[key] ?? "") ?? 0) * 100).rounded())
        }
    }

    private var hasMismatch: Bool {
        !checkedIDs.isEmpty && allocatedCents != totalCents
    }

    var body: some View {
        VStack(spacing: 0) {
            // Allocation mismatch error
            if hasMismatch {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appRed)
                        .font(.caption)
                    Text("Allocations must equal transaction total")
                        .font(.caption)
                        .foregroundStyle(Color.appRed)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if hasUnsavedChanges {
                // Unsaved changes indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.appOrange)
                        .frame(width: 6, height: 6)
                    Text(isSaving ? "Saving..." : "Dismiss to save changes")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(cashAccounts) { account in
                        let key = account.objectID.uriRepresentation().absoluteString
                        AllocationRow(
                            account: account,
                            isChecked: checkedIDs.contains(key),
                            amount: amounts[key] ?? "",
                            isUserEdited: userEditedIDs.contains(key),
                            onToggle: { handleToggle(key: key) },
                            onEdit: { newValue in handleEdit(key: key, newValue: newValue) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            loadExistingAllocations()
        }
        .onDisappear {
            if hasUnsavedChanges {
                saveAllocations()
            }
        }
    }

    private func loadExistingAllocations() {
        let existing = transaction.allocations?.allObjects as? [TransactionAllocation] ?? []
        guard !existing.isEmpty else { return }

        for alloc in existing {
            guard let account = alloc.account,
                  let amount = alloc.amount else { continue }
            let key = account.objectID.uriRepresentation().absoluteString
            checkedIDs.insert(key)
            amounts[key] = String(format: "%.2f", abs(amount.doubleValue))
            // Pre-populated amounts are not user-edited (shown in grey)
        }
    }

    func saveAllocations() {
        // Build list of (account, amount) pairs for checked accounts with valid amounts
        var pairs: [(account: Account, amount: Double)] = []
        for account in cashAccounts {
            let key = account.objectID.uriRepresentation().absoluteString
            guard checkedIDs.contains(key),
                  let amountStr = amounts[key],
                  let amount = Double(amountStr),
                  amount > 0 else { continue }
            pairs.append((account: account, amount: amount))
        }

        // Validate that allocations sum to the transaction total
        if hasMismatch {
            hasUnsavedChanges = false
            return
        }

        isSaving = true

        // 1. Save to CoreData immediately, capturing the revert closure
        do {
            let (entries, revert) = try CoreDataService.shared.saveAllocations(
                for: transaction,
                allocations: pairs,
                context: viewContext
            )

            // 2. Fire server call in the background
            guard let token = KeychainHelper.get("auth_token"),
                  let txID = transaction.id?.uuidString else {
                isSaving = false
                hasUnsavedChanges = false
                return
            }

            Task {
                do {
                    let _ = try await APIService.shared.saveAllocations(
                        transactionID: txID,
                        allocations: entries,
                        token: token
                    )
                    print("[AllocationSectionView] Allocations saved to server")
                    await MainActor.run {
                        isSaving = false
                        hasUnsavedChanges = false
                    }
                } catch {
                    print("[AllocationSectionView] Server save failed, reverting CoreData: \(error.localizedDescription)")
                    // Revert CoreData back to the previous state
                    do {
                        try revert()
                    } catch {
                        print("[AllocationSectionView] Failed to revert CoreData: \(error.localizedDescription)")
                    }
                    await MainActor.run {
                        isSaving = false
                        hasUnsavedChanges = true  // Keep dirty so user can retry on next dismiss
                        authManager.allocationSaveError = "Failed to save allocations to server. Changes have been reverted. Please try again."
                    }
                }
            }
        } catch {
            print("[AllocationSectionView] Failed to save allocations to CoreData: \(error.localizedDescription)")
            isSaving = false
        }
    }

    private func handleToggle(key: String) {
        if checkedIDs.contains(key) {
            checkedIDs.remove(key)
            amounts[key] = ""
            userEditedIDs.remove(key)
        } else {
            checkedIDs.insert(key)
        }
        redistributeAmounts()
        hasUnsavedChanges = true
    }

    private func handleEdit(key: String, newValue: String) {
        amounts[key] = newValue
        userEditedIDs.insert(key)
        redistributeRemaining(editedKey: key)
        hasUnsavedChanges = true
    }

    // Split total evenly across all checked accounts, ignoring user-edited ones
    private func redistributeAmounts() {
        let checked = Array(checkedIDs)
        guard !checked.isEmpty else { return }

        // Clear user-edit flags for unchecked accounts
        userEditedIDs = userEditedIDs.filter { checkedIDs.contains($0) }

        let nonEditedKeys = checked.filter { !userEditedIDs.contains($0) }
        guard !nonEditedKeys.isEmpty else { return }

        // Sum up what user-edited fields are using
        let editedCents = userEditedIDs.reduce(0) { sum, k in
            sum + centsFromString(amounts[k] ?? "")
        }
        let remainingCents = max(0, totalCents - editedCents)

        // Divide remaining evenly, give extra cent to first bucket
        let share = remainingCents / nonEditedKeys.count
        let remainder = remainingCents % nonEditedKeys.count

        for (index, k) in nonEditedKeys.enumerated() {
            let cents = share + (index == 0 ? remainder : 0)
            amounts[k] = formattedAmount(cents: cents)
        }
    }

    // After a manual edit, redistribute remaining to non-edited checked accounts
    private func redistributeRemaining(editedKey: String) {
        let nonEditedKeys = Array(checkedIDs).filter { !userEditedIDs.contains($0) }
        guard !nonEditedKeys.isEmpty else { return }

        let editedCents = userEditedIDs.reduce(0) { sum, k in
            sum + centsFromString(amounts[k] ?? "")
        }
        let remainingCents = max(0, totalCents - editedCents)

        let share = remainingCents / nonEditedKeys.count
        let remainder = remainingCents % nonEditedKeys.count

        for (index, k) in nonEditedKeys.enumerated() {
            let cents = share + (index == 0 ? remainder : 0)
            amounts[k] = formattedAmount(cents: cents)
        }
    }

    private func centsFromString(_ s: String) -> Int {
        Int(((Double(s) ?? 0) * 100).rounded())
    }

    private func formattedAmount(cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }
}

struct AllocationRow: View {
    var account: Account
    var isChecked: Bool
    var amount: String
    var isUserEdited: Bool
    var onToggle: () -> Void
    var onEdit: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: 23))
                .foregroundStyle(isChecked ? Color.appOrange : Color.secondary)
                .onTapGesture { onToggle() }

            Text(account.name ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 18))

            Spacer()
            Text("$")
                .fontWeight(.bold)
                .font(.system(size: 22))
                .foregroundStyle(isChecked ? Color.primary : Color.secondary)
            TextField("", text: Binding(
                get: { amount },
                set: { newValue in
                    // Only report edits when the user is actively typing
                    if isFocused {
                        onEdit(newValue)
                    }
                }
            ))
                .scrollContentBackground(.hidden)
                .foregroundStyle(isUserEdited ? Color.primary : Color.secondary)
                .font(.system(size: 14))
                .frame(width: 75, height: 17)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isChecked ? Color(.secondarySystemFill) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .keyboardType(.decimalPad)
                .disabled(!isChecked)
                .focused($isFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}


#Preview("Transactions") {
    let context = PersistenceController.preview.container.viewContext
    return TransactionsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Transaction") {
    let context = PersistenceController.preview.container.viewContext
    
    // Make account
    let checking = Account(context: context)
    checking.id = UUID()
    checking.externalID = "act1"
    checking.name = "Chase Sapphire"
    checking.bank = "Chase Bank"
    checking.accountType = "Credit"
    checking.accountNumber = "1234"
    checking.accountSource = "SimpleFIN"
    checking.availableBalance = NSDecimalNumber(value: 1234.56)
    checking.balance = NSDecimalNumber(value: 1234.56)
    checking.balanceDate = Date()
    checking.accountColor = CoreDataService.randomAccountColor()
    
    // Transfer group
    let tg1 = TransferGroup(context: context)
    tg1.id = UUID()
    tg1.name = "Payment 3"
    tg1.createdAt = Date()
    
    // Make transaction
    let tx = Transaction(context: context)
    tx.id = UUID()
    tx.externalID = "txid"
    tx.name = "North Italia Scottsdale"
    tx.amount = NSDecimalNumber(value: -122.94)
    tx.transactionDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
    tx.pending = false
    tx.account = checking
    tx.notes = "NORTH ITALIA SCOTTSDALE #580TF3"
    tx.transferGroup = tg1
    
    return TransactionView(transaction: tx)
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}
