import SwiftUI
import UIKit

struct ConnectionRecoveryView: View {
    @Environment(AppStore.self) private var store
    let notice: ConnectionRecovery
    let onRemoved: () -> Void
    @State private var confirmRemoval = false

    private var removalRequired: Bool { notice == .credentialsInvalid || notice == .pairAgain }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "network.slash")
                .font(.system(size: 52)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(notice.title).font(.title.bold())
                Text(notice.message).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            VStack(spacing: 16) {
                if notice.canRetry {
                    Button {
                        Task { await store.retrySavedConnection() }
                    } label: {
                        Text("Try again").frame(maxWidth: .infinity)
                    }.modifier(RecoveryRetryButtonStyle(liquid: notice == .offline || notice == .unavailable || notice == .serviceUnavailable || notice == .credentialsUnavailable))
                        .accessibilityIdentifier("recovery.retry")
                }
                if notice == .credentialsInvalid || notice == .pairAgain {
                    Button { confirmRemoval = true } label: {
                        Text("Remove saved connection").frame(maxWidth: .infinity)
                    }
                    .modifier(RecoveryRetryButtonStyle(liquid: true))
                    .tint(.blue)
                    .accessibilityIdentifier("recovery.remove")
                } else if notice != .offline && notice != .unavailable && notice != .serviceUnavailable && notice != .credentialsUnavailable {
                    Button("Remove saved connection", role: .destructive) { confirmRemoval = true }
                        .accessibilityIdentifier("recovery.remove")
                }
            }.controlSize(.large)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            if notice == .unavailable {
                Button("Remove saved connection", role: .destructive) { confirmRemoval = true }
                    .accessibilityIdentifier("recovery.remove")
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .background {
            if confirmRemoval {
                SavedConnectionRemovalAlert(isPresented: $confirmRemoval, required: removalRequired) {
                    store.forgetSavedConnection()
                    onRemoved()
                }
            }
        }
    }
}


private struct RecoveryRetryButtonStyle: ViewModifier {
    let liquid: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), liquid {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}


// UIKit preserves a single destructive action; SwiftUI inserts Cancel automatically.
private struct SavedConnectionRemovalAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let required: Bool
    let onRemove: () -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter() }

    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.updatePresentation = { [weak controller] in
            guard let controller, isPresented, controller.activeAlert == nil else { return }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            let alert = UIAlertController(
                title: "Remove this saved connection?",
                message: "This removes its sign-in details from this device. Hermes and your conversations stay in place. It does not revoke this device’s pairing on an unreachable Hermes computer.",
                preferredStyle: .alert)
            if !required {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    controller.activeAlert = nil
                    isPresented = false
                })
            }
            alert.addAction(UIAlertAction(title: "Remove connection", style: .destructive) { _ in
                controller.activeAlert = nil
                isPresented = false
                onRemove()
            })
            controller.activeAlert = alert
            presenter.present(alert, animated: true)
        }
        DispatchQueue.main.async { controller.updatePresentation?() }
    }

    final class Presenter: UIViewController {
        var updatePresentation: (() -> Void)?
        weak var activeAlert: UIAlertController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation?()
        }
    }
}
