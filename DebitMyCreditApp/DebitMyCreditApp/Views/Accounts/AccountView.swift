import SwiftUI
import CoreData
import Combine

struct AccountView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @ObservedObject var account: Account

    init(account: Account) {
        self._account = ObservedObject(wrappedValue: account)
    }

    typealias TransactionRow = (transaction: Transaction, allocatedAmount: NSDecimalNumber?)

    /// All transactions: direct on this account plus allocated from other accounts.
    private var allTransactionRows: [TransactionRow] {
        let direct = (account.transactions as? Set<Transaction> ?? [])
            .map { (transaction: $0, allocatedAmount: nil as NSDecimalNumber?) }

        let allocated = (account.allocations as? Set<TransactionAllocation> ?? [])
            .compactMap { allocation -> TransactionRow? in
                guard let txn = allocation.transaction, txn.account != account else { return nil }
                return (transaction: txn, allocatedAmount: allocation.amount)
            }

        return (direct + allocated).sorted {
            ($0.transaction.transactionDate ?? .distantPast) > ($1.transaction.transactionDate ?? .distantPast)
        }
    }

    /// Pending transactions, shown at the top regardless of date.
    private var pendingRows: [TransactionRow] {
        allTransactionRows.filter { $0.transaction.pending }
    }

    /// Non-pending transactions grouped by calendar day, newest day first.
    private var settledRowsByDay: [(day: Date, rows: [TransactionRow])] {
        let calendar = Calendar.current
        let settled = allTransactionRows.filter { !$0.transaction.pending }
        let grouped = Dictionary(grouping: settled) { row -> Date in
            let date = row.transaction.transactionDate ?? .distantPast
            return calendar.startOfDay(for: date)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, rows: $0.value) }
    }

    @State private var showBalanceBreakdown = false
    @State private var showAddTransaction = false

    var body: some View {
        let acctBalDate = account.balanceDate?.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute()) ?? "Unknown"
        let bankColor = getBankColor(bankName: account.bank?.lowercased() ?? "")
        
        ZStack(alignment: .top) {
            Color.lightBackground.ignoresSafeArea()
            
            // Gradient background: bank color at top, fading to clear ~25% down
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        // TODO: Implement chart
//                        .init(color: bankColor.opacity(0.85), location: 0),
//                        .init(color: bankColor.opacity(0), location: 0.35)
                        .init(color: bankColor.opacity(0.75), location: 0),
                        .init(color: bankColor.opacity(0), location: 0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height)
                .ignoresSafeArea()
            }
            
            VStack() {
                // Account name
                HStack {
                    Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
//                        .padding(.top, 10) // TODO: Remove after chart implemented
                    
                    Text(account.name ?? "")
                        .fontWeight(.heavy)
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    if let acctNum = account.accountNumber {
                        Text("...\(acctNum)")
                            .fontWeight(.medium)
                            .font(.system(size: 12))
                            .padding(.top, 3)
                    }
                }
                
                // TODO: Implement Chart
//                AccountBalanceHistoryChart()
//                    .frame(height: 210)
         
                HStack() {
                    Spacer()
                    
                    let rawBalance = (account.accountType == "Cash" ? account.availableBalance : account.balance)?.decimalValue as Decimal? ?? 0
                    let unpaid = account.unpaidTransactionsOfAccount(account: account).decimalValue as Decimal
                    let adjustedBalance = rawBalance - unpaid
                    HStack(alignment: .top, spacing: 4) {
                        VStack(spacing: 2) {
                            Text(adjustedBalance.formatted(.currency(code: "USD")))
                                .font(.system(size: 25))
                                .fontWeight(.bold)
                            Text(account.accountType == "Credit" || account.accountType == "Loan" ? "Balance" : "Available")
                                .font(.system(size: 13))
                                .fontWeight(.semibold)
                                .foregroundColor(.gray)
                        }
                        if account.accountType == "Cash" {
                            Button(action: { showBalanceBreakdown = true }) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .popover(isPresented: $showBalanceBreakdown, arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Breakdown")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    Divider()
                                    HStack {
                                        Text("Posted bank balance:")
                                        Spacer()
                                        Text(rawBalance.formatted(.currency(code: "USD")))
                                    }
                                    HStack {
                                        Text("Unpaid transactions:")
                                        Spacer()
                                        Text("- \(unpaid.formatted(.currency(code: "USD")))")
                                            .foregroundStyle(unpaid > 0 ? Color.appOrange : .primary)
                                    }
                                    Divider()
                                    HStack {
                                        Text("Available balance:")
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(adjustedBalance.formatted(.currency(code: "USD")))
                                            .fontWeight(.semibold)
                                    }
                                }
                                .font(.system(size: 13))
                                .padding(14)
                                .frame(minWidth: 260)
                                .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(.top, 1)
                
                Text("Last update received at \(acctBalDate)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
                
                Text("Transactions: ")
                    .padding(.leading, 10)
                    .padding(.top, 3)
                    .padding(.bottom, -10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 20))
                    .fontWeight(.semibold)
                
                // Transactions table
                transactionsList
                
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            
            // Button to create a new transaction — pinned bottom-right above tab bar
            if account.accountSource == "Manual" {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showAddTransaction = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 60, height: 60)
                        .glassEffect(.clear.tint(getBankColor(bankName: account.bank ?? "Manual")), in: .rect(cornerRadius: 50))
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 1, y: 4)
                        .opacity(showAddTransaction ? 0 : 1)
                        .sheet(isPresented: $showAddTransaction) {
                            NavigationStack {
                                newTransactionView
                            }
                            .presentationDetents([.height(290)])
                            .presentationDragIndicator(.visible)
                        }
                        
                    }
                }
            }
        }
    }
    
    private var transactionsList: some View {
        List {
            // Remove default top padding of list
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets(top: -20, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.lightBackground)
                .listRowSeparator(.hidden)

            // Pending section — always at top
            if !pendingRows.isEmpty {
                Section {
                    ForEach(pendingRows, id: \.transaction.objectID) { row in
                        TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount, dbtAcct: account)
                            .padding(.horizontal, 18)
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 10)
                            .listRowBackground(Color.lightBackground)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if account.accountSource == "Manual" && row.allocatedAmount == nil {
                                    Button(role: .destructive) {
                                        deleteTransaction(row.transaction)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                } header: {
                    VStack(spacing: 0) {
                        Text("Pending")
                            .font(.system(size: 15))
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        Divider()
                    }
                    .listRowInsets(EdgeInsets())
                    .background(Color.lightBackground)
                    .padding(.horizontal, 15)
                }
            }

            // Settled transactions grouped by day
            ForEach(settledRowsByDay, id: \.day) { group in
                Section {
                    ForEach(group.rows, id: \.transaction.objectID) { row in
                        TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount, dbtAcct: account)
                            .padding(.horizontal, 18)
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 10)
                            .listRowBackground(Color.lightBackground)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if account.accountSource == "Manual" && row.allocatedAmount == nil {
                                    Button(role: .destructive) {
                                        deleteTransaction(row.transaction)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                } header: {
                    VStack(spacing: 0) {
                        Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                            .font(.system(size: 15))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        Divider()
                    }
                    .listRowInsets(EdgeInsets())
                    .background(Color.lightBackground)
                    .padding(.horizontal, 15)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .onAppear {
            UITableView.appearance().sectionHeaderTopPadding = 1000
        }
    }


    private func deleteTransaction(_ transaction: Transaction) {
        guard let txnID = transaction.id,
              let token = KeychainHelper.get("auth_token") else { return }

        // Snapshot for revert
        let snapshot = transaction

        viewContext.delete(transaction)
        try? viewContext.save()

        Task {
            do {
                _ = try await APIService.shared.deleteTransaction(id: txnID, token: token)
            } catch {
                await MainActor.run {
                    // Revert: re-insert the transaction
                    let restored = Transaction(context: viewContext)
                    restored.id = snapshot.id
                    restored.externalID = snapshot.externalID
                    restored.name = snapshot.name
                    restored.amount = snapshot.amount
                    restored.notes = snapshot.notes
                    restored.transactionDate = snapshot.transactionDate
                    restored.pending = snapshot.pending
                    restored.createdAt = snapshot.createdAt
                    restored.updatedAt = snapshot.updatedAt
                    restored.account = account
                    restored.user = snapshot.user
                    try? viewContext.save()
                }
            }
        }
    }
    
    private var newTransactionView: some View {
        NewTransactionView(account: account)
    }
}

private struct NewTransactionView: View {
    let account: Account

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var transactionName: String = ""
    @State private var transactionAmount: String = ""
    @State private var transactionDate: Date = Date()
    @State private var transactionNote: String = ""
    @State private var isCompleting: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 12) {
            Text("New Transaction")
                .font(.title3)
                .fontWeight(.bold)
            
            TextField("Transaction Name", text: $transactionName)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.primary)
                .font(.system(size: 14))
                .frame(height: 20)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .center) {
                Text("$")
                    .font(.system(size: 20))
                    .fontWeight(.semibold)
                TextField("Amount", text: $transactionAmount)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.primary)
                    .font(.system(size: 14))
                    .frame(height: 20)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .frame(width: 150)
                    .keyboardType(.numberPad)
                    .onChange(of: transactionAmount) { _, newValue in
                        let digits = newValue.filter { $0.isNumber }
                        transactionAmount = String(digits.prefix(4))
                    }

                Spacer()
                
                Text("On: ")
                    .font(.system(size: 20))
                    .fontWeight(.semibold)
                ZStack(alignment: .center) {
                    // Styled button background — displays the selected date
                    HStack(spacing: 4) {
                        Text(transactionDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.system(size: 16, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)

                    // Invisible picker sits on top to handle taps
                    DatePicker("", selection: $transactionDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .colorMultiply(.clear)
                }
                .fixedSize()
            }
            
            
            TextField("Add Note", text: $transactionNote, axis: .vertical)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.primary)
                .font(.system(size: 14))
                .lineLimit(3...3)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            
            Button {
                saveTransaction()
            } label: {
                Group {
                    if isCompleting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Save Transaction")
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .disabled(isCompleting)
            .glassEffect(.clear.tint(.appOrange), in: .rect(cornerRadius: 50))
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .padding(.horizontal, 17)
        .padding(.top, 25)
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong")
        }
    }

    private func saveTransaction() {
        let trimmedName = transactionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Transaction name is required"
            showErrorAlert = true
            return
        }
        guard let amount = Double(transactionAmount), amount > 0 else {
            errorMessage = "Please enter a valid amount"
            showErrorAlert = true
            return
        }
        guard let accountID = account.id,
              let userID = authManager.currentUser?.id,
              let token = KeychainHelper.get("auth_token") else {
            errorMessage = "Not logged in"
            showErrorAlert = true
            return
        }

        isCompleting = true
        let newID = UUID()
        let now = Date()

        // Save to CoreData first
        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        guard let userEntity = try? viewContext.fetch(userFetch).first else {
            errorMessage = "User not found"
            showErrorAlert = true
            isCompleting = false
            return
        }

        let newTxn = Transaction(context: viewContext)
        newTxn.id = newID
        newTxn.externalID = newID.uuidString
        newTxn.name = trimmedName
        newTxn.amount = NSDecimalNumber(value: -amount)
        newTxn.notes = transactionNote.trimmingCharacters(in: .whitespacesAndNewlines)
        newTxn.transactionDate = transactionDate
        newTxn.pending = false
        newTxn.createdAt = now
        newTxn.updatedAt = now
        newTxn.account = account
        newTxn.user = userEntity

        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            isCompleting = false
            errorMessage = "Failed to save locally: \(error.localizedDescription)"
            showErrorAlert = true
            return
        }

        Task {
            do {
                _ = try await APIService.shared.createTransaction(
                    id: newID,
                    accountID: accountID,
                    name: trimmedName,
                    amount: -amount,
                    notes: transactionNote.trimmingCharacters(in: .whitespacesAndNewlines),
                    transactionDate: transactionDate,
                    token: token
                )
                await MainActor.run {
                    isCompleting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    viewContext.delete(newTxn)
                    try? viewContext.save()
                    isCompleting = false
                    errorMessage = "Failed to save to server: \(error.localizedDescription)"
                    showErrorAlert = true
                }
            }
        }
    }
}

struct TransactionRowView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var transaction: Transaction
    @State private var showTransactionDetail = false
    var allocatedAmount: NSDecimalNumber?
    var dbtAcct: Account

    var body: some View {
        Button (action: { showTransactionDetail = true }) {
            VStack(alignment: .leading, spacing: 5) {
                // Middle row containg the transaction name and the amount
                HStack(alignment: .center, spacing: 6) {
                    if transaction.account != dbtAcct {
                        Image(getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? ""))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .clipShape(Circle())
                            .padding(.top, 1)
                    }
                    
                    Text(transaction.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                        .foregroundColor(transaction.pending ? .secondary : .primary)
                    
                    Spacer(minLength: 8)
                    
                    // Show allocated amount if present, otherwise full transaction amount
                    let displayAmount = allocatedAmount ?? transaction.amount
                    let amountDecimal = displayAmount.map { $0.decimalValue as Decimal }
                    let isUnpaid = transaction.account != dbtAcct && (transaction.transferGroup == nil || transaction.transferGroup?.completed == false)
                    let amountColor: Color = {
                        if isUnpaid { return .appOrange }
                        guard let val = amountDecimal else { return .primary }
                        return val < 0 ? .primary : .green
                    }()
                    HStack(spacing: 1) {
                        let effectiveAmountColor: Color = isUnpaid ? .appOrange : (transaction.pending ? .secondary : amountColor)
                        Text(amountDecimal.map { $0.formatted(.currency(code: "USD")) } ?? "")
                            .fontWeight(.bold)
                            .font(.system(size: 15))
                            .foregroundStyle(effectiveAmountColor)
                            .fixedSize()
                        if let allocated = allocatedAmount,
                           let txAmount = transaction.amount,
                           abs(allocated.decimalValue as Decimal) != abs(txAmount.decimalValue as Decimal) {
                            Text("*")
                                .fontWeight(.bold)
                                .font(.system(size: 15))
                                .foregroundStyle(effectiveAmountColor)
                                .fixedSize()
                        }
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTransactionDetail) {
            TransactionView(transaction: transaction)
                .environment(\.managedObjectContext, viewContext)
                .presentationDetents((transaction.account?.accountType == "Credit" && (transaction.amount?.decimalValue ?? 0) < 0) ? [.height(650)] : [.height(300)])
                .presentationDragIndicator(.visible)
            
        }
        .alert("Save Error", isPresented: Binding(
            get: { authManager.allocationSaveError != nil },
            set: { if !$0 { authManager.allocationSaveError = nil } }
        )) {
            Button("OK", role: .cancel) { authManager.allocationSaveError = nil }
        } message: {
            Text(authManager.allocationSaveError ?? "")
        }
    }
}





#Preview("Debit Account") {
    let context = PersistenceController.preview.container.viewContext
    let request = Account.fetchRequest()
    request.predicate = NSPredicate(format: "externalID == %@", "act1")
    request.fetchLimit = 1
    let account = (try? context.fetch(request))?.first ?? Account(context: context)
    return NavigationStack {
        AccountView(account: account)
    }
    .environment(\.managedObjectContext, context)
    .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Manual Account") {
    let context = PersistenceController.preview.container.viewContext
    let request = Account.fetchRequest()
    request.predicate = NSPredicate(format: "externalID == %@", "act5")
    request.fetchLimit = 1
    let account = (try? context.fetch(request))?.first ?? Account(context: context)
    return NavigationStack {
        AccountView(account: account)
    }
    .environment(\.managedObjectContext, context)
    .environmentObject(PersistenceController.previewAuthManager())
}
//
//#Preview("Credit Account") {
//    let context = PersistenceController.preview.container.viewContext
//    let account = PersistenceController.previewCreditAccount
//    NavigationStack {
//        AccountView(account: account)
//    }
//    .environment(\.managedObjectContext, context)
//}

