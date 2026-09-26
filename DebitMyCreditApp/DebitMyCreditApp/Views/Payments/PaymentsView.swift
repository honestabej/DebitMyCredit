import SwiftUI
import CoreData

struct PaymentsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State var showNewPayment: Bool = false
    @State private var paymentToDelete: Payment? = nil

    private var payments: [Payment] {
        guard let userID = authManager.currentUser?.id else { return [] }
        return CoreDataService.shared.fetchPayments(forUserID: userID, in: viewContext)
    }

    private var unpaidCreditSummary: (byAccount: [CoreDataService.UnpaidAllocationSummary], unallocated: Decimal) {
        guard let userID = authManager.currentUser?.id else { return ([], 0) }
        return CoreDataService.shared.fetchUnpaidCreditSummary(forUserID: userID, in: viewContext)
    }

    func deletePayment(_ payment: Payment) {
        guard let paymentID = payment.id,
              let token = KeychainHelper.get("auth_token") else { return }

        let linkedTransactions = Array((payment.value(forKey: "transactions") as? Set<Transaction>) ?? [])

        for tx in linkedTransactions { tx.payment = nil }
        viewContext.delete(payment)
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            return
        }

        Task {
            do {
                _ = try await APIService.shared.deletePayment(id: paymentID, token: token)
                await MainActor.run { paymentToDelete = nil }
            } catch {
                await MainActor.run {
                    let restoredPayment = Payment(context: viewContext)
                    restoredPayment.id = payment.id
                    restoredPayment.name = payment.name
                    restoredPayment.createdAt = payment.createdAt
                    restoredPayment.updatedAt = payment.updatedAt
                    restoredPayment.user = payment.user
                    for tx in linkedTransactions { tx.payment = restoredPayment }
                    try? viewContext.save()
                    paymentToDelete = nil
                }
            }
        }
    }

    var body: some View {
        // Background Color layer
        ZStack {
            Color.appGreen.ignoresSafeArea()

            // Actual content on top of background green
            VStack {
                PageHeaderView(title: "Payments", leftButton: EmptyView?.none, includeRefresh: true)

                // Summary of unpaid transactions
                VStack(alignment: .leading) {
                    Text("Unpaid Transactions")
                        .fontWeight(.bold)
                        .font(.system(size: 17))

                    if !unpaidCreditSummary.byAccount.isEmpty || unpaidCreditSummary.unallocated > 0 {
                        AllocationsListView(spacing: 6) {
                            ForEach(unpaidCreditSummary.byAccount, id: \.accountName) { summary in
                                Text("\(summary.accountName) - \(summary.total.formatted(.currency(code: "USD")))")
                                    .font(.system(size: 12))
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Color(hex: summary.accountColor ?? "#BDBDBD").opacity(0.41)
                                    )
                                    .clipShape(Capsule())
                            }
                            if unpaidCreditSummary.unallocated > 0 {
                                Text("Unallocated - \(unpaidCreditSummary.unallocated.formatted(.currency(code: "USD")))")
                                    .font(.system(size: 13))
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.25))
                                    .clipShape(Capsule())
                            }
                        }
                    } else {
                        Text("Payments up to date")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: 50)
                    }


                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(.horizontal, 15)
                .padding(.bottom, 10)

                // List of Payments
                List {
                    Color.clear
                        .frame(height: 0)
                        .listRowInsets(EdgeInsets(top: -20, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.lightBackground)
                        .listRowSeparator(.hidden)

                    if !payments.isEmpty {
                        Section {
                            ForEach(payments) { payment in
                                PaymentRow(payment: payment)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.lightBackground)
                                    .listRowSeparatorTint(Color.gray.opacity(0.3))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            paymentToDelete = payment
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text("Payment History")
                                    .font(.system(size: 17))
                                    .fontWeight(.semibold)
                                    .fixedSize()
                            }
                            .listRowInsets(EdgeInsets())
                            .padding(.horizontal, 15)
                            .padding(.top, 10)
                        }
                    }

                    // Bottom row to clear tabview
                    Color.clear
                        .frame(height: 90)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.lightBackground)
                        .listRowSeparator(.hidden)
                }
                .listSectionSpacing(0)
                .listStyle(.plain)
                .environment(\.defaultMinListHeaderHeight, 0)
                .environment(\.defaultMinListRowHeight, 0)
                .background(Color.lightBackground)
                .onAppear {
                    UITableView.appearance().sectionHeaderTopPadding = 1000
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .padding(.top, 8)
                .alert("Delete Payment", isPresented: Binding(
                    get: { paymentToDelete != nil },
                    set: { if !$0 { paymentToDelete = nil } }
                )) {
                    Button("Delete", role: .destructive) {
                        if let payment = paymentToDelete { deletePayment(payment) }
                    }
                    Button("Cancel", role: .cancel) { paymentToDelete = nil }
                } message: {
                    Text("Are you sure you want to delete \(paymentToDelete?.name ?? "this payment")?")
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // Button to create a new payment — pinned bottom-right above tab bar
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showNewPayment = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 60, height: 60)
                    .glassEffect(.clear.tint(.appOrange), in: .rect(cornerRadius: 50))
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 1, y: 4)
                    .opacity(showNewPayment ? 0 : 1)
                    .sheet(isPresented: $showNewPayment) {
                        NavigationStack {
                            CreatePaymentView()
                        }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .background(Color.lightBackground)
                    }

                }
            }
        }
    }
}

