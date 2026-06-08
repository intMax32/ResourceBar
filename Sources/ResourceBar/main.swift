import AppKit
import Darwin
import Foundation
import IOKit

struct AppResourceUsage {
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

struct ResourceLeader {
    let name: String
    let value: String
}

struct ResourceSnapshot {
    let cpuPercent: Double?
    let memory: MemorySample?
    let gpuPercent: Double?
    let topCPUApps: [AppResourceUsage]
    let topRAMApps: [AppResourceUsage]
    let topGPUApps: [AppResourceUsage]
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
    private let processMonitor = ProcessResourceMonitor()

    func sample() -> ResourceSnapshot {
        let processSample = processMonitor.sample()

        return ResourceSnapshot(
            cpuPercent: cpuMonitor.sample(),
            memory: MemoryMonitor.sample(),
            gpuPercent: gpuMonitor.sample(),
            topCPUApps: processSample.topCPUApps,
            topRAMApps: processSample.topRAMApps,
            topGPUApps: [],
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

final class ProcessResourceMonitor {
    private struct ProcessSnapshot {
        let name: String
        let cpuTimeNanoseconds: UInt64
        let memoryBytes: UInt64
    }

    private struct AppAggregate {
        var cpuPercent: Double = 0
        var memoryBytes: UInt64 = 0
    }

    private var previousSnapshotsByPID: [pid_t: ProcessSnapshot] = [:]
    private var previousSampleDate: Date?

    func sample() -> (topCPUApps: [AppResourceUsage], topRAMApps: [AppResourceUsage]) {
        let now = Date()
        let snapshotsByPID = collectProcessSnapshots()
        let interval = previousSampleDate.map { now.timeIntervalSince($0) } ?? 0
        var aggregatesByName: [String: AppAggregate] = [:]

        for (pid, snapshot) in snapshotsByPID {
            var aggregate = aggregatesByName[snapshot.name] ?? AppAggregate()
            aggregate.memoryBytes += snapshot.memoryBytes

            if interval > 0, let previousSnapshot = previousSnapshotsByPID[pid] {
                let currentTime = snapshot.cpuTimeNanoseconds
                let previousTime = previousSnapshot.cpuTimeNanoseconds
                let timeDelta = currentTime > previousTime ? currentTime - previousTime : 0
                aggregate.cpuPercent += Double(timeDelta) / 1_000_000_000 / interval * 100
            }

            aggregatesByName[snapshot.name] = aggregate
        }

        previousSnapshotsByPID = snapshotsByPID
        previousSampleDate = now

        let usages = aggregatesByName.map { name, aggregate in
            AppResourceUsage(
                name: name,
                cpuPercent: aggregate.cpuPercent,
                memoryBytes: aggregate.memoryBytes
            )
        }

        let topCPUApps = interval > 0
            ? usages
                .filter { $0.cpuPercent >= 0.1 }
                .sorted { $0.cpuPercent == $1.cpuPercent ? $0.name < $1.name : $0.cpuPercent > $1.cpuPercent }
                .prefix(3)
            : []

        let topRAMApps = usages
            .filter { $0.memoryBytes > 0 }
            .sorted { $0.memoryBytes == $1.memoryBytes ? $0.name < $1.name : $0.memoryBytes > $1.memoryBytes }
            .prefix(3)

        return (Array(topCPUApps), Array(topRAMApps))
    }

    private func collectProcessSnapshots() -> [pid_t: ProcessSnapshot] {
        let pidByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidByteCount > 0 else {
            return [:]
        }

        let pidCapacity = Int(pidByteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let returnedByteCount = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        let returnedCount = max(0, Int(returnedByteCount) / MemoryLayout<pid_t>.stride)
        var snapshotsByPID: [pid_t: ProcessSnapshot] = [:]

        for pid in pids.prefix(returnedCount) where pid > 0 {
            guard let snapshot = snapshot(for: pid) else {
                continue
            }

            snapshotsByPID[pid] = snapshot
        }

        return snapshotsByPID
    }

    private func snapshot(for pid: pid_t) -> ProcessSnapshot? {
        var taskInfo = proc_taskinfo()
        let taskInfoSize = MemoryLayout<proc_taskinfo>.stride
        let result = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, Int32(taskInfoSize))
        }

        guard result == Int32(taskInfoSize) else {
            return nil
        }

        let name = displayName(for: pid)
        guard !name.isEmpty else {
            return nil
        }

        return ProcessSnapshot(
            name: name,
            cpuTimeNanoseconds: taskInfo.pti_total_user + taskInfo.pti_total_system,
            memoryBytes: taskInfo.pti_resident_size
        )
    }

    private func displayName(for pid: pid_t) -> String {
        if let appName = appBundleName(for: pid) {
            return appName
        }

        if let runningApp = NSRunningApplication(processIdentifier: pid),
           let localizedName = runningApp.localizedName,
           !localizedName.isEmpty {
            return localizedName
        }

        return processName(for: pid) ?? "PID \(pid)"
    }

    private func appBundleName(for pid: pid_t) -> String? {
        let pathBufferSize = 4096
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        let result = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(pathBufferSize))
        }

        guard result > 0 else {
            return nil
        }

        let path = String(cString: pathBuffer)
        let components = path.split(separator: "/")
        guard let appComponent = components.first(where: { $0.hasSuffix(".app") }) else {
            return nil
        }

        return String(appComponent.dropLast(4))
    }

