import SwiftUI
import CoreData

struct TransactionsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedAccount: Account? = nil
    @State private var showCardPicker = false
    @State private var showFilterView = false

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType == %@", "Credit"),
        animation: .default
    )
    private var creditAccounts: FetchedResults<Account>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Transaction.transactionDate, ascending: false)],
        predicate: NSPredicate(format: "account.accountType == %@", "Credit"),
        animation: .default
    )
    private var transactions: FetchedResults<Transaction>

    private var cardName: String {
        selectedAccount?.name ?? "All"
    }
    
    var body: some View {
        ZStack () {
            // Background gradient
            AppGradients.horizontalGradient.ignoresSafeArea()
            
            // White background behind tab bar
            VStack {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, 70)
            
            // Actual Content
            VStack {
                // The area above the white space holding the accounts
                ZStack {
                    Text("Credit Transactions")
                        .font(.system(size: 25))
                        .fontWeight(.bold)
                        .padding(.top)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                    
                    // Dont show refresh button if a refresh is currently taking place
                    if (!authManager.isRefreshing && !authManager.isSyncingSimpleFIN && !authManager.isLoadingUserData) {
                        HStack {
                            Spacer()
                            Button(action: {
                                Task { await authManager.refreshData() }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.top)
                            .padding(.trailing, 20)
                        }
                    }
                }
                
                    
                
                Spacer().frame(height: 37)
                
                HStack {
                    Text("Card: ")
                        .padding(.leading, 15)
                        .fontWeight(.semibold)
                    
                    Button {
                        showCardPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(cardName)
                                .animation(nil, value: cardName)
                            Image(systemName: "chevron.down")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.appOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .fontWeight(.bold)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showCardPicker, arrowEdge: .top) {
                        let accounts = Array(creditAccounts)
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                selectedAccount = nil
                                showCardPicker = false
                            } label: {
                                HStack {
                                    Text("All")
                                        .foregroundStyle(selectedAccount == nil ? Color.appOrange : .primary)
                                        .fontWeight(selectedAccount == nil ? .semibold : .regular)
                                    Spacer()
                                    if selectedAccount == nil {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.appOrange)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            ForEach(accounts) { account in
                                Divider()
                                Button {
                                    selectedAccount = account
                                    showCardPicker = false
                                } label: {
                                    HStack {
                                        Text(account.name ?? "")
                                            .foregroundStyle(selectedAccount == account ? Color.appOrange : .primary)
                                            .fontWeight(selectedAccount == account ? .semibold : .regular)
                                        Spacer()
                                        if selectedAccount == account {
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
                        .frame(minWidth: 200)
                        .presentationCompactAdaptation(.popover)
                    }
                    
                    Spacer()
                    
                    Button {
                        showFilterView = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(Color.appOrange)
                            .padding(.trailing, 15)
                            .font(.system(size: 23))
                    }
                    
                }
                .frame(maxWidth: .infinity)
                
                transactionsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }
        .onAppear {
            // Force creditAccounts fetch to execute immediately so the popover opens without delay
            _ = creditAccounts.count
        }
        .onChange(of: selectedAccount) { _, account in
            if let account = account {
                transactions.nsPredicate = NSPredicate(format: "account == %@", account)
            } else {
                transactions.nsPredicate = NSPredicate(format: "account.accountType == %@", "Credit")
            }
        }
        .sheet(isPresented: $showFilterView) {
            NavigationStack {
                FilterView()
            }
            .presentationDetents([.height(200)])
        }

    }
    
    /// Pending transactions, shown at the top regardless of date.
    private var pendingTransactions: [Transaction] {
        transactions.filter { $0.pending }
    }

    /// Non-pending transactions grouped by calendar day, newest day first.
    private var settledTransactionsByDay: [(day: Date, transactions: [Transaction])] {
        let calendar = Calendar.current
        let settled = transactions.filter { !$0.pending }
        let grouped = Dictionary(grouping: settled) { tx -> Date in
            calendar.startOfDay(for: tx.transactionDate ?? .distantPast)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, transactions: $0.value) }
    }

    // View to display the list of transactions grouped by pending then by date
    private var transactionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                // Pending section — always at top
                if !pendingTransactions.isEmpty {
                    Section {
                        ForEach(Array(pendingTransactions.enumerated()), id: \.element.objectID) { index, tx in
                            TransactionRow(transaction: tx)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 8)
                            if index < pendingTransactions.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text("Pending")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 15)
                            .background(Color.clear)
                    }
                }

                // Settled transactions grouped by day
                ForEach(settledTransactionsByDay, id: \.day) { group in
                    Section {
                        ForEach(Array(group.transactions.enumerated()), id: \.element.objectID) { index, tx in
                            TransactionRow(transaction: tx)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 8)
                            if index < group.transactions.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 15)
                            .background(Color.clear)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // View to display the filter options
    private struct FilterView: View {
        private enum RangeOption: String, CaseIterable, Identifiable {
            case last30 = "Last 30 Days"
            case ytd = "Year To Date"
            case custom = "Custom Date Range"
            var id: Self { self }
        }

        @State private var selected: RangeOption = .last30

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Display transactions from:")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                // Radio-style list
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(RangeOption.allCases) { option in
                        Button(action: { selected = option }) {
                            HStack(spacing: 10) {
                                Image(systemName: selected == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.appOrange)
                                Text(option.rawValue)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }

                // Optional: Placeholder for custom date pickers when custom is selected
                if selected == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a date range")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }
}

// MARK: View for each row displaying a transactions
struct TransactionRow: View {
    @ObservedObject var transaction: Transaction
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showTransactionDetail = false

    var body: some View {

        Button(action: { showTransactionDetail = true }) {
            VStack(spacing: 5) {
                // Top row containing account details and the transfer group
                HStack() {
                    Image(getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? ""))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .clipShape(Circle())
                    Text(transaction.account?.name ?? "" )
                        .font(.caption)
                        .fontWeight(.light)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let acctNum = transaction.account?.accountNumber {
                        Text("...\(acctNum)")
                            .font(.caption)
                            .fontWeight(.light)
                    }
                    
                    Spacer ()
                    
                    let tgName = transaction.transferGroup?.name ?? "--"
                    Text("TG: \(tgName)")
                        .font(.caption)
                        .fontWeight(.light)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                }
                
                // Middle row containg the transaction name and the amount
                HStack(spacing: 10) {
                    Text(transaction.name ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer()
                    
                    let displayAmount = transaction.amount
                    Text(displayAmount.map {
                        $0.decimalValue as Decimal
                    } .map {
                        $0.formatted(.currency(code: "USD"))
                    } ?? "")
                    .fontWeight(.bold)
                    .font(.system(size: 15))
                }
                
                // Bottom row containing the allocations
                HStack(spacing: 6) {
                    Text("Allocation: ")
                        .font(.caption)
                        .fontWeight(.light)
                    
                    let allocations = (transaction.allocations as? Set<TransactionAllocation>)?
                        .sorted { ($0.account?.name ?? "") < ($1.account?.name ?? "") } ?? []
                    
                    if allocations.isEmpty {
                        Text("None")
                            .font(.caption2)
                            .fontWeight(.light)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(allocations, id: \.objectID) { allocation in
                            if let account = allocation.account {
                                HStack(spacing: 4) {
                                    Text(account.name ?? "")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Color(hex: account.accountColor ?? "#BDBDBD").opacity(0.41)
                                )
                                .clipShape(Capsule())
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 5)
                
            }
            .foregroundColor(transaction.pending ? .secondary : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTransactionDetail) {
            TransactionView()
                .environment(\.managedObjectContext, viewContext)
                .presentationDragIndicator(.visible)
        }
    }
}



#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let account = Account(context: context)
    account.id = UUID().uuidString
    account.name = "Chase Sapphire"
    account.bank = "Chase"
    account.accountType = "Credit"
    account.accountNumber = "1234"
    account.accountColor = CoreDataService.randomAccountColor()
    
    // Checking Account being viewed
    let dbtAcct = Account(context: context)
    dbtAcct.id = "dbt-1"
    dbtAcct.name = "Abe's Checking"
    dbtAcct.bank = "Wells Fargo"
    dbtAcct.accountType = "Debit"
    dbtAcct.accountNumber = "1234"
    dbtAcct.availableBalance = NSDecimalNumber(value: 1234.56)
    dbtAcct.balanceDate = Date()
    dbtAcct.accountColor = CoreDataService.randomAccountColor()
    // Checking Account being viewed
    let dbtAcct2 = Account(context: context)
    dbtAcct2.id = "dbt-2"
    dbtAcct2.name = "Shae's Checking"
    dbtAcct2.bank = "Wells Fargo"
    dbtAcct2.accountType = "Debit"
    dbtAcct2.accountNumber = "2345"
    dbtAcct2.availableBalance = NSDecimalNumber(value: 1234.56)
    dbtAcct2.balanceDate = Date()
    dbtAcct2.accountColor = CoreDataService.randomAccountColor()
    
    // Create a transferGroup
    let tg1 = TransferGroup(context: context)
    tg1.name = "82"

    let tx1 = Transaction(context: context)
    tx1.id = UUID().uuidString
    tx1.name = "Whole Foods Market"
    tx1.amount = -54.32
    tx1.transactionDate = Date()
    tx1.account = account

    let tx2 = Transaction(context: context)
    tx2.id = UUID().uuidString
    tx2.name = "Netflix"
    tx2.amount = -15.99
    tx2.transactionDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    tx2.account = account
    tx2.transferGroup = tg1
    
    let tx3 = Transaction(context: context)
    tx3.id = UUID().uuidString
    tx3.name = "McDonald's"
    tx3.amount = -26.73
    tx3.transactionDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    tx3.account = account
    tx3.transferGroup = tg1
    
    let allo1 = TransactionAllocation(context: context)
    allo1.transaction = tx2
    allo1.account = dbtAcct
    allo1.amount = tx2.amount // Full amount

    let allo2 = TransactionAllocation(context: context)
    allo2.transaction = tx3
    allo2.account = dbtAcct
    allo2.amount = NSDecimalNumber(value: -14.50)

    let allo3 = TransactionAllocation(context: context)
    allo3.transaction = tx3
    allo3.account = dbtAcct2
    allo3.amount = NSDecimalNumber(value: -12.23)
    

    try? context.save()

    return TransactionsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(AuthManager(viewContext: context))
}

