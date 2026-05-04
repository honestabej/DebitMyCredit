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
    private var debitAccounts: FetchedResults<Account>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType == %@", "Credit"),
        animation: .default
    )
    private var creditAccounts: FetchedResults<Account>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.name, ascending: true)],
        predicate: NSPredicate(format: "accountType != %@ AND accountType != %@ AND accountType != %@", "Debit", "Credit", "N/A"),
        animation: .default
    )
    private var otherAccounts: FetchedResults<Account>
    
    var body: some View {
        ZStack () {
            // Background gradient
            AppGradients.horizontalGradient.ignoresSafeArea()
            
            // White background layer (decorative, extends behind tab bar)
            VStack {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, 295)
            
            // Actual Content
            VStack {
                // The area above the white space holding the accounts
                ZStack {
                    Text("Accounts")
                        .font(.system(size: 25))
                        .fontWeight(.bold)
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
                            .padding(.trailing, 20)
                        }
                    }
                }
                
                AccountsBalanceHistoryChart()
                    .frame(height: 230)
                
                accountsList
                    .padding(.top, 33)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        
    }
    
    // View to display the list of accounts grouped by type
    private var accountsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                accountSection(title: "Debit", accounts: Array(debitAccounts))
                accountSection(title: "Credit", accounts: Array(creditAccounts))
                accountSection(title: "Other", accounts: Array(otherAccounts))
            }
        }
    }

    @ViewBuilder
    private func accountSection(title: String, accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section {
                ForEach(accounts) { account in
                    AccountRow(account: account, useAvailableBalance: title == "Debit")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                    if account != accounts.last {
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            } header: {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.white)
            }
        }
    }
    
}

struct AccountRow: View {
    @ObservedObject var account: Account
    var useAvailableBalance: Bool = true
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showAccountDetail = false

    private func relativeTime(from date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86400 { return "\(seconds / 3600)hr" }
        return "\(seconds / 86400)d"
    }

    var body: some View {


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
                    

                }
                
                VStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name ?? "")
                            .fontWeight(.bold)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                            Text(relativeTime(from: account.balanceDate))
                        }
                        .font(.caption2)
                        .foregroundColor(Color(uiColor: .gray))
                    }
                    
                    Spacer()
                    
                    // Amount + label pairs
                    VStack(alignment: .leading, spacing: 2) {
                        let displayBalance = useAvailableBalance ? account.availableBalance : account.balance
                        Text(displayBalance.map { $0.decimalValue as Decimal }
                            .map { $0.formatted(.currency(code: "USD")) } ?? "")
                            .font(.system(size: 20))
                        
                        Text(useAvailableBalance ? "Available" : "Balance")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.gray)
                            .padding(.top, 1)
                    }
                
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 69)
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
    account1.accountType = "Credit"
    account1.accountNumber = "1234"
    account1.balance = NSDecimalNumber(value: 1234.56)
    account1.balanceDate = Date()

    let account2 = Account(context: context)
    account2.id = "2"
    account2.name = "Abe's Checking"
    account2.bank = "Wells Fargo"
    account2.accountType = "Debit"
    account2.accountNumber = "1234"
    account2.availableBalance = NSDecimalNumber(value: 567.89)
    account2.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    
    let account3 = Account(context: context)
    account3.id = "3"
    account3.name = "Shae's Checking"
    account3.bank = "Wells Fargo"
    account3.accountType = "Debit"
    account3.accountNumber = "1234"
    account3.availableBalance = NSDecimalNumber(value: 7554.89)
    account3.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    
    let account4 = Account(context: context)
    account4.id = "4"
    account4.name = "Apple HYSA"
    account4.bank = "Apple"
    account4.accountType = "Debit"
    account4.accountNumber = "1234"
    account4.availableBalance = NSDecimalNumber(value: 33089.78)
    account4.balanceDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
    
    let account6 = Account(context: context)
    account6.id = "1"
    account6.name = "ADP Retirement"
    account6.bank = "ADP"
    account6.accountType = "Other"
    account6.accountNumber = "1234"
    account6.balance = NSDecimalNumber(value: 6397103.89)
    account6.balanceDate = Date()

    try? context.save()

    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(AuthManager(viewContext: context))
}


