import AppKit
import Foundation
import IOKit

struct ResourceSnapshot {
    let cpuPercent: Double?
    let memory: MemorySample?
    let gpuPercent: Double?
    let capturedAt: Date
}

struct MemorySample {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let reclaimableBytes: UInt64

    var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

final class ResourceMonitor {
    private let cpuMonitor = CPUMonitor()
    private let gpuMonitor = GPUMonitor()

    func sample() -> ResourceSnapshot {
        ResourceSnapshot(
            cpuPercent: cpuMonitor.sample(),
            memory: MemoryMonitor.sample(),
            gpuPercent: gpuMonitor.sample(),
            capturedAt: Date()
        )
    }
}

final class CPUMonitor {
    private var previousInfo: processor_info_array_t?
    private var previousInfoCount: mach_msg_type_number_t = 0
    private var previousCPUCount: natural_t = 0

    deinit {
        deallocatePreviousInfo()
    }

    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let currentInfo = info else {
            return nil
        }

        let usage = calculateUsage(currentInfo: currentInfo, cpuCount: cpuCount)
        deallocatePreviousInfo()
        previousInfo = currentInfo
        previousInfoCount = infoCount
        previousCPUCount = cpuCount
        return usage
    }

    private func calculateUsage(currentInfo: processor_info_array_t, cpuCount: natural_t) -> Double? {
        guard let previousInfo, previousCPUCount == cpuCount else {
            return nil
        }

        var totalDiff: UInt64 = 0
        var idleDiff: UInt64 = 0
        let stateCount = Int(CPU_STATE_MAX)

        for cpuIndex in 0..<Int(cpuCount) {
            let offset = cpuIndex * stateCount
            let currentUser = UInt64(currentInfo[offset + Int(CPU_STATE_USER)])
            let currentSystem = UInt64(currentInfo[offset + Int(CPU_STATE_SYSTEM)])
            let currentIdle = UInt64(currentInfo[offset + Int(CPU_STATE_IDLE)])
            let currentNice = UInt64(currentInfo[offset + Int(CPU_STATE_NICE)])

            let previousUser = UInt64(previousInfo[offset + Int(CPU_STATE_USER)])
            let previousSystem = UInt64(previousInfo[offset + Int(CPU_STATE_SYSTEM)])
            let previousIdle = UInt64(previousInfo[offset + Int(CPU_STATE_IDLE)])
            let previousNice = UInt64(previousInfo[offset + Int(CPU_STATE_NICE)])

            let currentTotal = currentUser + currentSystem + currentIdle + currentNice
            let previousTotal = previousUser + previousSystem + previousIdle + previousNice

            totalDiff += currentTotal > previousTotal ? currentTotal - previousTotal : 0
            idleDiff += currentIdle > previousIdle ? currentIdle - previousIdle : 0
        }

        guard totalDiff > 0 else {
            return nil
        }

        return clampPercent((1 - Double(idleDiff) / Double(totalDiff)) * 100)
    }

    private func deallocatePreviousInfo() {
        guard let previousInfo else {
            return
        }

        let byteCount = vm_size_t(previousInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: previousInfo)),
            byteCount
        )

        self.previousInfo = nil
        previousInfoCount = 0
        previousCPUCount = 0
    }
}

enum MemoryMonitor {
    static func sample() -> MemorySample? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize == 0 ? vm_kernel_page_size : pageSize)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedPageCount = UInt64(
            statistics.internal_page_count +
                statistics.wire_count +
                statistics.compressor_page_count
        )
        let reclaimablePageCount = UInt64(
            statistics.external_page_count +
                statistics.purgeable_count +
                statistics.speculative_count
        )
        let usedBytes = min(totalBytes, usedPageCount * pageBytes)
        let reclaimableBytes = min(totalBytes - usedBytes, reclaimablePageCount * pageBytes)

        return MemorySample(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            reclaimableBytes: reclaimableBytes
        )
    }
}

final class GPUMonitor {
    private let performanceKeys = [
        "Device Utilization %",
        "Renderer Utilization %",
        "Tiler Utilization %",
        "GPU Core Utilization %",
        "GPU Utilization %"
    ]

    func sample() -> Double? {
        let classNames = ["IOAccelerator", "IOAccelerator2", "AGXAccelerator"]
        var samples: [Double] = []

        for className in classNames {
            samples.append(contentsOf: samplesForClass(named: className))
        }

        guard !samples.isEmpty else {
            return nil
        }

        return clampPercent(samples.max() ?? 0)
    }