    private func processName(for pid: pid_t) -> String? {
        let nameBufferSize = 256
        var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
        let result = nameBuffer.withUnsafeMutableBytes { buffer in
            proc_name(pid, buffer.baseAddress, UInt32(nameBufferSize))
        }

        guard result > 0 else {
            return nil
        }

        return String(cString: nameBuffer)
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
        popover.contentSize = NSSize(width: 760, height: 380)
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
    private let cpuTopList = TopAppsListView(title: "CPU Top 3")
    private let ramTopList = TopAppsListView(title: "RAM Top 3")
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

        let topListsContainer = NSView()
        topListsContainer.translatesAutoresizingMaskIntoConstraints = false
        cpuTopList.translatesAutoresizingMaskIntoConstraints = false
        ramTopList.translatesAutoresizingMaskIntoConstraints = false
        topListsContainer.addSubview(cpuTopList)
        topListsContainer.addSubview(ramTopList)

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

        let rootStack = NSStackView(views: [metricsStack, topListsContainer, footerStack])
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
            metricsStack.heightAnchor.constraint(equalToConstant: 142),
            topListsContainer.heightAnchor.constraint(equalToConstant: 150),
            cpuTopList.leadingAnchor.constraint(equalTo: topListsContainer.leadingAnchor),
            cpuTopList.topAnchor.constraint(equalTo: topListsContainer.topAnchor),
            cpuTopList.bottomAnchor.constraint(equalTo: topListsContainer.bottomAnchor),
            cpuTopList.trailingAnchor.constraint(equalTo: ramTopList.leadingAnchor, constant: -10),
            ramTopList.trailingAnchor.constraint(equalTo: topListsContainer.trailingAnchor),
            ramTopList.topAnchor.constraint(equalTo: topListsContainer.topAnchor),
            ramTopList.bottomAnchor.constraint(equalTo: topListsContainer.bottomAnchor),
            cpuTopList.widthAnchor.constraint(equalTo: ramTopList.widthAnchor)
        ])

