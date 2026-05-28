import SwiftUI
import CoreData

struct PaymentGroupView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext
    
    var paymentGroup: TransferGroup

    @State private var showErrorAlert = false
    @State private var errorMessage: String?
    @State private var isCompleting = false

    private var allocationSummary: (byAccount: [CoreDataService.PaidAllocationSummary], unallocated: Decimal) {
        CoreDataService.shared.fetchPaidAllocationSummary(for: paymentGroup)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                // Group name
                Text(paymentGroup.name ?? "Name not found")
                    .fontWeight(.heavy)
                    .font(.system(size: 24))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer().frame(height: 5)
                
                // Group payment amount
                Text(paymentGroup.totalAmount.formatted(.currency(code: "USD")))
                    .font(.system(size: 27))
                Text("Total Payment")
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        // Credit cards
                        Text("Credit Card(s)")
                            .fontWeight(.heavy)
                            .font(.system(size: 18))
                            .padding(.top, 5)
                        ForEach(paymentGroup.creditCards, id: \.account.objectID) { payment in
                            HStack {
                                Image(getBankCircleLogo(bankName: payment.account.bank?.lowercased() ?? ""))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 25, height: 25)
                                    .clipShape(Circle())
                                
                                Text(payment.account.name ?? "")
                                    .font(.system(size: 14))
                                
                                Spacer()
                                
                                Text(payment.amount.formatted(.currency(code: "USD")))
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // Allocations
                        Text("Debit Allocations")
                            .fontWeight(.heavy)
                            .font(.system(size: 18))
                            .padding(.top, 10)
                        if !allocationSummary.byAccount.isEmpty || allocationSummary.unallocated > 0 {
                            AllocationsListView(spacing: 6) {
                                ForEach(allocationSummary.byAccount, id: \.accountName) { summary in
                                    Text("\(summary.accountName) - \(summary.total.formatted(.currency(code: "USD")))")
                                        .font(.system(size: 12))
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Color(hex: summary.accountColor ?? "").opacity(0.4)
                                        )
                                        .clipShape(Capsule())
                                }
                                if allocationSummary.unallocated > 0 {
                                    Text("Unallocated - \(allocationSummary.unallocated.formatted(.currency(code: "USD")))")
                                        .font(.system(size: 12))
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.gray.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        
                        // Transactions
                        Text("Transactions")
                            .fontWeight(.heavy)
                            .font(.system(size: 18))
                            .padding(.top, 10)
                        ForEach(Array(paymentGroup.transactions as? Set<Transaction> ?? []), id: \.objectID) { transaction in
                            TransactionRow(transaction: transaction, fromPaymentGroup: true)
                        }
                        
                        Spacer().frame(height: 70)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                
                Spacer() // Align things to top
            }
            .padding(.top, 25)
            .padding(.horizontal, 15)
            
            if (paymentGroup.completed == false){
                Button {
                    completePaymentGroup()
                } label: {
                    Group {
                        if isCompleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Mark Payment Complete")
                                .foregroundStyle(Color.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 45)
                }
                .disabled(isCompleting)
                .glassEffect(.clear.tint(.appOrange), in: .rect(cornerRadius: 50))
                .padding(.horizontal, 40)
                .padding(.bottom, 25)
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong")
        }
        .ignoresSafeArea()
    }
    
    // Mark the payment group as complete
    func completePaymentGroup() {
        guard let groupID = paymentGroup.id,
              let token = KeychainHelper.get("auth_token") else { return }

        isCompleting = true

        Task {
            do {
                _ = try await APIService.shared.completePaymentGroup(id: groupID, token: token)
                await MainActor.run {
                    paymentGroup.completed = true
                    try? viewContext.save()
                    isCompleting = false
                }
            } catch {
                await MainActor.run {
                    isCompleting = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
}

#Preview("From Groups") {
    let context = PersistenceController.preview.container.viewContext
    return PaymentGroupsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Group") {
    let context = PersistenceController.preview.container.viewContext
    let request = TransferGroup.fetchRequest()
    request.predicate = NSPredicate(format: "name == %@", "Payment 1")
    request.fetchLimit = 1
    let tg1 = (try? context.fetch(request))?.first ?? TransferGroup(context: context)
    return PaymentGroupView(paymentGroup: tg1)
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}
