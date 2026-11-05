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
        VStack(spacing: 6) {
            items
            if manager.unreachableItemID != nil {
                Text("Perch can't open this item while the notch hides it. Make room in the menu bar to reach it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
            } else if !manager.showsRealIcons {
                Button {
                    manager.requestRealIcons()
                } label: {
                    Label("Show real menu bar icons", systemImage: "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.gray)
                .help("Needs Screen Recording access, used only to picture the hidden icons.")
            }
        }
    }

    private var items: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.hiddenItems) { item in
                    MenuBarOverflowItemButton(item: item) {
                        // Close the notch first so the item's menu isn't covered. Items
                        // Perch can't open keep it open to show why.
                        let closesNotch = item.axIndex != nil
                        if closesNotch { vm.close() }
                        Task {
                            if closesNotch { try? await Task.sleep(for: .milliseconds(200)) }
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

    private var name: String { item.appName ?? String(localized: "Menu item") }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon
                    .frame(width: 48, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(item.image != nil ? 0.08 : 0))
                    )

                Text(name)
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
        .help(item.title.isEmpty ? name : "\(name): \(item.title)")
    }

    /// The real menu bar image when available, otherwise the app's icon.
    @ViewBuilder
    private var icon: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 40, maxHeight: 24)
        } else if let appIcon = item.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(.gray)
        }
    }
}