        view = rootView
    }

    func update(with snapshot: ResourceSnapshot) {
        cpuTile.update(
            value: ResourceFormat.percent(snapshot.cpuPercent),
            detail: "Total load",
            progress: snapshot.cpuPercent,
            leaders: nil,
            emptyText: "Sampling..."
        )
        cpuTopList.update(
            leaders: snapshot.topCPUApps.map {
                ResourceLeader(name: $0.name, value: ResourceFormat.precisePercent($0.cpuPercent))
            },
            emptyText: "Sampling..."
        )

        if let memory = snapshot.memory {
            ramTile.update(
                value: ResourceFormat.percent(memory.percent),
                detail: "\(ResourceFormat.bytes(memory.usedBytes)) used, \(ResourceFormat.bytes(memory.reclaimableBytes)) cache",
                progress: memory.percent,
                leaders: nil,
                emptyText: "No process data"
            )
            ramTopList.update(
                leaders: snapshot.topRAMApps.map {
                    ResourceLeader(name: $0.name, value: ResourceFormat.bytes($0.memoryBytes))
                },
                emptyText: "No process data"
            )
        } else {
            ramTile.update(value: "N/A", detail: "Unavailable", progress: nil, leaders: nil, emptyText: "No process data")
            ramTopList.update(leaders: [], emptyText: "No process data")
        }

        if let gpuPercent = snapshot.gpuPercent {
            gpuTile.update(
                value: ResourceFormat.percent(gpuPercent),
                detail: "IOKit counter",
                progress: gpuPercent,
                leaders: nil,
                emptyText: ""
            )
        } else {
            gpuTile.update(value: "N/A", detail: "No counter", progress: nil, leaders: nil, emptyText: "")
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
    private let topHeaderLabel = NSTextField(labelWithString: "Top 3")
    private let leaderRows = [LeaderRowView(), LeaderRowView(), LeaderRowView()]

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

        topHeaderLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        topHeaderLabel.textColor = .tertiaryLabelColor

        let leadersStack = NSStackView(views: leaderRows)
        leadersStack.orientation = .vertical
        leadersStack.alignment = .width
        leadersStack.spacing = 4

        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel, progressIndicator, topHeaderLabel, leadersStack])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
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

    func update(value: String, detail: String, progress: Double?, leaders: [ResourceLeader]?, emptyText: String) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail

        if let progress {
            progressIndicator.isHidden = false
            progressIndicator.doubleValue = clampPercent(progress)
        } else {
            progressIndicator.isHidden = true
            progressIndicator.doubleValue = 0
        }

        if let leaders {
            topHeaderLabel.isHidden = false
            updateLeaders(leaders, emptyText: emptyText)
        } else {
            topHeaderLabel.isHidden = true
            leaderRows.forEach { $0.isHidden = true }
        }
    }

    private func updateLeaders(_ leaders: [ResourceLeader], emptyText: String) {
        if leaders.isEmpty {
            leaderRows[0].update(name: emptyText, value: "")
            leaderRows[0].isHidden = false

            for row in leaderRows.dropFirst() {
                row.isHidden = true
            }

            return
        }

        for (index, row) in leaderRows.enumerated() {
            if index < leaders.count {
                row.update(name: leaders[index].name, value: leaders[index].value)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
    }
}

final class TopAppsListView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let leaderRows = [LeaderRowView(), LeaderRowView(), LeaderRowView()]

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
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let rowsStack = NSStackView(views: leaderRows)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 6

        let stack = NSStackView(views: [titleLabel, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    func update(leaders: [ResourceLeader], emptyText: String) {
        if leaders.isEmpty {
            leaderRows[0].update(name: emptyText, value: "")
            leaderRows[0].isHidden = false

            for row in leaderRows.dropFirst() {
                row.isHidden = true
            }

            return
        }

        for (index, row) in leaderRows.enumerated() {
            if index < leaders.count {
                row.update(name: leaders[index].name, value: leaders[index].value)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
    }
}

final class LeaderRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -10),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17)
        ])
    }

    func update(name: String, value: String) {
        nameLabel.stringValue = name
        valueLabel.stringValue = value
    }
}

enum ResourceFormat {
    static func percent(_ value: Double?, unavailable: String = "N/A") -> String {
        guard let value else {
            return unavailable
        }

        return "\(Int(clampPercent(value).rounded()))%"
    }

    static func precisePercent(_ value: Double) -> String {
        if value >= 10 {
            return "\(Int(value.rounded()))%"
        }

        return String(format: "%.1f%%", max(0, value))
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
