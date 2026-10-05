import SwiftUI

struct ContentStatusHeader: View {
    let status: ContentRefreshStatus
    var retry: (() -> Void)? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Button { retry?() } label: {
                Text(status.text(now: context.date))
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(retry == nil)
        }
        .accessibilityIdentifier("content.refreshStatus")
    }
}

struct ContentStatusSubtitle: ViewModifier {
    let status: ContentRefreshStatus
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content.navigationSubtitle(status.text(now: context.date))
            }
        } else { content }
    }
}

/// Keep the system navigation layout, with readable status text below large titles.
@MainActor
func configureContentNavigationAppearance() {
    if #available(iOS 26.0, *) {
        let bar = UINavigationBar.appearance()
        let standard = bar.standardAppearance.copy()
        standard.largeSubtitleTextAttributes[.font] = UIFont.preferredFont(forTextStyle: .body)
        bar.standardAppearance = standard
        let scrollEdge = bar.scrollEdgeAppearance?.copy() ?? UINavigationBarAppearance()
        if bar.scrollEdgeAppearance == nil { scrollEdge.configureWithTransparentBackground() }
        scrollEdge.largeSubtitleTextAttributes[.font] = UIFont.preferredFont(forTextStyle: .body)
        bar.scrollEdgeAppearance = scrollEdge
    }
}

/// A moving highlight clipped to the glyphs, leaving layout and text semantics intact.
struct ActivityTextShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion && scenePhase == .active {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible)) { context in
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            let band = max(24, width * 0.45)
                            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                            LinearGradient(colors: [.clear, Color.primary.opacity(0.85), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (width + band) * progress)
                        }
                        .mask(content)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}
