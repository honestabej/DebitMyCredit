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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

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
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showAccountDetail = false

    var body: some View {
        let acctBalDate = account.balanceDate?.formatted(Date.FormatStyle().month(.defaultDigits).day().hour().minute()) ?? "Unknown"

        Button(action: { showAccountDetail = true }) {
            HStack(alignment: .top, spacing: 10) {
                
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
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.name ?? "")
                        .fontWeight(.heavy)
                        .font(.system(size: 19))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    
                    HStack() {
                        VStack() {
                            Text(account.availableBalance.map { availableBalance in
                                availableBalance.decimalValue as Decimal
                            }.map {
                                $0.formatted(.currency(code: "USD"))
                            } ?? "")
                                .fontWeight(.semibold)
                            Text("Balance")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.gray)
                        }
                        .padding(.leading, 20)
                        
                        Spacer()
                    }
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAccountDetail) {
            AccountView(account: account)
                .environment(\.managedObjectContext, viewContext)
                .presentationDragIndicator(.visible)
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
    account1.accountNumber = "1234"
    account1.availableBalance = NSDecimalNumber(value: 1234.56)
    account1.balanceDate = Date()

    let account2 = Account(context: context)
    account2.id = "2"
    account2.name = "Wells Fargo Checking"
    account2.bank = "Wells Fargo"
    account2.accountType = "Debit"
    account2.availableBalance = NSDecimalNumber(value: 567.89)
    account2.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())

    try? context.save()

    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(AuthManager(viewContext: context))
}


