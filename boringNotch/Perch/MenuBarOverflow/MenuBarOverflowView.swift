//
//  MenuBarOverflowView.swift
//  Perch
//
//  Notch tab listing menu bar icons that are hidden behind the notch.
//

import SwiftUI

struct MenuBarOverflowView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = MenuBarOverflowManager.shared

    var body: some View {
        Group {
            switch manager.state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case .needsPermission:
                permissionPrompt
            case .loaded:
                if manager.hiddenItems.isEmpty {
                    EmptyStateView(message: "No menu bar icons are hidden by the notch")
                } else {
                    itemList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await manager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { _ in
            Task { await manager.refresh() }
        }
    }

    private var itemList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.hiddenItems) { item in
                    MenuBarOverflowItemButton(item: item) {
                        // Close the notch first so the item's menu isn't covered.
                        vm.close()
                        Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            await manager.open(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Text("Perch needs Accessibility access to show hidden menu bar icons.")
                .font(.system(size: 13))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            Button("Grant Access") {
                XPCHelperClient.shared.requestAccessibilityAuthorization()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 24)
    }
}

private struct MenuBarOverflowItemButton: View {
    let item: MenuBarOverflowItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .foregroundStyle(.gray)
                    }
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)

                Text(item.appName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 68, height: 68)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isHovering ? 0.12 : 0.0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.title.isEmpty ? item.appName : "\(item.appName): \(item.title)")
    }
}
