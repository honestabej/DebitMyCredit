import SwiftUI
import CoreData

struct PaymentGroupsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State var showNewPaymentGroup: Bool = false
    @State private var groupToDelete: TransferGroup? = nil

    private var transferGroups: [TransferGroup] {
        guard let userID = authManager.currentUser?.id else { return [] }
        return CoreDataService.shared.fetchTransferGroups(forUserID: userID, in: viewContext)
    }

    private var unpaidCreditSummary: (byAccount: [CoreDataService.UnpaidAllocationSummary], unallocated: Decimal) {
        guard let userID = authManager.currentUser?.id else { return ([], 0) }
        return CoreDataService.shared.fetchUnpaidCreditSummary(forUserID: userID, in: viewContext)
    }

    func deletePaymentGroup(_ group: TransferGroup) {
        guard let groupID = group.id,
              let token = KeychainHelper.get("auth_token") else { return }

        let linkedTransactions = (group.transactions?.allObjects as? [Transaction]) ?? []

        for tx in linkedTransactions { tx.transferGroup = nil }
        viewContext.delete(group)
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            return
        }

        Task {
            do {
                _ = try await APIService.shared.deletePaymentGroup(id: groupID, token: token)
                await MainActor.run { groupToDelete = nil }
            } catch {
                await MainActor.run {
                    let restoredGroup = TransferGroup(context: viewContext)
                    restoredGroup.id = group.id
                    restoredGroup.name = group.name
                    restoredGroup.createdAt = group.createdAt
                    restoredGroup.updatedAt = group.updatedAt
                    restoredGroup.user = group.user
                    for tx in linkedTransactions { tx.transferGroup = restoredGroup }
                    try? viewContext.save()
                    groupToDelete = nil
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
                PageHeaderView(title: "Payment Groups", leftButton: EmptyView?.none, includeRefresh: true)
                
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
                
                // List of Payment Groups
                List {
                    let manualGroups = transferGroups.filter { $0.name == "Manual" }
                    let customGroups = transferGroups.filter { $0.name != "Manual" }

                    if !manualGroups.isEmpty {
                        PaymentGroupRow(paymentGroup: manualGroups[0])
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.lightBackground)
                            .padding(.top, 10)
                    }

                    if !customGroups.isEmpty {
                        Section {
                            ForEach(customGroups) { group in
                                PaymentGroupRow(paymentGroup: group)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.lightBackground)
                                    .listRowSeparatorTint(Color.gray.opacity(0.3))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            groupToDelete = group
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Text("Payment Groups")
                        }
                    }

                    Color.clear
                        .frame(height: 90)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.lightBackground)
                        .listRowSeparator(.hidden)
                }
                .listSectionSpacing(0)
                .listStyle(.plain)
                .background(Color.lightBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .padding(.top, 10)
                .alert("Delete Payment Group", isPresented: Binding(
                    get: { groupToDelete != nil },
                    set: { if !$0 { groupToDelete = nil } }
                )) {
                    Button("Delete", role: .destructive) {
                        if let group = groupToDelete { deletePaymentGroup(group) }
                    }
                    Button("Cancel", role: .cancel) { groupToDelete = nil }
                } message: {
                    Text("Are you sure you want to delete \(groupToDelete?.name ?? "this payment group")?")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            
            // Button to create a new payment group — pinned bottom-right above tab bar
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showNewPaymentGroup = true
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
                    .opacity(showNewPaymentGroup ? 0 : 1)
                    .sheet(isPresented: $showNewPaymentGroup) {
                        NavigationStack {
                            NewPaymentGroupView()
                        }
                        .presentationDetents([.height(650)])
                        .presentationDragIndicator(.visible)
                    }
                    
                }
            }
        }
    }
}

struct PaymentGroupRow: View {
    @ObservedObject var paymentGroup: TransferGroup
    @State var showPaymentGroupDetail: Bool = false

    var body: some View {
        Button {
            showPaymentGroupDetail = true
        } label: {
            HStack {
                Text(paymentGroup.name ?? "Name not found")
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text(paymentGroup.totalAmount.formatted(.currency(code: "USD")))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(paymentGroup.completed ? Color.green : Color.appOrange)
                    .frame(width: 8, height: 8)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 20)
//            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPaymentGroupDetail) {
            NavigationStack {
                PaymentGroupView(paymentGroup: paymentGroup)
            }
            .presentationDetents([.height(650)])
            .presentationDragIndicator(.visible)
        }
    }
}

