import AppKit
import QuartzCore

/// `Reclaim --stress-navigate` drives the real UI in and out of folders on a
/// timer while measuring main-thread frame intervals.
///
/// The `--bench-nav` numbers only cover layout and breakdown; this covers what
/// a user actually feels — SwiftUI updating the sidebar, the zoom animation, and
/// AppKit drawing — and is what a sampling profiler should be attached to.
@MainActor
final class NavigationStress {
    private weak var model: AppModel?
    private var driver: Timer?
    private var frameMonitor: Timer?
    private var lastTick = Date()
    private var intervals: [Double] = []
    /// Cost of one navigation: the model update plus the layout and draw it
    /// forces, measured synchronously. Runloop timer jitter alone is not a fair
    /// measure — macOS throttles a window that is not frontmost, which shows up
    /// as jank that a user looking at the app would never see.
    private var stepCosts: [Double] = []
    private var modelCosts: [Double] = []
    private var commitCosts: [Double] = []
    private var drawCosts: [Double] = []
    private var hoverCosts: [Double] = []
    private var goingIn = true
    private var steps = 0
    private let stepLimit: Int

    init(model: AppModel, steps: Int = 120) {
        self.model = model
        self.stepLimit = steps
    }

    func start() {
        Log.info("navigation stress started", ["steps": "\(stepLimit)"])
        lastTick = Date()

        // Records the gap between main-thread wake-ups: anything much over a
        // frame means navigation blocked the UI.
        let monitor = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.intervals.append(now.timeIntervalSince(self.lastTick) * 1000)
                self.lastTick = now
            }
        }
        RunLoop.main.add(monitor, forMode: .common)
        frameMonitor = monitor

        let hoverMode = CommandLine.arguments.contains("--stress-hover")
        let driver = Timer(timeInterval: hoverMode ? 0.016 : 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { hoverMode ? self?.hoverStep() : self?.step() }
        }
        RunLoop.main.add(driver, forMode: .common)
        self.driver = driver
    }

    /// Alternates the hover target as fast as the pointer plausibly could, to
    /// measure what a mouse move across the map costs.
    private func hoverStep() {
        guard let model, let zoomRoot = model.zoomRoot, zoomRoot.children.count > 1 else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        model.setHover(zoomRoot.children[steps % 2])
        CATransaction.flush()
        NSApp.windows.first(where: { $0.isVisible })?.contentView?.displayIfNeeded()
        hoverCosts.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        steps += 1
        if steps > stepLimit { finish() }
    }

    private func step() {
        guard let model, let scanRoot = model.scanRoot else { return }
        steps += 1
        if steps > stepLimit { finish(); return }

        let started = DispatchTime.now().uptimeNanoseconds
        if goingIn {
            let target = model.zoomRoot?.children.first {
                $0.isDirectory && !$0.children.isEmpty
            }
            if let target {
                model.zoom(into: target)
            } else {
                goingIn = false
            }
        } else {
            if model.zoomRoot === scanRoot {
                goingIn = true
            } else {
                model.zoomOut()
            }
        }
        let modelDone = DispatchTime.now().uptimeNanoseconds
        // Force the resulting update through: SwiftUI commits and the map
        // relayouts and draws, all on this thread, before we stop the clock.
        CATransaction.flush()
        let committed = DispatchTime.now().uptimeNanoseconds
        NSApp.windows.first(where: { $0.isVisible })?.contentView?.displayIfNeeded()
        let drawn = DispatchTime.now().uptimeNanoseconds

        modelCosts.append(Double(modelDone - started) / 1e6)
        commitCosts.append(Double(committed - modelDone) / 1e6)
        drawCosts.append(Double(drawn - committed) / 1e6)
        stepCosts.append(Double(drawn - started) / 1e6)
    }

    private func finish() {
        driver?.invalidate()
        frameMonitor?.invalidate()
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ p: Double) -> Double { sorted[Int(Double(sorted.count - 1) * p)] }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let costs = stepCosts.sorted()
        func costPercentile(_ p: Double) -> Double {
            costs.isEmpty ? 0 : costs[Int(Double(costs.count - 1) * p)]
        }
        Log.info("navigation stress finished", [
            "steps": "\(steps - 1)",
            "stepMedianMs": String(format: "%.2f", costPercentile(0.5)),
            "stepP95Ms": String(format: "%.2f", costPercentile(0.95)),
            "stepMaxMs": String(format: "%.2f", costs.last ?? 0),
            "stepsOver16ms": "\(costs.filter { $0 > 16 }.count)",
            "modelMedianMs": String(format: "%.2f", median(modelCosts)),
            "swiftUIMedianMs": String(format: "%.2f", median(commitCosts)),
            "drawMedianMs": String(format: "%.2f", median(drawCosts)),
            "frameMedianMs": String(format: "%.2f", percentile(0.5)),
            "frameP95Ms": String(format: "%.2f", percentile(0.95)),
            "frameMaxMs": String(format: "%.2f", sorted.last ?? 0),
            "hoverMedianMs": String(format: "%.2f", median(hoverCosts)),
            "hoverMaxMs": String(format: "%.2f", hoverCosts.max() ?? 0),
        ])
    }
}
