import SwiftUI
import CoreData
import Combine

struct AccountView: View {
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

    var body: some View {
        let acctBalDate = account.balanceDate?.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute()) ?? "Unknown"
        let bankColor = getBankColor(bankName: account.bank?.lowercased() ?? "")
        
        ZStack(alignment: .top) {
            Color.lightBackground.ignoresSafeArea()
            
            // Gradient background: bank color at top, fading to clear ~25% down
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        // TODO: Implement table
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
                        .padding(.top, 10) // TODO: Remove after chart implemented
                    
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
                    .padding(.bottom, -3)
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
        
        } // ZStack
    }
    
    private var transactionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                // Pending section — always at top
                if !pendingRows.isEmpty {
                    Section {
                        ForEach(Array(pendingRows.enumerated()), id: \.element.transaction.objectID) { index, row in
                            TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount, dbtAcct: account)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 5)
                            if index < pendingRows.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text("Pending")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.lightBackground)
                    }
                }

                // Settled transactions grouped by day
                ForEach(settledRowsByDay, id: \.day) { group in
                    Section {
                        ForEach(Array(group.rows.enumerated()), id: \.element.transaction.objectID) { index, row in
                            TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount, dbtAcct: account)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 5)
                            if index < group.rows.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .background(Color.lightBackground)
                    }
                }
            }
            .padding(.horizontal, 10)
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
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(transaction.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                        .foregroundColor(transaction.pending ? .secondary : .primary)
                    
                    Spacer(minLength: 8)
                    
                    // Show allocated amount if present, otherwise full transaction amount
                    let displayAmount = allocatedAmount ?? transaction.amount
                    let amountDecimal = displayAmount.map { $0.decimalValue as Decimal }
                    let amountColor: Color = {
                        guard let val = amountDecimal else { return .primary }
                        return val < 0 ? .primary : .green
                    }()
                    HStack(spacing: 1) {
                        Text(amountDecimal.map { $0.formatted(.currency(code: "USD")) } ?? "")
                            .fontWeight(.bold)
                            .font(.system(size: 15))
                            .foregroundStyle(transaction.pending ? .secondary : amountColor)
                            .fixedSize()
                        if let allocated = allocatedAmount,
                           let txAmount = transaction.amount,
                           abs(allocated.decimalValue as Decimal) != abs(txAmount.decimalValue as Decimal) {
                            Text("*")
                                .fontWeight(.bold)
                                .font(.system(size: 15))
                                .foregroundStyle(transaction.pending ? .secondary : amountColor)
                                .fixedSize()
                        }
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Bottom row: only shown when the transaction is from a different account
                if transaction.account != dbtAcct {
                    HStack(spacing: 4) {
                        Image(getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? ""))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                            .clipShape(Circle())
                        
                        Text(transaction.account?.name ?? "")
                            .truncationMode(.tail)
                            .lineLimit(1)
                            .layoutPriority(1)
                        
                        Spacer(minLength: 8)
                        
                        if let tgName = transaction.transferGroup?.name {
                            Text("Paid: \(tgName)")
                                .truncationMode(.tail)
                                .lineLimit(1)
                                .frame(minWidth: 80, alignment: .trailing)
                                .layoutPriority(0)
                        } else {
                            Text("Unpaid")
                                .foregroundStyle(.orange)
                                .fixedSize()
                        }
                    }
                    .padding(.leading, 5)
                    .font(.caption)
                    .fontWeight(.light)
                    .lineLimit(1)
                    .foregroundStyle(transaction.pending ? .secondary : .primary)
                }
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
//
//#Preview("Credit Account") {
//    let context = PersistenceController.preview.container.viewContext
//    let account = PersistenceController.previewCreditAccount
//    NavigationStack {
//        AccountView(account: account)
//    }
//    .environment(\.managedObjectContext, context)
//}

