import SwiftUI

struct ToastView: View {
    let message: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSuccessToast: ViewModifier {
    @ObservedObject var model: MSIControlModel
    @ObservedObject var lighting: KeyboardLightingModel
    @ObservedObject var battery: BatteryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var dismissalID = UUID()

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)
    }

    func body(content: Content) -> some View {
        ZStack {
            content
            VStack {
                if showToast {
                    ToastView(message: toastMessage)
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
        }
        .onChange(of: model.successfulSettingsApplyCount) { _, _ in present() }
        .onChange(of: lighting.successfulApplyCount) { _, _ in present() }
        .onChange(of: battery.successfulApplyCount) { _, _ in present() }
        .task(id: dismissalID) {
            guard showToast else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                withAnimation(animation) { showToast = false }
            } catch {
                // A newer success replaces this dismissal task.
            }
        }
        .onDisappear { showToast = false }
    }

    private func present() {
        withAnimation(animation) {
            toastMessage = t("配置已成功应用")
            showToast = true
        }
        dismissalID = UUID()
    }
}
