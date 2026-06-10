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
    @State private var filterUnallocated: Bool = false

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
        predicate: NSPredicate(
            format: "account.accountType == %@ AND amount < 0 AND transactionDate >= %@",
            "Credit",
            Calendar.current.date(byAdding: .day, value: -30, to: Date())! as NSDate
        ),
        animation: .default
    )
    private var transactions: FetchedResults<Transaction>

    private var cardName: String {
        selectedAccount?.name ?? "All"
    }
    
    var body: some View {
        // Background Color layer
        ZStack {
            Color.appGreen.ignoresSafeArea()
            
            // Actual Content
            VStack {
                PageHeaderView(title: "Credit Transactions", leftButton: FilterButton, includeRefresh: true)
                
                // Transaction list area
                transactionsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.lightBackground)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .onAppear {
            // Force creditAccounts fetch to execute immediately so the popover opens without delay
            _ = creditAccounts.count
            updatePredicate()
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
                rangeOption: $filterRangeOption,
                filterUnallocated: $filterUnallocated
            )
        }

    }
    
    // Filter button to pass into header
    private var FilterButton: some View {
        Button {
            showFilterView = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.white)
                .padding(.leading, 20)
                .padding(.top, 3)
                .font(.system(size: 23))
        }
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
                                .padding(.vertical, 8)
                                .padding(.leading, 4)
//                            if index < pendingTransactions.count - 1 {
//                                Divider()
//                            }
                        }
                    } header: {
                        VStack(spacing: 2) {
                            Text("Pending")
                                .font(.system(size: 15))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.lightBackground)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 15)
                }

                // Settled transactions grouped by day
                ForEach(settledTransactionsByDay, id: \.day) { group in
                    Section {
                        ForEach(Array(group.transactions.enumerated()), id: \.element.objectID) { index, tx in
                            TransactionRow(transaction: tx)
                                .padding(.vertical, 8)
                                .padding(.leading, 4)
//                            if index < group.transactions.count - 1 {
//                                Divider()
//                            }
                        }
                    } header: {
                        VStack(spacing: 2) {
                            Text(group.day.formatted(.dateTime.month(.wide).day().year()))
                                .font(.system(size: 15))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.lightBackground)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 15)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.top, 10)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 83) }
    }
    
    // Wrapper that measures FilterView's natural height and sizes the sheet to fit, up to 70% of screen height
    private struct FilterSheetWrapper: View {
        @Binding var selectedAccount: Account?
        let accounts: [Account]
        @Binding var startDate: Date
        @Binding var endDate: Date
        @Binding var rangeOption: TransactionsView.RangeOption
        @Binding var filterUnallocated: Bool
        @State private var contentHeight: CGFloat = 300

        private var screenHeight: CGFloat {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 852
        }

        var body: some View {
            NavigationStack {
                FilterView(selectedAccount: $selectedAccount, accounts: accounts, contentHeight: $contentHeight, startDate: $startDate, endDate: $endDate, rangeOption: $rangeOption, filterUnallocated: $filterUnallocated)
            }
            .presentationDetents([.height(min(contentHeight, screenHeight * 0.7))])
            .presentationDragIndicator(.visible)
            .background(SheetResizeAnimator(height: min(contentHeight, screenHeight * 0.7)))
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
        @Binding var filterUnallocated: Bool

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
                // Unallocated filter
                Toggle(isOn: $filterUnallocated) {
                    Text("Unallocated Only")
                        .font(.headline)
                }
                .tint(Color.appOrange)
                
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
            NSPredicate(format: "transactionDate >= %@ AND transactionDate < %@", start as NSDate, end as NSDate),
            NSPredicate(format: "amount < 0")
        ]
        if let account = selectedAccount {
            predicates.append(NSPredicate(format: "account == %@", account))
        } else {
            predicates.append(NSPredicate(format: "account.accountType == %@", "Credit"))
        }
        transactions.nsPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    // Pending transactions, shown at the top regardless of date.
    private var pendingTransactions: [Transaction] {
        transactions.filter {
            $0.pending && (!filterUnallocated || ($0.allocations as? Set<TransactionAllocation>)?.isEmpty == true)
        }
    }

    // Non-pending transactions grouped by calendar day, newest day first.
    private var settledTransactionsByDay: [(day: Date, transactions: [Transaction])] {
        let calendar = Calendar.current
        let settled = transactions.filter {
            !$0.pending && (!filterUnallocated || ($0.allocations as? Set<TransactionAllocation>)?.isEmpty == true)
        }
        let grouped = Dictionary(grouping: settled) { tx -> Date in
            calendar.startOfDay(for: tx.transactionDate ?? .distantPast)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, transactions: $0.value) }
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
}

// MARK: View for each row displaying a transactions
struct TransactionRow: View {
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject var transaction: Transaction
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showTransactionDetail = false
    var fromPaymentGroup: Bool = false

    var body: some View {

        Button(action: { if (!fromPaymentGroup) { showTransactionDetail = true }}) {
            VStack(spacing: 5) {
                // Middle row containg the transaction name and the amount
                HStack(spacing: 10) {
                    Text(transaction.name ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer()
                    
                    let isUnpaid = transaction.transferGroup == nil || transaction.transferGroup?.completed == false
                    let effectiveAmountColor: Color = isUnpaid ? .appOrange : (transaction.pending ? .secondary : .primary)
                    let displayAmount = transaction.amount
                    Text(displayAmount.map {
                        $0.decimalValue as Decimal
                    } .map {
                        $0.formatted(.currency(code: "USD"))
                    } ?? "")
                    .fontWeight(.bold)
                    .font(.system(size: 15))
                    .foregroundStyle(effectiveAmountColor)
                }
                
                // Bottom row containing the allocations
                HStack(spacing: 6) {
                    Image(getBankCircleLogo(bankName: transaction.account?.bank?.lowercased() ?? ""))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .clipShape(Circle())
                    if let acctNum = transaction.account?.accountNumber {
                        Text("••••\(acctNum)")
                            .font(.caption)
                            .fontWeight(.light)
                    }
                    
                    Text("•")
                    
                    let allocations = (transaction.allocations as? Set<TransactionAllocation>)?
                        .sorted { ($0.account?.name ?? "") < ($1.account?.name ?? "") } ?? []
                    
                    if allocations.isEmpty {
                        UnallocatedChip()
                    } else {
                        ForEach(allocations, id: \.objectID) { allocation in
                            if let account = allocation.account {
                                AllocationChip(account: account)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 5)
                
                // Delete orphaned pending transaction
                if transaction.isOrphaned {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transaction no longer exists")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.black)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            viewContext.delete(transaction)
                            try? viewContext.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.9))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .foregroundColor(transaction.pending ? .secondary : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTransactionDetail) {
            TransactionView(transaction: transaction)
                .environment(\.managedObjectContext, viewContext)
                .presentationDetents(transaction.account?.accountType == "Credit" ? [.height(650)] : [.height(300)])
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
    } // body
}



private struct AllocationChip: View {
    @ObservedObject var account: Account

    var body: some View {
        Text(account.name ?? "")
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(hex: account.accountColor ?? "#BDBDBD").opacity(0.41))
            .clipShape(Capsule())
    }
}

private struct UnallocatedChip: View {

    var body: some View {
        Text("Unallocated")
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(1)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundColor(.secondary)
            )
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

