import SwiftUI
import CoreData

struct AccountsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.managedObjectContext) private var viewContext

    // Fetch all accounts except hidden/placeholder types, sorted by type then name
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Account.accountType, ascending: true),
            NSSortDescriptor(keyPath: \Account.name, ascending: true)
        ],
        predicate: NSPredicate(format: "accountType != %@ AND accountType != %@", "-", "Hide"),
        animation: .default
    )
    private var accounts: FetchedResults<Account>

    // Display order for known account types; unknown types fall at the end
    private let typeOrder = ["Cash", "Credit", "Investment", "Loan"]

    // Accounts grouped by type, in the defined display order
    private var groupedAccounts: [(type: String, accounts: [Account])] {
        let dict = Dictionary(grouping: accounts, by: { $0.accountType ?? "Other" })
        let knownTypes = typeOrder.filter { dict[$0] != nil }
        let otherTypes = dict.keys.filter { !typeOrder.contains($0) }.sorted()
        return (knownTypes + otherTypes).compactMap { type in
            guard let group = dict[type] else { return nil }
            return (type: type, accounts: group)
        }
    }
    
    var body: some View {
        ZStack () {
            // Background gradient
            Color.appGreen.ignoresSafeArea()
            
            // White background layer (decorative, extends behind tab bar)
            VStack {}
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.lightBackground)
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
                        .padding(.top, 3)
                    
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
                            .padding(.top, 3)
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
                ForEach(groupedAccounts, id: \.type) { group in
                    accountSection(title: group.type, accounts: group.accounts)
                }
            }
        }
    }

    @ViewBuilder
    private func accountSection(title: String, accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section {
                ForEach(accounts) { account in
                    AccountRow(account: account, useAvailableBalance: title == "Cash")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)

//                    if account != accounts.last {
//                        Divider()
//                            .padding(.leading, 20)
//                    }
                }
            } header: {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.lightBackground)
            }
        }
    }
    
}

struct AccountRow: View {
    @ObservedObject var account: Account
    var useAvailableBalance: Bool = true
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showAccountDetail = false

    var body: some View {
        Button(action: { showAccountDetail = true }) {
            HStack(alignment: .center, spacing: 10) {
//                // Card Image
//                ZStack {
//                    RoundedRectangle(cornerRadius: 8)
//                        .fill(getBankColor(bankName: account.bank?.lowercased() ?? ""))
//                        .frame(width: 110, height: 69)
//                    
//                    // Bank logo — top left
//                    VStack {
//                        HStack {
//                            Image(getBankTextLogo(bankName: account.bank?.lowercased() ?? ""))
//                                .resizable()
//                                .scaledToFit()
//                                .frame(maxHeight: 13)
//                                .padding([.top, .leading], 5)
//                            Spacer()
//                        }
//                        Spacer()
//                    }
//                    .frame(width: 100, height: 63)
//                    
//                    // Last 4 digits — bottom right
//                    VStack {
//                        Spacer()
//                        HStack {
//                            Spacer()
//                            if let acctNum = account.accountNumber, !acctNum.isEmpty {
//                                Text("•••• \(acctNum)")
//                                    .font(.system(size: 13, weight: .medium))
//                                    .foregroundColor(.white)
//                                    .padding(.bottom, 5)
//                                    .padding(.trailing, 8)
//                            }
//                        }
//                    }
//                    .frame(width: 110, height: 69)
//                }
                
                // Display corresponding Bank Logo
                Image(getBankCircleLogo(bankName: account.bank?.lowercased() ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 45, height: 45)
                    .clipShape(Circle())
                
                VStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name ?? "")
                            .fontWeight(.bold)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
//                        Spacer()
//                        HStack(spacing: 2) {
//                            Image(systemName: "clock")
//                            Text(timeSinceLastUpdate(from: account.balanceDate))
//                        }
                        .font(.caption2)
                        .foregroundColor(Color(uiColor: .gray))
                    }
                    
//                    Spacer()
                    
                    // Display the account number if available, and the time since last update
                    HStack {
                        if let accountNumber = account.accountNumber, !accountNumber.isEmpty {
                            Text("•••• \(accountNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("•")
                        }
                        
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                            Text(timeSinceLastUpdate(from: account.balanceDate))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    
//                    // Amount + label pairs
//                    VStack(alignment: .leading, spacing: 2) {
//                        let displayBalance = useAvailableBalance ? account.availableBalance : account.balance
//                        Text(displayBalance.map { $0.decimalValue as Decimal }
//                            .map { $0.formatted(.currency(code: "USD")) } ?? "")
//                            .font(.system(size: 20))
//                        
//                        Text(useAvailableBalance ? "Available" : "Balance")
//                            .font(.caption)
//                            .fontWeight(.semibold)
//                            .foregroundColor(.gray)
//                            .padding(.top, 1)
//                    }
                
                }
                .frame(maxWidth: .infinity, alignment: .leading)
//                .frame(height: 69)
                
                let displayBalance = useAvailableBalance ? account.availableBalance : account.balance
                Text(displayBalance.map { $0.decimalValue as Decimal }
                    .map { $0.formatted(.currency(code: "USD")) } ?? "")
                    .font(.system(size: 17))
                    .fontWeight(.bold)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAccountDetail) {
            AccountView(account: account)
                .environment(\.managedObjectContext, viewContext)
                .presentationDragIndicator(.visible)
        }
        .padding(8)
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
    }
}



// View for each row
#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewAuthManager())
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    return AccountsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(PersistenceController.previewEmptyAuthManager())
}


