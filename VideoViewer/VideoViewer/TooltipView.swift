import SwiftUI

struct TooltipView: ViewModifier {
    let text: String
    @State private var showTooltip = false
    
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                showTooltip = hovering
            }
            .overlay(
                Group {
                    if showTooltip {
                        HStack {
                            Spacer()
                            VStack {
                                Spacer()
                                Text(text)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                    .fixedSize()
                                    .transition(.opacity.combined(with: .scale))
                            }
                            .offset(x: -40, y: 30)
                        }
                        .animation(.easeInOut(duration: 0.15), value: showTooltip)
                    }
                }
                .allowsHitTesting(false)
            )
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(TooltipView(text: text))
    }
}