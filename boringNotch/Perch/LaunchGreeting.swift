//
//  LaunchGreeting.swift
//  Perch
//
//  A short "Perch is running" greeting in the closed notch right after launch,
//  so starting the app (which has no window or Dock icon) gives visible feedback.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    static let launchGreeting = Key<Bool>("perchLaunchGreeting", default: true)
}

@MainActor
final class LaunchGreeting: ObservableObject {
    static let shared = LaunchGreeting()

    @Published private(set) var isShowing = false

    private init() {}

    /// Shows the greeting for a couple of seconds. Skipped on the very first
    /// launch, where onboarding and the hello animation already greet the user.
    func showIfEnabled() {
        guard Defaults[.launchGreeting], !BoringViewCoordinator.shared.firstLaunch else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { isShowing = true }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.smooth(duration: 0.45)) { isShowing = false }
        }
    }
}

/// Laid out like the closed-notch battery notification: content on both sides
/// of the camera housing, which the notch widens to make room for.
struct LaunchGreetingView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @State private var appeared = false

    private var iconSize: CGFloat { max(0, notchHeight - 12) }

    var body: some View {
        HStack(spacing: 0) {
            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(appeared ? 1 : 0.3)
                .rotationEffect(.degrees(appeared ? 0 : -25))
                .opacity(appeared ? 1 : 0)
                .frame(width: 76, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            HStack(spacing: 5) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green.opacity(0.8), radius: appeared ? 4 : 0)
                Text("Perch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -8)
            .frame(width: 76, alignment: .trailing)
        }
        .frame(height: notchHeight, alignment: .center)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.1)) {
                appeared = true
            }
        }
    }
}
