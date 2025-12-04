import SwiftUI

struct HomeView: View {
    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Button(action: {}) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Red Button")

                Button(action: {}) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Blue Button")

                Button(action: {}) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Green Button")

                Button(action: {}) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Orange Button")

                Button(action: {}) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Purple Button")
            }
            .padding(20)
        }
    }
}

#Preview {
    HomeView()
}
