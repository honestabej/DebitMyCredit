import SwiftUI
import CoreData

struct TransactionsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedAccount: Account? = nil
    @State private var showCardPicker = false
    @State private var showFilterView = false
    @State private var filterStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var filterEndDate: Date = Date()
    @State private var filterRangeOption: TransactionsView.RangeOption = .last30

    enum RangeOption {
        case last30, ytd, all, custom
    }

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
            Color.appGreen.ignoresSafeArea()
            
            // White background behind tab bar
            VStack {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.lightBackground)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, 45)
            
            // Actual Content
            VStack {
                // The area above the white space holding the accounts
                ZStack {
                    Text("Credit Transactions")
                        .font(.system(size: 25))
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(.top, 3)
                    
                    // Dont show refresh button if a refresh is currently taking place
                    
                    HStack {
                        // Filter button
                        Button {
                            showFilterView = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(.white)
                                .padding(.leading, 20)
                                .padding(.top, 3)
                                .font(.system(size: 23))
                        }
                        
                        Spacer()
                        
                        // Refresh button
                        if (!authManager.isRefreshing && !authManager.isSyncingSimpleFIN && !authManager.isLoadingUserData) {
                            Button(action: {
                                Task { await authManager.refreshData() }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 3)
                        }
                    }
                }
                
                // Spacer to start the list at the correct spot
                Spacer().frame(height: 20)
                
                transactionsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
        }
        .onAppear {
            // Force creditAccounts fetch to execute immediately so the popover opens without delay
            _ = creditAccounts.count
        }
        .onChange(of: selectedAccount) { _, _ in updatePredicate() }
        .onChange(of: filterStartDate) { _, _ in updatePredicate() }
        .onChange(of: filterEndDate) { _, _ in updatePredicate() }
        .onChange(of: filterRangeOption) { _, _ in updatePredicate() }
        .sheet(isPresented: $showFilterView) {
            FilterSheetWrapper(
                selectedAccount: $selectedAccount,
                accounts: Array(creditAccounts),
                startDate: $filterStartDate,
                endDate: $filterEndDate,
                rangeOption: $filterRangeOption
            )
        }

    }
    
    // Update the dates being used to filter the transactions
    private func updatePredicate() {
        let calendar = Calendar.current
        let start: Date
        let end: Date = calendar.startOfDay(for: filterEndDate).addingTimeInterval(86400) // end of day

        switch filterRangeOption {
        case .last30:
            start = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        case .ytd:
            start = calendar.date(from: calendar.dateComponents([.year], from: Date())) ?? Date()
        case .all:
            start = .distantPast
        case .custom:
            start = calendar.startOfDay(for: filterStartDate)
        }

        var predicates: [NSPredicate] = [
            NSPredicate(format: "transactionDate >= %@ AND transactionDate < %@", start as NSDate, end as NSDate)
        ]
        if let account = selectedAccount {
            predicates.append(NSPredicate(format: "account == %@", account))
        } else {
            predicates.append(NSPredicate(format: "account.accountType == %@", "Credit"))
        }
        transactions.nsPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
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
                                .padding([.vertical, .leading], 8)
//                                .padding(.leading, 8)
                            if index < pendingTransactions.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text("Pending")
                            .font(.system(size: 15))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(Color.lightBackground)
                    }
                    .padding(.horizontal, 12)
                }

                // Settled transactions grouped by day
                ForEach(settledTransactionsByDay, id: \.day) { group in
                    Section {
                        ForEach(Array(group.transactions.enumerated()), id: \.element.objectID) { index, tx in
                            TransactionRow(transaction: tx)
                                .padding([.vertical, .leading], 8)
                            if index < group.transactions.count - 1 {
                                Divider()
                            }
                        }
                    } header: {
                        Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                            .font(.system(size: 15))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(Color.lightBackground)
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // Wrapper that measures FilterView's natural height and sizes the sheet to fit, up to 70% of screen height
    private struct FilterSheetWrapper: View {
        @Binding var selectedAccount: Account?
        let accounts: [Account]
        @Binding var startDate: Date
        @Binding var endDate: Date
        @Binding var rangeOption: TransactionsView.RangeOption
        @State private var contentHeight: CGFloat = 300

        private var screenHeight: CGFloat {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 852
        }

        var body: some View {
            NavigationStack {
                FilterView(selectedAccount: $selectedAccount, accounts: accounts, contentHeight: $contentHeight, startDate: $startDate, endDate: $endDate, rangeOption: $rangeOption)
            }
            .presentationDetents([.height(min(contentHeight, screenHeight * 0.7))])
            .presentationDragIndicator(.visible)
            .background(SheetResizeAnimator(height: min(contentHeight, screenHeight * 0.7)))
        }
    }

    // Uses UISheetPresentationController.animateChanges to smoothly resize the sheet
    private struct SheetResizeAnimator: UIViewControllerRepresentable {
        let height: CGFloat

        func makeUIViewController(context: Context) -> UIViewController {
            UIViewController()
        }

        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            guard
                let sheet = uiViewController.parent?.sheetPresentationController
                    ?? uiViewController.presentingViewController?.presentedViewController?.sheetPresentationController
            else { return }
            let detent = UISheetPresentationController.Detent.custom(identifier: .init("dynamic")) { _ in height }
            sheet.animateChanges {
                sheet.detents = [detent]
            }
        }
    }

    // View to display the filter options
    private struct FilterView: View {
        @Binding var selectedAccount: Account?
        let accounts: [Account]
        @Binding var contentHeight: CGFloat
        @Binding var startDate: Date
        @Binding var endDate: Date
        @Binding var rangeOption: TransactionsView.RangeOption

        private enum RangeOption: String, CaseIterable, Identifiable {
            case last30 = "Last 30 Days"
            case ytd = "Year To Date"
            case all = "All Time"
            case custom = "Custom Date Range"
            var id: Self { self }
            var outer: TransactionsView.RangeOption {
                switch self {
                case .last30: return .last30
                case .ytd: return .ytd
                case .all: return .all
                case .custom: return .custom
                }
            }
        }

        private var selected: RangeOption {
            switch rangeOption {
            case .last30: return .last30
            case .ytd: return .ytd
            case .all: return .all
            case .custom: return .custom
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                // Date range filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Date Range:")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(RangeOption.allCases) { option in
                            Button(action: { withAnimation(.spring(duration: 0.3)) { rangeOption = option.outer } }) {
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

                    if selected == .custom {
                        HStack(spacing: 8) {
                            ZStack {
                                // Styled button background — displays the selected date
                                HStack(spacing: 4) {
                                    Text(startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                .allowsHitTesting(false)

                                // Invisible picker sits on top to handle taps
                                DatePicker("", selection: $startDate, in: ...endDate, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .colorMultiply(.clear)
                            }

                            Text("to")
                                .foregroundStyle(.secondary)

                            ZStack {
                                HStack(spacing: 4) {
                                    Text(endDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                .allowsHitTesting(false)

                                DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .colorMultiply(.clear)
                            }

                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                
                // Card filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card:")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Button { selectedAccount = nil } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedAccount == nil ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.appOrange)
                                Text("All")
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                        
                        ForEach(accounts) { account in
                            Button { selectedAccount = account } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedAccount == account ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(Color.appOrange)
                                    Text(account.name ?? "")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                }

                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { contentHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in contentHeight = h }
                }
            )
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
                    Text("Pay Group: \(tgName)")
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



#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return TransactionsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    return TransactionsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewEmptyAuthManager())
}