struct PaymentRow: View {
    @ObservedObject var payment: Payment
    @State var showPaymentDetail: Bool = false

    var body: some View {
        Button {
            showPaymentDetail = true
        } label: {
            HStack {
                Text(payment.name ?? "Name not found")
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Spacer()

                Text(payment.totalAmount.formatted(.currency(code: "USD")))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(payment.completed ? Color.green : Color.appOrange)
                    .frame(width: 8, height: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .frame(height: 45)
        .buttonStyle(.plain)
        .sheet(isPresented: $showPaymentDetail) {
            NavigationStack {
                PaymentView(payment: payment)
            }
            .presentationDetents([.height(650)])
            .presentationDragIndicator(.visible)
        }
    }
}

struct NewPaymentView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State private var paymentName: String = ""
    @State private var checkedIDs: Set<UUID> = []
    @State private var isSaving: Bool = false
    @State private var isSavingMessage: String = "Creating Payment..."
    @State private var showErrorAlert = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successfulMessage: String = "Payment created!"
    @Environment(\.dismiss) private var dismiss

    // The 0-based index for the new payment (equal to the current count of existing payments).
    private var newPaymentIndex: Int {
        guard let userID = authManager.currentUser?.id else { return 0 }
        return CoreDataService.shared.fetchPayments(forUserID: userID, in: viewContext).count
    }

    // Unpaid credit transactions that have at least one allocation (but no Payment yet).
    private var unpaidAllocatedTransactions: [Transaction] {
        guard let userID = authManager.currentUser?.id else { return [] }
        let request: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        request.predicate = NSPredicate(
            format: "user.id == %@ AND account.accountType == %@ AND payment == nil AND allocations.@count > 0",
            userID as CVarArg,
            "Credit"
        )
        request.sortDescriptors = [NSSortDescriptor(key: "transactionDate", ascending: false)]
        return (try? viewContext.fetch(request)) ?? []
    }

    var body: some View {
        ZStack {
            VStack {
                TextField("", text: $paymentName)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.primary)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    let allIDs = Set(unpaidAllocatedTransactions.compactMap(\.id))
                    let allChecked = !allIDs.isEmpty && allIDs.isSubset(of: checkedIDs)
                    Image(systemName: allChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 23))
                        .foregroundStyle(allChecked ? Color.appOrange : Color.secondary)
                        .padding(.trailing, 3)
                        .onTapGesture {
                            if allChecked {
                                checkedIDs.subtract(allIDs)
                            } else {
                                checkedIDs.formUnion(allIDs)
                            }
                        }

                    Text("Add Transactions:")
                        .font(.system(size: 20))
                        .fontWeight(.semibold)

                    Spacer()
                }
                .padding(.top, 10)

                // Display each transaction that is unpaid and allocated that can be entered into this new payment
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(unpaidAllocatedTransactions) { transaction in
                            let id = transaction.id ?? UUID()
                            let isChecked = checkedIDs.contains(id)
                            HStack {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 23))
                                    .foregroundStyle(isChecked ? Color.appOrange : Color.secondary)
                                    .padding(.trailing, 3)
                                    .onTapGesture {
                                        if checkedIDs.contains(id) {
                                            checkedIDs.remove(id)
                                        } else {
                                            checkedIDs.insert(id)
                                        }
                                    }

                                TransactionRow(transaction: transaction, fromPaymentGroup: true)
                            }
                            .padding(.bottom, 10)
                        }
                    }
                }
                .padding(.top, 5)

                Button {
                    createPayment()
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Create")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 37)
                .background(Color.appOrange)
                .foregroundColor(.white)
                .cornerRadius(10)
                .fontWeight(.bold)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .navigationTitle("New Payment")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                paymentName = "Group \(newPaymentIndex)"
                // Mark all transactions as checked by default
                checkedIDs = Set(unpaidAllocatedTransactions.compactMap(\.id))
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Something went wrong")
            }
            .alert("Success", isPresented: $showSuccessAlert) {
                Button("OK") { dismiss() }
                    .tint(.blue)
            } message: {
                Text(successfulMessage)
            }

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
    }

    // Save the payment into CoreData first, then persist to the server.
    // If the server call fails, the CoreData record is deleted.
    func createPayment() {
        guard let userID = authManager.currentUser?.id,
              let token = KeychainHelper.get("auth_token") else { return }

        let name = paymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Group \(newPaymentIndex)" : paymentName

        let existingNames = CoreDataService.shared.fetchPayments(forUserID: userID, in: viewContext).map { $0.name ?? "" }
        guard !existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A payment named \"\(name)\" already exists."
            showErrorAlert = true
            return
        }

        let selectedTransactions = unpaidAllocatedTransactions.filter { checkedIDs.contains($0.id ?? UUID()) }
        let transactionIDs = selectedTransactions.compactMap(\.id)
        let paymentID = UUID()
        let now = Date()

        // Save to CoreData
        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        guard let userEntity = try? viewContext.fetch(userFetch).first else { return }

        let newPayment = Payment(context: viewContext)
        newPayment.id = paymentID
        newPayment.name = name
        newPayment.createdAt = now
        newPayment.user = userEntity

        for tx in selectedTransactions {
            tx.payment = newPayment
        }

        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            errorMessage = "Failed to save locally. Please try again."
            showErrorAlert = true
            return
        }

        // Persist to server
        isSaving = true

        Task {
            do {
                let isoFormatter = ISO8601DateFormatter()
                let nowString = isoFormatter.string(from: now)

                // Derive creditCardAccountID from the first selected transaction's account
                let creditCardAccountID = selectedTransactions.first?.account?.id ?? UUID()

                // Build paymentAccounts by grouping allocation amounts per debit account
                var accountTotals: [UUID: (id: UUID, amount: Double)] = [:]
                for tx in selectedTransactions {
                    let allocations = (tx.allocations?.allObjects as? [TransactionAllocation]) ?? []
                    for alloc in allocations {
                        guard let accountID = alloc.account?.id else { continue }
                        let amount = abs((alloc.amount ?? .zero).doubleValue)
                        if let existing = accountTotals[accountID] {
                            accountTotals[accountID] = (existing.id, existing.amount + amount)
                        } else {
                            accountTotals[accountID] = (UUID(), amount)
                        }
                    }
                }
                let paymentAccounts = accountTotals.map { (accountID, entry) in
                    APIModels.PaymentAccountEntry(id: entry.id, accountInternalID: accountID, paymentAmount: entry.amount)
                }

                let payload = APIModels.CreatePayment(
                    id: paymentID,
                    userID: userID,
                    name: name,
                    paymentType: "direct",
                    creditCardAccountID: creditCardAccountID,
                    transactionIDs: transactionIDs,
                    paymentAccounts: paymentAccounts,
                    createdAt: nowString,
                    updatedAt: nowString
                )
                let _ = try await APIService.shared.createPayment(payment: payload, token: token)
                print("[NewPaymentView] Payment saved to server")
                await MainActor.run {
                    isSaving = false
                    showSuccessAlert = true
                }
            } catch {
                print("[NewPaymentView] Server save failed, reverting CoreData: \(error.localizedDescription)")
                // Revert: unlink transactions and delete the payment
                await MainActor.run {
                    for tx in selectedTransactions {
                        tx.payment = nil
                    }
                    viewContext.delete(newPayment)
                    try? viewContext.save()
                    isSaving = false
                    errorMessage = "Failed to save to server. Please try again."
                    showErrorAlert = true
                }
            }
        }
    }

    // Delete the payment from CoreData first, then delete from the server.
    // If the server call fails, the CoreData record is restored.
    func deletePayment(_ payment: Payment) {
        guard let paymentID = payment.id,
              let token = KeychainHelper.get("auth_token") else { return }

        // Snapshot the linked transactions so we can restore the relationship if the server call fails
        let linkedTransactions = Array((payment.value(forKey: "transactions") as? Set<Transaction>) ?? [])

        // Unlink transactions and delete the payment from CoreData
        for tx in linkedTransactions { tx.payment = nil }
        viewContext.delete(payment)
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            return
        }

        Task {
            do {
                _ = try await APIService.shared.deletePayment(id: paymentID, token: token)
            } catch {
                // Revert: restore the payment and re-link transactions
                await MainActor.run {
                    let restoredPayment = Payment(context: viewContext)
                    restoredPayment.id = payment.id
                    restoredPayment.name = payment.name
                    restoredPayment.createdAt = payment.createdAt
                    restoredPayment.updatedAt = payment.updatedAt
                    restoredPayment.user = payment.user
                    for tx in linkedTransactions { tx.payment = restoredPayment }
                    try? viewContext.save()
                }
            }
        }
    }
}

#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return PaymentsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}
