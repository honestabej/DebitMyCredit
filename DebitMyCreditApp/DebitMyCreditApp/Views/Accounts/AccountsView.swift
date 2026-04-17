import SwiftUI
import CoreData

struct AccountsView: View {
    
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType == %@", "Debit"),
        animation: .default
    )
    private var accounts: FetchedResults<Account>
    
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
                    Text("Debit Accounts")
                        .font(.system(size: 25))
                        .fontWeight(.bold)
                        .padding(.top)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)

                    HStack {
                        Spacer()
                        Button(action: {
                            Task { await authManager.triggerSync() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.top)
                        .padding(.trailing, 20)
                    }
                }
                
                
                Spacer().frame(height: 45)
                
                accountsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        
    }
    
    // View to display the list of accounts
    private var accountsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(accounts) { account in
                    AccountRow(account: account)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    if account != accounts.last {
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            }
        }
    }
    
}

struct AccountRow: View {
    @ObservedObject var account: Account

    var body: some View {
        HStack(spacing: 12) {
            // Card Image
            ZStack () {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(Color.appPurple))
                    .frame(width: 100, height: 55)
                
                Text("Test")
            }
            
            VStack(alignment: .leading) {
                Text(account.name ?? "")
                Text(account.balanceDate?.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute()) ?? "")
                Text(account.accountBalance.map { balance in
                    balance.decimalValue as Decimal
                }.map {
                    $0.formatted(.currency(code: "USD"))
                } ?? "")
            }
            Spacer()
        }
    }
}

// View for each row
#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    let account1 = Account(context: context)
    account1.id = "1"
    account1.name = "Chase Checking"
    account1.bank = "Chase"
    account1.accountType = "Debit"
    account1.accountBalance = NSDecimalNumber(value: 1234.56)
    account1.balanceDate = Date()

    let account2 = Account(context: context)
    account2.id = "2"
    account2.name = "Wells Fargo Checking"
    account2.bank = "Wells Fargo"
    account2.accountType = "Debit"
    account2.accountBalance = NSDecimalNumber(value: 567.89)
    account2.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())

    try? context.save()

    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(AuthManager(viewContext: context))
}


