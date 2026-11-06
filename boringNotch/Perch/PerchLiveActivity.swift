//
//  PerchLiveActivity.swift
//  Perch
//
//  Short Dynamic Island-style messages in the closed notch: the notch widens
//  for a couple of seconds with an icon on the left and a tinted label on the
//  right. Used for the launch greeting and system overload alerts.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    static let launchGreeting = Key<Bool>("perchLaunchGreeting", default: true)
}

@MainActor
final class PerchLiveActivity: ObservableObject {
    static let shared = PerchLiveActivity()

    struct Activity: Hashable {
        /// Asset catalog image (e.g. the app logo), or…
        var image: String? = nil
        /// …an SF Symbol drawn in `tint`.
        var symbol: String? = nil
        var tint: Color = .green
        var text: String
        fileprivate var id = UUID()
    }

    @Published private(set) var current: Activity?

    private init() {}

    func show(_ activity: Activity, for seconds: Double = 3) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { current = activity }
        let id = activity.id
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard current?.id == id else { return }
            withAnimation(.smooth(duration: 0.45)) { current = nil }
        }
    }

    /// "Perch is running" right after launch, so starting an app with no window
    /// gives visible feedback. Skipped on first launch, where onboarding greets.
    func greetIfEnabled() {
        guard Defaults[.launchGreeting], !BoringViewCoordinator.shared.firstLaunch else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            show(.init(image: "logo", tint: .green, text: "Perch"), for: 2.4)
        }
    }
}

/// Laid out like the closed-notch battery notification: content on both sides
/// of the camera housing, which the notch widens to make room for.
struct PerchLiveActivityView: View {
    let activity: PerchLiveActivity.Activity
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @State private var appeared = false

    private var iconSize: CGFloat { max(0, notchHeight - 12) }

    var body: some View {
        HStack(spacing: 0) {
            // Same width as the label on the right so the notch stays centered.
            ZStack(alignment: .leading) {
                label.hidden()
                icon
                    .scaleEffect(appeared ? 1 : 0.3)
                    .rotationEffect(.degrees(appeared ? 0 : -25))
                    .opacity(appeared ? 1 : 0)
            }
            .frame(minWidth: 76, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            label
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : -8)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .frame(height: notchHeight, alignment: .center)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.1)) { appeared = true }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = activity.image {
            Image(image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
        } else if let symbol = activity.symbol {
            Image(systemName: symbol)
                .font(.system(size: iconSize * 0.65, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: iconSize, height: iconSize)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activity.tint)
                .frame(width: 6, height: 6)
                .shadow(color: activity.tint.opacity(0.8), radius: appeared ? 4 : 0)
            Text(activity.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
