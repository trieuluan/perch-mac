//
//  VisualizerSettingsView.swift
//  Perch
//
//  Settings > Visualizer: where visualizers appear and how they're colored.
//

import Defaults
import SwiftUI

struct VisualizerSettingsView: View {
    @Default(.visualizerColorMode) private var colorMode
    @Default(.visualizerGradient) private var gradient
    @Default(.playerBackground) private var playerBackground
    @Default(.menuBarOverlay) private var menuBarOverlay
    @Default(.menuBarOverlayIntensity) private var overlayIntensity

    private static let maxColors = 5

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .closedNotchBars) {
                    Text("Bars next to the album art")
                }
                Picker("Player background", selection: $playerBackground) {
                    ForEach(PlayerBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text(playerBackground.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Defaults.Toggle(key: .menuBarVisualizer) {
                    Text("Menu bar icon visualizer")
                }
            } header: {
                Text("Where to show")
            } footer: {
                Text("Visualizers follow the audio your Mac is playing. macOS asks for System Audio Recording access the first time; without it they fall back to a simple animation.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Effect", selection: $menuBarOverlay) {
                    ForEach(MenuBarOverlayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                if menuBarOverlay != .none {
                    HStack {
                        Text("Intensity")
                        Slider(value: $overlayIntensity, in: 0.2 ... 1)
                        Text("\(Int((overlayIntensity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Across the menu bar")
            } footer: {
                Text(menuBarOverlay.detail)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Color", selection: $colorMode) {
                    ForEach(VisualizerColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: colorMode) { _, mode in
                    // Album art colors are only computed while this upstream option is on.
                    VisualizerPalette.syncUpstreamColorSetting()
                }

                if colorMode == .custom {
                    presets
                    ForEach(gradient.indices, id: \.self) { index in
                        colorRow(index)
                    }
                    if gradient.count < Self.maxColors {
                        Button {
                            gradient.append(gradient.last ?? "#FFFFFF")
                        } label: {
                            Label("Add color", systemImage: "plus")
                        }
                    }
                }

                preview
            } header: {
                Text("Colors")
            } footer: {
                if colorMode == .custom {
                    Text("Colors blend left to right across each visualizer.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Visualizer")
    }

    private var presets: some View {
        HStack(spacing: 8) {
            Text("Presets")
            Spacer()
            ForEach(GradientPreset.all) { preset in
                Button {
                    gradient = preset.colors
                } label: {
                    Capsule()
                        .fill(LinearGradient(
                            colors: preset.colors.compactMap(Color.init(perchHex:)),
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 34, height: 16)
                        .overlay(Capsule().strokeBorder(.white.opacity(gradient == preset.colors ? 0.9 : 0.15)))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private func colorRow(_ index: Int) -> some View {
        HStack {
            ColorPicker(
                String(localized: "Color \(index + 1)"),
                selection: Binding(
                    get: { Color(perchHex: gradient[safe: index] ?? "") ?? .white },
                    set: { newValue in
                        guard gradient.indices.contains(index) else { return }
                        gradient[index] = newValue.perchHex
                    }
                ),
                supportsOpacity: false
            )
            if gradient.count > 1 {
                Button {
                    guard gradient.indices.contains(index) else { return }
                    gradient.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove color")
            }
        }
    }

    private var preview: some View {
        HStack {
            Text("Preview")
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(VisualizerPalette.horizontal())
                .frame(width: 180, height: 14)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
