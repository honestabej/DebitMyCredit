import SwiftUI

struct PageHeaderView<LeftButton: View>: View {
    @EnvironmentObject var authManager: AuthManager
    
    var title: String
    var leftButton: LeftButton?
    var includeRefresh: Bool
    
    var body: some View {
        HStack {
            if let leftButton { leftButton } else { placeholder }
            
            Spacer()
            
            Text(title)
                .font(.system(size: 25))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.top, 3)
            
            Spacer()
            
            if includeRefresh { refreshButton } else { placeholder }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // Placeholder when no button is shown
    private var placeholder: some View {
        Color.clear
            .frame(width: 18)
            .padding(.trailing, 20)
    }
    
    // Refresh button logic and UI
    @ViewBuilder
    private var refreshButton: some View {
        // Only show refresh button when not currently loading/syncing data
        if !authManager.isRefreshing && !authManager.isSyncingSimpleFIN && !authManager.isLoadingUserData {
            Button(action: {
                Task { await authManager.refreshData() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.trailing, 20)
            .padding(.top, 3)
        } else {
            placeholder
        }
    }
}
