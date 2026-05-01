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
                    Text(account.availableBalance.map { availableBalance in
                        availableBalance.decimalValue as Decimal
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
            }
            .padding(.top, 1)
            
            Text("Transactions: ")
                .padding([.top, .leading], 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 20))
                .fontWeight(.semibold)
            
            // Transactions table
            transactionsList
            
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .padding(.vertical, 4)
                            .background(Color(.systemBackground))
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
                            .background(Color(.systemBackground))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

struct TransactionRowView: View {
    @ObservedObject var transaction: Transaction
    var allocatedAmount: NSDecimalNumber?
    var dbtAcct: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Top row containing account details and the transfer group if from a credit card
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
                
                if transaction.account != dbtAcct {
                    let tgName = transaction.transferGroup?.name ?? "--"
                    Text("TG: \(tgName)")
                        .font(.caption)
                        .fontWeight(.light)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            
            // Middle row containg the transaction name and the amount
            HStack(spacing: 10) {
                Text(transaction.name ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
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
                    if allocatedAmount != nil && allocatedAmount != transaction.amount,
                       let fullAmount = transaction.amount {
                        let formatted = (fullAmount.decimalValue as Decimal).formatted(.currency(code: "USD"))
                        Text("/\(formatted)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 90, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(transaction.pending ? .secondary : .primary)
            
            
//            if transaction.pending == false && transaction.notes != nil {
//                Text("\(transaction.notes ?? "")")
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                    .lineLimit(2)
//                    .truncationMode(.tail)
//                    .padding(.leading, 39)
//                    .padding(.trailing, 15)
//            }
        }
    }
}





// MARK: For preview window
private func makeTx(id: String, name: String, amount: Double, date: Date, pending: Bool, acct: Account, context: NSManagedObjectContext) -> Transaction {
    let txn = Transaction(context: context)
    txn.id = id
    txn.name = name
    txn.amount = NSDecimalNumber(value: amount)
    txn.transactionDate = date
    txn.pending = pending
    txn.account = acct
    return txn
}

private func makePreviewAccount() -> (account: Account, context: NSManagedObjectContext) {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    
    // Create a transferGroup
    let tg1 = TransferGroup(context: context)
    tg1.name = "82"

    // Checking Account being viewed
    let dbtAcct = Account(context: context)
    dbtAcct.id = "dbt-1"
    dbtAcct.name = "Abe's Checking"
    dbtAcct.bank = "Wells Fargo"
    dbtAcct.accountType = "Debit"
    dbtAcct.accountNumber = "1234"
    dbtAcct.availableBalance = NSDecimalNumber(value: 1234.56)
    dbtAcct.balanceDate = Date()

    // Two credit accounts
    let chaseCrdt = Account(context: context)
    chaseCrdt.id = "cdt-1"
    chaseCrdt.name = "Chase Sapphire Preffered"
    chaseCrdt.bank = "Chase"
    chaseCrdt.accountType = "Credit"
    chaseCrdt.accountNumber = "2345"

    let applCrdt = Account(context: context)
    applCrdt.id = "cdt-2"
    applCrdt.name = "Apple Card"
    applCrdt.bank = "Apple"
    applCrdt.accountType = "Credit"
    applCrdt.accountNumber = "3456"

    let twoDaysPrior = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
    let threeDaysPrior = Calendar.current.date(byAdding: .day, value: -3, to: Date())!

    // Transactions from the checking account
    let txn1 = makeTx(id: "t1", name: "Starbucks", amount: -5.75, date: Date(), pending: false, acct: dbtAcct, context: context)
    txn1.notes = "STARBUCKS CORP #79209"
    let txn2 = makeTx(id: "t2", name: "Target", amount: -23.50, date: Date(), pending: false, acct: dbtAcct, context: context)
    let txn3 = makeTx(id: "t3", name: "Safeway", amount: -131.58, date: Date(), pending: false, acct: dbtAcct, context: context)
    let txn4 = makeTx(id: "t4", name: "Online Transfer", amount: -240.00, date: Date(), pending: false, acct: dbtAcct, context: context)
    txn4.notes = "ONLINE TRANSFER ACCT 2345 TO ABRAHAM J - $240 CYCLE FOR TWO WEEKS"
    let txn5 = makeTx(id: "t5", name: "Amazon", amount: -42.99, date: Date(), pending: true, acct: dbtAcct, context: context)
    let txn6 = makeTx(id: "t6", name: "Target", amount: -50.38, date: Date(), pending: true, acct: dbtAcct, context: context)
    let txn7 = makeTx(id: "t7", name: "McDonald's", amount: -26.83, date: twoDaysPrior, pending: false, acct: dbtAcct, context: context)
    let txn8 = makeTx(id: "t8", name: "Cane's Chicken", amount: -15.48, date: threeDaysPrior, pending: false, acct: dbtAcct, context: context)
    let txn9 = makeTx(id: "t9", name: "Black Rock Coffee Bar", amount: -7.26, date: threeDaysPrior, pending: false, acct: dbtAcct, context: context)

    // Transactions from credit accounts
    let txn10 = makeTx(id: "t10", name: "Target", amount: -81.24, date: Date(), pending: true, acct: chaseCrdt, context: context)
    let txn11 = makeTx(id: "t11", name: "Amazon", amount: -46.10, date: twoDaysPrior, pending: false, acct: chaseCrdt, context: context)
    let txn12 = makeTx(id: "t12", name: "Oregano's Bistro", amount: -57.23, date: twoDaysPrior, pending: false, acct: chaseCrdt, context: context)
    txn12.transferGroup = tg1
    let txn13 = makeTx(id: "t13", name: "Walmart", amount: -17.62, date: threeDaysPrior, pending: false, acct: chaseCrdt, context: context)
    txn13.transferGroup = tg1
    let txn14 = makeTx(id: "t14", name: "Life Cafe", amount: -9.60, date: Date(), pending: true, acct: applCrdt, context: context)
    let txn15 = makeTx(id: "t15", name: "Black Rock Coffee Bar", amount: -7.26, date: threeDaysPrior, pending: false, acct: applCrdt, context: context)
    txn15.transferGroup = tg1

    
    
    // Allocating credit transactions to the checking account
    let allo1 = TransactionAllocation(context: context)
    allo1.transaction = txn10
    allo1.account = dbtAcct
    allo1.amount = txn10.amount // Full amount

    let allo2 = TransactionAllocation(context: context)
    allo2.transaction = txn11
    allo2.account = dbtAcct
    allo2.amount = txn11.amount

    let allo3 = TransactionAllocation(context: context)
    allo3.transaction = txn12
    allo3.account = dbtAcct
    allo3.amount = NSDecimalNumber(value: -32.45)

    let allo4 = TransactionAllocation(context: context)
    allo4.transaction = txn13
    allo4.account = dbtAcct
    allo4.amount = NSDecimalNumber(value: -9.37)

    let allo5 = TransactionAllocation(context: context)
    allo5.transaction = txn14
    allo5.account = dbtAcct
    allo5.amount = txn14.amount

    let allo6 = TransactionAllocation(context: context)
    allo6.transaction = txn15
    allo6.account = dbtAcct
    allo6.amount = txn15.amount

    // Suppress unused variable warnings
    _ = (txn1, txn2, txn3, txn4, txn5, txn6, txn7, txn8, txn9, allo1, allo2, allo3, allo4, allo5, allo6)

    try? context.save()
    return (dbtAcct, context)
}

#Preview {
    let (dbtAcct, context) = makePreviewAccount()
    NavigationStack {
        AccountView(account: dbtAcct)
    }
    .environment(\.managedObjectContext, context)
}

