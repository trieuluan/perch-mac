//
//  MenuBarVisualizer.swift
//  Perch
//
//  A small spectrum in the menu bar while music is playing. Clicking it
//  toggles play/pause. Toggle in Settings > General.
//

import AppKit
import Combine
import Defaults

@MainActor
final class MenuBarVisualizer {
    static let shared = MenuBarVisualizer()

    private static let barCount = 6
    private static let size = NSSize(width: 22, height: 14)

    private var statusItem: NSStatusItem?
    private var barsView: MenuBarBarsView?
    private var cancellables: Set<AnyCancellable> = []
    private var engineRunning = false

    private init() {}

    /// Call once at launch.
    func setup() {
        Defaults.publisher(.menuBarVisualizer)
            .map(\.newValue)
            .combineLatest(MusicManager.shared.$isPlaying.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, playing in
                MainActor.assumeIsolated { self?.update(enabled: enabled, playing: playing) }
            }
            .store(in: &cancellables)

        VisualizerEngine.shared.$levels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.engineRunning else { return }
                    self.barsView?.levels = VisualizerEngine.shared.levels(Self.barCount)
                }
            }
            .store(in: &cancellables)
    }

    private func update(enabled: Bool, playing: Bool) {
        let shouldShow = enabled && playing
        if shouldShow {
            if statusItem == nil { createItem() }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }

        if shouldShow != engineRunning {
            engineRunning = shouldShow
            if shouldShow {
                VisualizerEngine.shared.start()
            } else {
                VisualizerEngine.shared.stop()
                barsView?.levels = Array(repeating: 0, count: Self.barCount)
            }
        }
    }

    private func createItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.size.width + 8)
        item.autosaveName = "PerchVisualizer"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePlayback)
            button.toolTip = "Perch: click to play/pause"
            let bars = MenuBarBarsView(barCount: Self.barCount)
            bars.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(bars)
            NSLayoutConstraint.activate([
                bars.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                bars.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                bars.widthAnchor.constraint(equalToConstant: Self.size.width),
                bars.heightAnchor.constraint(equalToConstant: Self.size.height),
            ])
            barsView = bars
        }
        statusItem = item
    }

    @objc private func togglePlayback() {
        MusicManager.shared.togglePlay()
    }
}

/// Layer-backed bars that follow the menu bar's text color.
private final class MenuBarBarsView: NSView {
    private var bars: [CALayer] = []

    var levels: [CGFloat] = [] {
        didSet { layoutBars() }
    }

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0 ..< barCount {
            let bar = CALayer()
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        levels = Array(repeating: 0, count: barCount)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutBars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutBars()
    }

    private func layoutBars() {
        guard !bars.isEmpty else { return }
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }

        let spacing: CGFloat = 2
        let width = (bounds.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let level = i < levels.count ? levels[i] : 0
            let height = max(2, bounds.height * max(0.12, level))
            bar.backgroundColor = color
            bar.frame = CGRect(
                x: CGFloat(i) * (width + spacing),
                y: (bounds.height - height) / 2,
                width: width,
                height: height
            )
        }
        CATransaction.commit()
    }
}