    private func samplesForClass(named className: String) -> [Double] {
        guard let matchingDictionary = IOServiceMatching(className) else {
            return []
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }

        defer {
            IOObjectRelease(iterator)
        }

        var values: [Double] = []
        var service = IOIteratorNext(iterator)

        while service != 0 {
            if let statistics = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                values.append(contentsOf: performanceKeys.compactMap { utilization(from: statistics[$0]) })
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return values
    }

    private func utilization(from rawValue: Any?) -> Double? {
        if let number = rawValue as? NSNumber {
            return clampPercent(number.doubleValue)
        }

        if let value = rawValue as? Double {
            return clampPercent(value)
        }

        if let value = rawValue as? Int {
            return clampPercent(Double(value))
        }

        return nil
    }
}

final class ResourceBarApp: NSObject, NSApplicationDelegate {
    private let monitor = ResourceMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let contentController = ResourceToolbarViewController()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        startTimer()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.title = "--%"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.toolTip = "CPU usage"
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        contentController.onRefresh = { [weak self] in
            self?.refresh()
        }

        contentController.onQuit = {
            NSApp.terminate(nil)
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 170)
        popover.contentViewController = contentController
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let snapshot = monitor.sample()
        updateStatusItem(with: snapshot)
        contentController.update(with: snapshot)
    }

    private func updateStatusItem(with snapshot: ResourceSnapshot) {
        statusItem.button?.title = ResourceFormat.percent(snapshot.cpuPercent, unavailable: "--%")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

final class ResourceToolbarViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?

    private let cpuTile = MetricTileView(title: "CPU")
    private let ramTile = MetricTileView(title: "RAM")
    private let gpuTile = MetricTileView(title: "GPU")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    override func loadView() {
        let rootView = NSVisualEffectView()
        rootView.material = .popover
        rootView.blendingMode = .behindWindow
        rootView.state = .active

        let metricsStack = NSStackView(views: [cpuTile, ramTile, gpuTile])
        metricsStack.orientation = .horizontal
        metricsStack.distribution = .fillEqually
        metricsStack.spacing = 8

        timestampLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timestampLabel.textColor = .secondaryLabelColor

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed(_:)))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitPressed(_:)))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small

        let footerStack = NSStackView(views: [timestampLabel, NSView(), refreshButton, quitButton])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8

        let rootStack = NSStackView(views: [metricsStack, footerStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
            metricsStack.heightAnchor.constraint(equalToConstant: 112)
        ])

        view = rootView
    }

    func update(with snapshot: ResourceSnapshot) {
        cpuTile.update(
            value: ResourceFormat.percent(snapshot.cpuPercent),
            detail: "Total load",
            progress: snapshot.cpuPercent
        )

        if let memory = snapshot.memory {
            ramTile.update(
                value: ResourceFormat.percent(memory.percent),
                detail: "\(ResourceFormat.bytes(memory.usedBytes)) used, \(ResourceFormat.bytes(memory.reclaimableBytes)) cache",
                progress: memory.percent
            )
        } else {
            ramTile.update(value: "N/A", detail: "Unavailable", progress: nil)
        }

        if let gpuPercent = snapshot.gpuPercent {
            gpuTile.update(
                value: ResourceFormat.percent(gpuPercent),
                detail: "IOKit counter",
                progress: gpuPercent
            )
        } else {
            gpuTile.update(value: "N/A", detail: "No counter", progress: nil)
        }

        timestampLabel.stringValue = "Updated \(dateFormatter.string(from: snapshot.capturedAt))"
    }

    @objc private func refreshPressed(_ sender: NSButton) {
        onRefresh?()
    }

    @objc private func quitPressed(_ sender: NSButton) {
        onQuit?()
    }
}

final class MetricTileView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    init(title: String) {
        super.init(frame: .zero)
        setup(title: title)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(title: "")
    }

    private func setup(title: String) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.lineBreakMode = .byClipping
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar

        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            progressIndicator.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    func update(value: String, detail: String, progress: Double?) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail

        if let progress {
            progressIndicator.isHidden = false
            progressIndicator.doubleValue = clampPercent(progress)
        } else {
            progressIndicator.isHidden = true
            progressIndicator.doubleValue = 0
        }
    }
}

enum ResourceFormat {
    static func percent(_ value: Double?, unavailable: String = "N/A") -> String {
        guard let value else {
            return unavailable
        }

        return "\(Int(clampPercent(value).rounded()))%"
    }

    static func bytes(_ bytes: UInt64) -> String {
        let gibibytes = Double(bytes) / 1_073_741_824

        if gibibytes >= 10 {
            return "\(Int(gibibytes.rounded())) GB"
        }

        return String(format: "%.1f GB", gibibytes)
    }
}

func clampPercent(_ value: Double) -> Double {
    min(100, max(0, value))
}

let app = NSApplication.shared
let delegate = ResourceBarApp()
app.delegate = delegate
app.run()
