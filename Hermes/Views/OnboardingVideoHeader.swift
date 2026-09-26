import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class OnboardingVideo {
    // Sampled from the blue sky along the video's top edge.
    static let blue = Color(red: 5 / 255, green: 39 / 255, blue: 211 / 255)
    let player: AVPlayer

    init() {
        if let url = Bundle.main.url(forResource: "hermes-jr-onboarding", withExtension: "mp4") {
            player = AVPlayer(url: url)
        } else {
            player = AVPlayer()
        }
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }
}

struct OnboardingVideoHeader: View {
    let video: OnboardingVideo

    var body: some View {
        ZStack {
            Image("hermes-jr-onboarding-poster")
                .resizable()
                .scaledToFit()
            OnboardingPlayerSurface(player: video.player)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: OnboardingVideo.blue, location: 0),
                .init(color: OnboardingVideo.blue.opacity(0.9), location: 0.25),
                .init(color: OnboardingVideo.blue.opacity(0), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 120)
            .allowsHitTesting(false)
        }
        .clipped()
        .background(OnboardingVideo.blue)
        .accessibilityHidden(true)
    }
}

private struct OnboardingPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