struct NewPaymentGroupView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    @State private var paymentGroupName: String = ""
    @State private var checkedIDs: Set<UUID> = []
    @State private var isSaving: Bool = false
    @State private var isSavingMessage: String = "Creating Payment Group..."
    @State private var showErrorAlert = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var successfulMessage: String = "Payment group created!"
    @Environment(\.dismiss) private var dismiss

    // The 0-based index for the new group (equal to the current count of existing groups).
    private var newGroupIndex: Int {
        guard let userID = authManager.currentUser?.id else { return 0 }
        return CoreDataService.shared.fetchTransferGroups(forUserID: userID, in: viewContext).count
    }

    // Unpaid credit transactions that have at least one allocation (but no TransferGroup yet).
    private var unpaidAllocatedTransactions: [Transaction] {
        guard let userID = authManager.currentUser?.id else { return [] }
        let request: NSFetchRequest<Transaction> = NSFetchRequest(entityName: "Transaction")
        request.predicate = NSPredicate(
            format: "user.id == %@ AND account.accountType == %@ AND transferGroup == nil AND allocations.@count > 0",
            userID as CVarArg,
            "Credit"
        )
        request.sortDescriptors = [NSSortDescriptor(key: "transactionDate", ascending: false)]
        return (try? viewContext.fetch(request)) ?? []
    }

    var body: some View {
        ZStack {
            VStack {
                TextField("", text: $paymentGroupName)
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

                // Display each transaction that is unpaid and allocated that can be entered into this new payment group
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
                    createPaymentGroup()
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
            .navigationTitle("New Payment Group")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                paymentGroupName = "Group \(newGroupIndex)"
                // Mark all transaction as checked by default
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
    
    // Save the payment group into CoreData first, then persist to the server.
    // If the server call fails, the CoreData record is deleted.
    func createPaymentGroup() {
        guard let userID = authManager.currentUser?.id,
              let token = KeychainHelper.get("auth_token") else { return }

        let name = paymentGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Group \(newGroupIndex)" : paymentGroupName

        let existingNames = CoreDataService.shared.fetchTransferGroups(forUserID: userID, in: viewContext).map { $0.name ?? "" }
        guard !existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A payment group named \"\(name)\" already exists."
            showErrorAlert = true
            return
        }

        let selectedTransactions = unpaidAllocatedTransactions.filter { checkedIDs.contains($0.id ?? UUID()) }
        let transactionIDs = selectedTransactions.compactMap(\.id)
        let groupID = UUID()
        let now = Date()

        // Save to CoreData
        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userID as CVarArg)
        guard let userEntity = try? viewContext.fetch(userFetch).first else { return }

        let newGroup = TransferGroup(context: viewContext)
        newGroup.id = groupID
        newGroup.name = name
        newGroup.createdAt = now
        newGroup.user = userEntity

        for tx in selectedTransactions {
            tx.transferGroup = newGroup
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
                let payload = APIModels.CreatePaymentGroup(
                    id: groupID,
                    userID: userID,
                    name: name,
                    transactionIDs: transactionIDs,
                    completed: false,
                    createdAt: .string(nowString),
                    updatedAt: .string(nowString)
                )
                let _ = try await APIService.shared.createPaymentGroup(paymentGroup: payload, token: token)
                print("[NewPaymentGroupView] Payment group saved to server")
                await MainActor.run {
                    isSaving = false
                    showSuccessAlert = true
                }
            } catch {
                print("[NewPaymentGroupView] Server save failed, reverting CoreData: \(error.localizedDescription)")
                // Revert: unlink transactions and delete the group
                await MainActor.run {
                    for tx in selectedTransactions {
                        tx.transferGroup = nil
                    }
                    viewContext.delete(newGroup)
                    try? viewContext.save()
                    isSaving = false
                    errorMessage = "Failed to save to server. Please try again."
                    showErrorAlert = true
                }
            }
        }
    }
    
    // Delete the payment group from CoreData first, then delete from the server.
    // If the server call fails, the CoreData record is restored.
    func deletePaymentGroup(_ group: TransferGroup) {
        guard let groupID = group.id,
              let token = KeychainHelper.get("auth_token") else { return }

        // Snapshot the linked transactions so we can restore the relationship if the server call fails
        let linkedTransactions = (group.transactions?.allObjects as? [Transaction]) ?? []

        // Unlink transactions and delete the group from CoreData
        for tx in linkedTransactions { tx.transferGroup = nil }
        viewContext.delete(group)
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            return
        }

        Task {
            do {
                _ = try await APIService.shared.deletePaymentGroup(id: groupID, token: token)
            } catch {
                // Revert: restore the group and re-link transactions
                await MainActor.run {
                    let restoredGroup = TransferGroup(context: viewContext)
                    restoredGroup.id = group.id
                    restoredGroup.name = group.name
                    restoredGroup.createdAt = group.createdAt
                    restoredGroup.updatedAt = group.updatedAt
                    restoredGroup.user = group.user
                    for tx in linkedTransactions { tx.transferGroup = restoredGroup }
                    try? viewContext.save()
                }
            }
        }
    }
}

#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return PaymentGroupsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}
