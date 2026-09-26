import SwiftUI
import CoreData

struct CreatePaymentView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @State private var currentStep: Int = 1
    @State private var selectedAccount: Account? = nil
    @State private var showAccountDropdown: Bool = false
    @State private var checkedTransactionIDs: Set<UUID> = []

    @FetchRequest(
        entity: Account.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType == %@", "Credit")
    ) private var creditAccounts: FetchedResults<Account>

    var body: some View {
        VStack() {
            stepIndicator()
            Spacer()

            ZStack(alignment: .topLeading) {
                switch currentStep {
                case 1:
                    step1View()
                case 2:
                    step2View()
                case 3:
                    step3View()
                default:
                    Text("error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .id(currentStep)
            .transition(.opacity)
            .padding(.horizontal, 15)

            Spacer()
            bottomRow()
        }
        .padding(.top, 30)
    }

    @ViewBuilder
    private func stepIndicator() -> some View {
        HStack(spacing: 6) {
            ZStack {
                Text("Step 3 of 3")
                    .fontWeight(.semibold)
                    .hidden()
                Text("Step \(currentStep) of 3")
                    .fontWeight(.semibold)
            }
            .padding(.trailing, 10)
            .layoutPriority(1)

            ForEach(1...3, id: \.self) { i in
                Rectangle()
                    .fill(i <= currentStep ? Color.appOrange : Color.appOrange.opacity(0.12))
                    .frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 15)
    }

    @ViewBuilder
    private func bottomRow() -> some View {
        HStack(spacing: 10) {
            if currentStep > 1 {
                Button(action: { withAnimation(.easeInOut(duration: 0.5)) { currentStep -= 1 } }) {
                    Text("Back")
                        .fontWeight(.semibold)
                        .frame(maxWidth: 100)
                        .padding(.vertical, 12)
                        .glassEffect(.clear.tint(.appRed), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.5)),
                    removal: .move(edge: .leading).combined(with: .opacity).animation(.spring(response: 0.25, dampingFraction: 0.9))
                ))
            }
            let nextDisabled = currentStep == 1 && checkedTransactionIDs.isEmpty
            Button(action: {
                if currentStep < 3 {
                    withAnimation(.easeInOut(duration: 0.5)) { currentStep += 1 }
                } else {
                    // TODO: Create payment function
                }
            }) {
                Text(currentStep == 3 ? "Create Payment" : "Next")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassEffect(.clear.tint(nextDisabled ? .appOrange.opacity(0.5) : .appOrange), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(nextDisabled)
        }
        .clipped()
        .padding(.horizontal, 15)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentStep)
    }

    // MARK: Step 1 Setup
    @ViewBuilder
    private func step1View() -> some View {
        VStack(alignment: .leading) {
            Text("What are you paying off?")
                .font(.title2)
                .fontWeight(.bold)

            cardSelector()
                .zIndex(1)

            if selectedAccount != nil {
                transactionsList()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cardSelector() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAccountDropdown.toggle()
                }
            }) {
                HStack() {
                    if let account = selectedAccount {
                        Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name ?? "")
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if let acctNum = account.accountNumber, !acctNum.isEmpty {
                                Text("••••\(acctNum)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Select card")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAccountDropdown ? 180 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showAccountDropdown)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .cornerRadius(10)
                .shadow(color: .black.opacity(showAccountDropdown ? 0 : 0.07), radius: 4, x: 0, y: 2)
            }
            .tint(.black)
            .zIndex(1)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 7) {
                    Color.clear.frame(height: 50)
                    if showAccountDropdown {
                        cardSelectorDropdown()
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardSelectorDropdown() -> some View {
        VStack(spacing: 0) {
            ForEach(creditAccounts) { account in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedAccount = account
                        showAccountDropdown = false
                    }
                    let txIDs = ((account.transactions as? Set<Transaction>) ?? [])
                        .filter { $0.payment == nil && ($0.allocations?.count ?? 0) > 0 }
                        .compactMap(\.id)
                    checkedTransactionIDs = Set(txIDs)
                }) {
                    HStack {
                        Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name ?? "")
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if let acctNum = account.accountNumber, !acctNum.isEmpty {
                                Text("••••\(acctNum)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if selectedAccount == account {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appOrange)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                }
                .tint(.black)

                if account != creditAccounts.last {
                    Divider()
                        .padding(.horizontal, 14)
                }
            }
        }
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
    }

    // Groups unpaid, allocated transactions of the selected credit card by debit account.
    // Split transactions appear in each respective account's group with their allocated amount.
    var groupedAllocations: [(account: Account, allocations: [TransactionAllocation])] {
        guard let creditAccount = selectedAccount else { return [] }

        let transactions = (creditAccount.transactions as? Set<Transaction> ?? [])
            .filter { $0.payment == nil && ($0.allocations?.count ?? 0) > 0 }

        var groups: [Account: [TransactionAllocation]] = [:]
        for transaction in transactions {
            for case let allocation as TransactionAllocation in (transaction.allocations ?? []) {
                guard let debitAccount = allocation.account else { continue }
                groups[debitAccount, default: []].append(allocation)
            }
        }

        return groups
            .map { ($0.key, $0.value.sorted { ($0.transaction?.transactionDate ?? .distantPast) > ($1.transaction?.transactionDate ?? .distantPast) }) }
            .sorted { ($0.account.name ?? "") < ($1.account.name ?? "") }
    }

    @ViewBuilder
    private func transactionsList() -> some View {
        let groups = groupedAllocations
        let allTxIDs = Set(groups.flatMap(\.allocations).compactMap { $0.transaction?.id })
        let allChecked = !allTxIDs.isEmpty && allTxIDs.isSubset(of: checkedTransactionIDs)
        let checkedTotal = groups.flatMap(\.allocations)
            .filter { checkedTransactionIDs.contains($0.transaction?.id ?? UUID()) }
            .reduce(Decimal(0)) { $0 + ($1.amount as Decimal? ?? 0) }

        if groups.isEmpty {
            Text("No allocated unpaid transactions")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
        } else {
            // "All" checkbox header
            HStack {
                Image(systemName: allChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 26))
                    .foregroundStyle(allChecked ? Color.appOrange : Color.secondary)
                    .padding(.trailing, 3)
                    .onTapGesture {
                        if allChecked {
                            checkedTransactionIDs.subtract(allTxIDs)
                        } else {
                            checkedTransactionIDs.formUnion(allTxIDs)
                        }
                    }
                Text("All transactions")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(checkedTotal, format: .currency(code: "USD"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.account.objectID) { group in
                        let groupTxIDs = Set(group.allocations.compactMap { $0.transaction?.id })
                        let groupAllChecked = !groupTxIDs.isEmpty && groupTxIDs.isSubset(of: checkedTransactionIDs)
                        let checkedGroupTotal = group.allocations
                            .filter { checkedTransactionIDs.contains($0.transaction?.id ?? UUID()) }
                            .reduce(Decimal(0)) { $0 + ($1.amount as Decimal? ?? 0) }

                        VStack(alignment: .leading, spacing: 6) {
                            // Group header
                            HStack {
                                Image(systemName: groupAllChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 22))
                                    .foregroundStyle(groupAllChecked ? Color.appOrange : Color.secondary)
                                    .padding(.trailing, 3)
                                    .onTapGesture {
                                        if groupAllChecked {
                                            checkedTransactionIDs.subtract(groupTxIDs)
                                        } else {
                                            checkedTransactionIDs.formUnion(groupTxIDs)
                                        }
                                    }
                                Text(group.account.name ?? "Unknown")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(checkedGroupTotal, format: .currency(code: "USD"))
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 5)

                            // Transaction rows
                            VStack(spacing: 0) {
                                ForEach(group.allocations, id: \.objectID) { allocation in
                                    if let transaction = allocation.transaction {
                                        let txID = transaction.id ?? UUID()
                                        let isChecked = checkedTransactionIDs.contains(txID)
                                        let isSplit = (transaction.allocations?.count ?? 0) > 1

                                        HStack {
                                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 22))
                                                .foregroundStyle(isChecked ? Color.appOrange : Color.secondary)
                                                .padding(.trailing, 3)
                                                .onTapGesture {
                                                    if checkedTransactionIDs.contains(txID) {
                                                        checkedTransactionIDs.remove(txID)
                                                    } else {
                                                        checkedTransactionIDs.insert(txID)
                                                    }
                                                }
                                            HStack(spacing: 5) {
                                                Text(transaction.name ?? "")
                                                    .font(.subheadline)
                                                if isSplit {
                                                    Text("Split")
                                                        .font(.caption2)
                                                        .fontWeight(.semibold)
                                                        .foregroundStyle(.white)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(Color.gray)
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            Spacer()
                                            Text(allocation.amount as Decimal? ?? 0, format: .currency(code: "USD"))
                                                .font(.subheadline)
                                                .foregroundStyle(isChecked ? .primary : .secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color.white)

                                        if allocation.objectID != group.allocations.last?.objectID {
                                            Divider().padding(.horizontal, 12)
                                        }
                                    }
                                }
                            }
                            .cornerRadius(10)
                            .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: Step 2 Setup
    @ViewBuilder
    private func step2View() -> some View {
        VStack {
            Text("Step2")
            Rectangle()
                .fill(Color.appGreen)
                .frame(height: 30)
                .frame(width: 200)
        }
    }

    // MARK: Step 3 Setup
    @ViewBuilder
    private func step3View() -> some View {
        VStack {
            Text("Step3")
            Rectangle()
                .fill(Color.appPurple)
                .frame(height: 30)
                .frame(width: 200)
        }
    }
}

#Preview("From Parent View") {
    let context = PersistenceController.preview.container.viewContext
    return PaymentsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}
