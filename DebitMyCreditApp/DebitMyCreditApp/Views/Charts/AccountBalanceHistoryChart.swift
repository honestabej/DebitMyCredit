import SwiftUI
import CoreData
import Combine

enum AccountBalanceHistoryRange: String, CaseIterable {
    case oneMonth = "1M"
    case sixMonths = "6M"
    case ytd = "YTD"
    case oneYear = "1Y"
    case allTime = "All"
}

struct AccountBalanceHistoryChart: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedRange: AccountBalanceHistoryRange = .oneMonth
    
    var body: some View {
        VStack(spacing: 8) {
            
            // Graph container
            ZStack(alignment: .top) {
                // Title and key
                HStack(alignment: .top) {
                    Text("Balance History")
                        .fontWeight(.bold)
                    
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            
            // Range selector
            HStack(spacing: 8) {
                ForEach(AccountBalanceHistoryRange.allCases, id: \.self) { range in
                    let isSelected = selectedRange == range
                    Group {
                        if isSelected {
                            Button(range.rawValue) { selectedRange = range }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        } else {
                            Button(range.rawValue) { selectedRange = range }
                                .font(.caption.weight(.regular))
                                .foregroundStyle(.black.opacity(0.65))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
}

#Preview("With Data") {
    let context = PersistenceController.preview.container.viewContext
    AccountBalanceHistoryChart()
        .environment(\.managedObjectContext, context)
}

#Preview("Empty State") {
    let context = PersistenceController.previewEmpty.container.viewContext
    AccountBalanceHistoryChart()
        .environment(\.managedObjectContext, context)
}



