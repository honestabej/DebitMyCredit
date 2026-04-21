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

    var body: some View {
        let acctBalDate = account.balanceDate?.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute()) ?? "Unknown"
        
        VStack() {
            // Card Image
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(getBankColor(bankName: account.bank?.lowercased() ?? ""))
                    .frame(width: 110, height: 69)
                
                // Bank logo — top left
                VStack {
                    HStack {
                        Image(getBankTextLogo(bankName: account.bank?.lowercased() ?? ""))
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 13)
                            .padding([.top, .leading], 5)
                        Spacer()
                    }
                    Spacer()
                }
                .frame(width: 100, height: 63)
                
                // Last 4 digits — bottom right
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if let acctNum = account.accountNumber {
                            Text("...\(acctNum)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.bottom, 5)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .frame(width: 110, height: 69)
            }
            
            // Last updated indication
            Text("\(acctBalDate)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Text(account.name ?? "")
                .fontWeight(.heavy)
                .font(.system(size: 24))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)
     
            HStack() {
                Spacer()
                
                VStack() {
                    Text(account.accountBalance.map { balance in
                        balance.decimalValue as Decimal
                    }.map {
                        $0.formatted(.currency(code: "USD"))
                    } ?? "")
                        .fontWeight(.semibold)
                        .font(.title3)
                    
                    Text("Balance")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                VStack() {
                    Text(account.accountBalance.map { balance in
                        balance.decimalValue as Decimal
                    }.map {
                        $0.formatted(.currency(code: "USD"))
                    } ?? "")
                        .italic()
                        .fontWeight(.semibold)
                        .font(.title3)
                    
                    Text("Active")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.gray)
                        .italic()
                }
                
                Spacer()
            }
            .padding(.top, 1)
            
            Text("Transactions: ")
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 20))
                .fontWeight(.semibold)
            
            // Transactions table
            transactionsList
            
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 50)
        .navigationBarTitleDisplayMode(.inline)
        .presentationDragIndicator(.visible)
    }
    
    private var transactionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                // Pending section — always at top
                if !pendingRows.isEmpty {
                    Section {
                        ForEach(Array(pendingRows.enumerated()), id: \.element.transaction.objectID) { index, row in
                            TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)

                            if index < pendingRows.count - 1 {
                                Divider().padding(.leading, 20)
                            }
                        }
                    } header: {
                        Text("Pending")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(.systemBackground))
                    }

                    if !settledRowsByDay.isEmpty {
                        Divider()
                    }
                }

                // Settled transactions grouped by day
                ForEach(settledRowsByDay, id: \.day) { group in
                    Section {
                        ForEach(Array(group.rows.enumerated()), id: \.element.transaction.objectID) { index, row in
                            TransactionRowView(transaction: row.transaction, allocatedAmount: row.allocatedAmount)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)

                            if index < group.rows.count - 1 {
                                Divider().padding(.leading, 20)
                            }
                        }
                    } header: {
                        Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(.systemBackground))
                    }
                }
            }
        }
    }
}

struct TransactionRowView: View {
    @ObservedObject var transaction: Transaction
    /// When non-nil, this transaction was allocated to the account with a specific amount
    var allocatedAmount: NSDecimalNumber?

    var body: some View {
        HStack() {
            Image(getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? ""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .frame(alignment: .leading)
                .opacity(transaction.pending ? 0.5 : 1.0)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name ?? "Tx")
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .font(.system(size: 17))
                // Show source account name for allocated transactions
                if allocatedAmount != nil, let sourceName = transaction.account?.name {
                    Text("From: \(sourceName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if transaction.pending == false && transaction.notes != nil {
                    Text("\(transaction.notes ?? "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer()
            
            VStack(alignment: .trailing) {
                // Show allocated amount if present, otherwise full transaction amount
                let displayAmount = allocatedAmount ?? transaction.amount
                Text(displayAmount.map {
                    $0.decimalValue as Decimal
                } .map {
                    $0.formatted(.currency(code: "USD"))
                } ?? "")
                    .fontWeight(.bold)
                    .font(.system(size: 15))
                    

                // Show full amount if it was allocated from another account
                if allocatedAmount != nil {
                    Text("/ \(transaction.amount!)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 90, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(transaction.pending ? .secondary : .primary)
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    // Primary account being viewed
    let account = Account(context: context)
    account.id = "1"
    account.name = "Abe's Checking"
    account.bank = "Wells Fargo"
    account.accountType = "Debit"
    account.accountNumber = "1234"
    account.accountBalance = NSDecimalNumber(value: 1234.56)
    account.balanceDate = Date()

    // Direct transactions on this account
    let txn1 = Transaction(context: context)
    txn1.id = "t1"
    txn1.name = "Starbucks"
    txn1.amount = NSDecimalNumber(value: -5.75)
    txn1.transactionDate = Date()
    txn1.pending = false
    txn1.account = account

    // Same day as txn1 — should appear in the same date group
    let txn4 = Transaction(context: context)
    txn4.id = "t4"
    txn4.name = "Target"
    txn4.amount = NSDecimalNumber(value: -23.50)
    txn4.transactionDate = Calendar.current.date(byAdding: .hour, value: -3, to: Date())
    txn4.pending = false
    txn4.account = account

    // Pending — should appear at top
    let txn2 = Transaction(context: context)
    txn2.id = "t2"
    txn2.name = "Amazon"
    txn2.amount = NSDecimalNumber(value: -42.99)
    txn2.transactionDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    txn2.pending = true
    txn2.account = account

    // Second pending transaction
    let txn5 = Transaction(context: context)
    txn5.id = "t5"
    txn5.name = "Netflix"
    txn5.amount = NSDecimalNumber(value: -15.99)
    txn5.transactionDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    txn5.pending = true
    txn5.account = account

    // A second account that is the source of an allocated transaction
    let chaseCreditAcct = Account(context: context)
    chaseCreditAcct.id = "2"
    chaseCreditAcct.name = "Chase Credit"
    chaseCreditAcct.bank = "Chase"
    chaseCreditAcct.accountType = "Credit"
    chaseCreditAcct.accountNumber = "5678"
    chaseCreditAcct.accountBalance = NSDecimalNumber(value: 3000.00)

    // Transaction on the credit account that is partially allocated to the credit card
    let txn3 = Transaction(context: context)
    txn3.id = "t3"
    txn3.name = "Chase credit tx"
    txn3.amount = NSDecimalNumber(value: -500.00)
    txn3.transactionDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
    txn3.pending = false
    txn3.account = chaseCreditAcct

    // Allocation: $500 of the checking payment allocated to the credit card account
    let allocation = TransactionAllocation(context: context)
    allocation.transaction = txn3
    allocation.account = account
    allocation.amount = NSDecimalNumber(value: -500.00)

    try? context.save()

    return NavigationStack {
        AccountView(account: account)
    }
    .environment(\.managedObjectContext, context)
}

