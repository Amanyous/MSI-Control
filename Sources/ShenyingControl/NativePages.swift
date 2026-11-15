import Charts
import ECControl
import KeyboardLighting
import SwiftUI
import SystemSensors

private struct DiskCapacityProgressStyle: ProgressViewStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
                }
        }
        .frame(height: 4)
    }
}

struct ContentView: View {
    @ObservedObject var model: MSIControlModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            switch model.section {
            case .dashboard: DashboardPage(model: model, monitor: model.monitor)
            case .fan: FanPage(model: model)
            case .lighting: LightingPage(lighting: model.lighting)
            case .battery: BatteryPage(battery: model.battery)
            case .drivers: DriverConfigurationPage(model: model, monitor: model.monitor)
            case .settings: ApplicationSettingsPage()
            case .about: ApplicationAboutPage()
            }
        }
        .modifier(SettingsSuccessToast(
            model: model, lighting: model.lighting, battery: model.battery
        ))
        .navigationTitle(model.section.title)
        .transaction {
            // Transparency and contrast do not imply a request to disable motion.
            if reduceMotion { $0.animation = nil }
        }
    }
}

struct DashboardPage: View {
    @ObservedObject var model: MSIControlModel
    @ObservedObject var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayValues = Array(repeating: 0.0, count: 10)
    @State private var isRefreshing = false
    @State private var refreshRotation = 0.0
    @State private var displayMemoryFraction = 0.0
    @State private var displayDiskFraction = 0.0
    @State private var showCopyToast = false
    @State private var copyFeedback = false
    private enum BootPhase {
        case waiting, sweeping, holding, returning, live
    }
    @State private var bootPhase: BootPhase = .waiting
    private var isBootSweeping: Bool { bootPhase != .live }
    private var maxima: [Double] {
        [100, 6, 6000, 6000, 150, 100, 100, 100, 100,
         max(1, (monitor.gpuStatus?.memoryTotalBytes ?? 0) / 1_000_000_000)]
    }
    private let metricColumns = Array(repeating: GridItem(.flexible(minimum: 112), spacing: 16, alignment: .top), count: 4)

    private var actualValues: [Double] {
        [
            monitor.sensors.temperature.value,
            monitor.displayedFrequency.value,
            monitor.sensors.fan.value,
            monitor.sensors.fan2.value,
            monitor.sensors.power.value,
            monitor.cpuUsage * 100,
            monitor.gpuStatus?.temperature,
            monitor.gpuStatus?.coreUsage,
            monitor.gpuStatus?.videoDecodeUsage,
            monitor.gpuStatus?.memoryUsedBytes.map { $0 / 1_000_000_000 }
        ].map { value in
            guard let value, value.isFinite else { return 0 }
            return max(0, value)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(t("systemMonitor")).font(.headline)
                    Spacer()
                    if (monitor.sensors.temperature.value ?? 0) > 85 {
                        Label("温度偏高", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Text(localized("updatedAt", monitor.lastUpdated.formatted(date: .omitted, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("CPU").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(
                    columns: metricColumns,
                    alignment: .center,
                    spacing: 20
                ) {
                SensorMetric(title: t("cpuTemperature"), reading: monitor.sensors.temperature, displayValue: displayValues[0], isBootSweeping: isBootSweeping, unit: "°C", maximum: maxima[0], temperatureWarning: true)
                SensorMetric(title: t("cpuFrequency"), reading: monitor.displayedFrequency, displayValue: displayValues[1], isBootSweeping: isBootSweeping, unit: "GHz", maximum: maxima[1])
                SensorMetric(title: t("cpuPower"), reading: monitor.sensors.power, displayValue: displayValues[4], isBootSweeping: isBootSweeping, unit: "W", maximum: maxima[4])
                SensorMetric(
                    title: t("cpuUsage"),
                    reading: SensorReading(
                        value: monitor.cpuUsage * 100,
                        source: "host_processor_info",
                        issue: nil
                    ),
                    displayValue: displayValues[5],
                    isBootSweeping: isBootSweeping,
                    unit: "%",
                    maximum: maxima[5]
                )
                }
                Text("GPU").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                LazyVGrid(
                    columns: metricColumns,
                    alignment: .center,
                    spacing: 20
                ) {
                    SensorMetric(title: "GPU 温度", reading: SensorReading(value: monitor.gpuStatus?.temperature, source: "NVAccel · Temperature(C)", issue: nil), displayValue: displayValues[6], isBootSweeping: isBootSweeping, unit: "°C", maximum: maxima[6], temperatureWarning: true, sourceLabel: "Core Temp")
                    SensorMetric(title: "显存占用", reading: SensorReading(value: monitor.gpuStatus?.memoryUsedBytes.map { $0 / 1_000_000_000 }, source: "NVAccel · inUseVidMemoryBytes / VRAM,totalsize", issue: nil), displayValue: displayValues[9], isBootSweeping: isBootSweeping, unit: "GB", maximum: maxima[9], sourceLabel: monitor.gpuStatus?.memoryTotalBytes.map { String(format: "Total %.1f GB", $0 / 1_000_000_000) } ?? "Total — GB")
                    SensorMetric(title: "GPU 占用", reading: SensorReading(value: monitor.gpuStatus?.coreUsage, source: "NVAccel · GPU Core Utilization %", issue: nil), displayValue: displayValues[7], isBootSweeping: isBootSweeping, unit: "%", maximum: maxima[7], sourceLabel: "Core Usage")
                    SensorMetric(title: "GPU 视频解码", reading: SensorReading(value: monitor.gpuStatus?.videoDecodeUsage, source: "NVAccel · GPU Video Decode Utilization %", issue: nil), displayValue: displayValues[8], isBootSweeping: isBootSweeping, unit: "%", maximum: maxima[8], sourceLabel: "Video Engine")
                }
                Text("散热").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                LazyVGrid(columns: metricColumns, alignment: .center, spacing: 20) {
                    SensorMetric(title: t("sensorFanSpeed"), reading: monitor.sensors.fan, displayValue: displayValues[2], isBootSweeping: isBootSweeping, unit: "RPM", maximum: maxima[2], decimals: 0)
                    SensorMetric(title: t("sensorFan2Speed"), reading: monitor.sensors.fan2, displayValue: displayValues[3], isBootSweeping: isBootSweeping, unit: "RPM", maximum: maxima[3], decimals: 0)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("performance")).font(.headline)
                    Text(translated(model.performanceStatus)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(t("sceneMode"), selection: Binding(
                    get: { model.performanceMode }, set: { if let mode = $0 { model.applyPerformance(mode) } }
                )) {
                    if model.performanceMode == nil {
                        Text(t("unrecognized")).tag(nil as PerformanceMode?)
                    }
                    ForEach([PerformanceMode.quiet, .balanced, .performance], id: \.self) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 290)
                .disabled(model.performanceBusy || model.performanceMode == nil)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(t("deviceStatus")).font(.headline).padding(.top, 8)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow(t("power"), translated(monitor.powerSource))
                        statusRow(t("ecDriver"), translated(monitor.ecStatus))
                        statusRow(t("ecIdentity"), translated(monitor.ecIdentity))
                        statusRow(t("coresThreads"), "\(monitor.physicalCPUs) / \(monitor.logicalCPUs)")
                        statusRow("电池健康度", model.battery.battery.healthPercent.map { String(format: "%.1f%% · 正常", $0) } ?? "—")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("内存使用率", monitor.memorySummary)
                        ProgressView(value: displayMemoryFraction)
                            .progressViewStyle(DiskCapacityProgressStyle(
                                color: displayMemoryFraction > 0.85 ? .orange : .accentColor
                            ))
                            .labelsHidden()
                            .accessibilityLabel("内存使用率")
                            .padding(.vertical, 2)
                            .animation(reduceMotion ? nil : .spring(duration: 0.5), value: displayMemoryFraction)
                        if let disk = monitor.diskInfo {
                            HStack {
                                Text("磁盘 (\(disk.name))").foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(disk.name)
                                Spacer()
                                Text(monitor.diskSummary).foregroundStyle(.primary).monospacedDigit()
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                    .contentTransition(.numericText())
                            }
                            .frame(maxWidth: .infinity)
                            .help("已用空间与主磁盘总容量")
                            ProgressView(value: displayDiskFraction)
                                .progressViewStyle(DiskCapacityProgressStyle(
                                    color: displayDiskFraction > 0.9 ? .red : .accentColor
                                ))
                                .labelsHidden()
                                .accessibilityLabel("磁盘使用率")
                                .padding(.vertical, 2)
                                .animation(reduceMotion ? nil : .spring(duration: 0.5), value: displayDiskFraction)
                            statusRow("磁盘格式", disk.format)
                        } else {
                            statusRow("磁盘状态", "—")
                        }
                        statusRow(t("thermalState"), translated(monitor.thermalState))
                        statusRow("系统运行时间", monitor.uptimeSummary)
                    }
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isRefreshing = true
                    refreshRotation += 360
                    monitor.refresh()
                    model.readPerformance()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        isRefreshing = false
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(refreshRotation))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: refreshRotation)
                        Text(t("refresh"))
                    }
                }.labelStyle(.titleAndIcon).help(t("refresh"))
            }
            ToolbarItem {
                Menu {
                    Button {
                        monitor.copyPowerSampleCommand()
                        copyFeedback = true
                        showCopyToast = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copyFeedback = false
                            showCopyToast = false
                        }
                    } label: {
                        Label(copyFeedback ? "✓ 已复制" : t("copySample"), systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help(t("copySample"))
            }
        }
        .overlay(alignment: .top) {
            if showCopyToast {
                ToastView(message: "采样命令已复制")
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { monitor.dashboardDidAppear(); model.readPerformance() }
        .task(id: reduceMotion) { await playBootSweep() }
        .task(id: reduceMotion) { await playResourceBootSweep() }
        .onChange(of: monitor.memoryFraction) { _, value in
            guard monitor.hasPlayedResourceBootAnimation else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.5)) {
                displayMemoryFraction = value
            }
        }
        .onChange(of: monitor.diskInfo?.usageFraction) { _, value in
            guard monitor.hasPlayedResourceBootAnimation else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.5)) {
                displayDiskFraction = value ?? 0
            }
        }
        .onChange(of: actualValues) { _, values in
            guard bootPhase == .live else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.4)) {
                displayValues = values
            }
        }
        .onDisappear {
            bootPhase = .live
            displayValues = actualValues
        }
    }

    private func playResourceBootSweep() async {
        guard !monitor.hasPlayedResourceBootAnimation else {
            displayMemoryFraction = monitor.memoryFraction
            displayDiskFraction = monitor.diskInfo?.usageFraction ?? 0
            return
        }
        // Mark before sleeping so leaving and re-entering the page cannot replay it.
        monitor.hasPlayedResourceBootAnimation = true
        displayMemoryFraction = 0
        displayDiskFraction = 0
        guard !reduceMotion else {
            displayMemoryFraction = monitor.memoryFraction
            displayDiskFraction = monitor.diskInfo?.usageFraction ?? 0
            return
        }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.8)) {
            displayMemoryFraction = 1
            displayDiskFraction = 1
        }
        try? await Task.sleep(for: .milliseconds(1100))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            displayMemoryFraction = monitor.memoryFraction
            displayDiskFraction = monitor.diskInfo?.usageFraction ?? 0
        }
        try? await Task.sleep(for: .milliseconds(800))
    }

    @MainActor
    private func playBootSweep() async {
        guard !Task.isCancelled else { return }
        guard !monitor.hasPlayedBootAnimation, !reduceMotion else {
            monitor.hasPlayedBootAnimation = true
            bootPhase = .live
            displayValues = actualValues
            return
        }
        monitor.hasPlayedBootAnimation = true
        bootPhase = .waiting
        displayValues = Array(repeating: 0, count: maxima.count)
        do {
            // Give the zero state one layout pass before beginning the shared sweep.
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            bootPhase = .sweeping
            withAnimation(.easeOut(duration: 0.8)) {
                displayValues = maxima
            }
            try await Task.sleep(for: .milliseconds(800))
            try Task.checkCancellation()
            bootPhase = .holding
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            bootPhase = .returning
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                displayValues = actualValues
            }
            try await Task.sleep(for: .milliseconds(800))
            try Task.checkCancellation()
            bootPhase = .live
            // Samples received while returning are reconciled without changing sampling.
            withAnimation(.snappy(duration: 0.4)) {
                displayValues = actualValues
            }
        } catch {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                bootPhase = .live
                displayValues = actualValues
            }
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).foregroundStyle(.primary).multilineTextAlignment(.trailing).monospacedDigit()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct SensorMetric: View {
    let title: String
    let reading: SensorReading
    let displayValue: Double
    let isBootSweeping: Bool
    let unit: String
    let maximum: Double
    var decimals = 1
    var temperatureWarning = false
    var sourceLabel: String? = nil
    private var conciseSource: String {
        guard reading.value != nil, reading.issue == nil else { return "N/A" }
        if let sourceLabel { return sourceLabel }
        if let source = reading.source {
            if source.hasPrefix("MSR 0x198") { return "MSR 0x198" }
            if source.hasPrefix("EC ") {
                return source.split(separator: " ").prefix(2).joined(separator: " ")
            }
            if source.hasPrefix("host_processor") { return "host_processor" }
            if source.hasPrefix("SMC ") { return source }
            return source.split(separator: " ").first.map(String.init) ?? source
        }
        return "N/A"
    }
    private var fullSource: String {
        translated(reading.issue ?? reading.source ?? t("sensorMissing"))
    }
    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: min(maximum, max(0, displayValue)), in: 0...maximum) {
                EmptyView()
            }
            .gaugeStyle(SweepGaugeStyle(
                maximum: maximum,
                decimals: decimals,
                unit: unit,
                showsValue: isBootSweeping || reading.value != nil,
                temperatureWarning: temperatureWarning
            ))
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(conciseSource)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 128)
                .frame(height: 16, alignment: .top)
                .help(fullSource)
        }
        .frame(minWidth: 112, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(reading.formatted(decimals: decimals)) \(unit)")
        .accessibilityHint(translated(reading.issue ?? reading.source ?? ""))
    }
}

private struct SweepGaugeStyle: GaugeStyle {
    let maximum: Double
    let decimals: Int
    let unit: String
    let showsValue: Bool
    let temperatureWarning: Bool

    func makeBody(configuration: Configuration) -> some View {
        SweepGaugeDial(
            value: configuration.value * maximum,
            maximum: maximum,
            decimals: decimals,
            unit: unit,
            showsValue: showsValue,
            temperatureWarning: temperatureWarning
        )
    }
}

// Interpolate the rendered value, not just Gauge's target configuration.
private struct SweepGaugeDial: View, Animatable {
    nonisolated var value: Double
    let maximum: Double
    let decimals: Int
    let unit: String
    let showsValue: Bool
    let temperatureWarning: Bool

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    private var fraction: Double { min(1, max(0, value / maximum)) }
    private var tint: Color {
        guard temperatureWarning else { return .accentColor }
        return value > 90 ? .red : value >= 80 ? .orange : .accentColor
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135))
                .opacity(fraction > 0 ? 1 : 0)
            VStack(spacing: 0) {
                Text(showsValue ? String(format: "%.*f", decimals, max(0, value)) : "—")
                    .font(.title.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 80)
        }
        .padding(5)
    }
}

struct FanPage: View {
    @ObservedObject var model: MSIControlModel
    @ObservedObject private var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: MSIControlModel) {
        self.model = model
        self.monitor = model.monitor
    }
    private var isAutoMode: Bool { model.selectedFanMode == .automatic || model.loadedFanMode != .advanced }
    private var canEdit: Bool {
        !model.fanModeBusy && !isAutoMode
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("mode")).font(.headline).padding(.bottom, 8)
                Picker("", selection: Binding(get: { model.selectedFanMode }, set: { mode in
                    if reduceMotion {
                        model.applyFanMode(mode)
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) { model.applyFanMode(mode) }
                    }
                })) {
                    Text(t("automatic")).tag(ECFanMode.automatic)
                    Text(t("manual")).tag(ECFanMode.advanced)
                }.pickerStyle(.segmented).disabled(model.fanModeBusy || model.loadedFanMode == nil)
                HStack(spacing: 8) {
                    ForEach(FanPreset.allCases, id: \.self) { preset in
                        Button(preset.title) {
                            model.setFanPreset(preset)
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                            .buttonStyle(FanPresetButtonStyle(selected: !isAutoMode && model.currentPreset == preset))
                            .accessibilityAddTraits(!isAutoMode && model.currentPreset == preset ? .isSelected : [])
                    }
                }
                .disabled(!canEdit)
                LabeledContent(t("fan_1")) {
                    Text("\(model.monitor.sensors.fan.formatted(decimals: 0)) RPM")
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.monitor.sensors.fan.value ?? 0)
                }
                LabeledContent(t("fan_2")) {
                    Text("\(model.monitor.sensors.fan2.formatted(decimals: 0)) RPM")
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.monitor.sensors.fan2.value ?? 0)
                }
                Toggle(t("strongCooling"), isOn: Binding(get: { model.coolerBoost }, set: { _ in model.toggleBoost() }))
                    .disabled(isAutoMode || model.fanModeBusy)
                    .opacity(isAutoMode ? 0.5 : 1)
                    .help(canEdit ? t("strongCooling") : t("自动模式下由系统接管，无法开启强冷"))
                Toggle("智能启停（低温停转）", isOn: Binding(
                    get: { model.zeroRPM }, set: { model.setZeroRPM($0) }
                ))
                .disabled(!canEdit || model.fixedFanSpeed || !model.editableCurve.contains { $0.temperature < 45 })
                .help("仅将当前风扇低于 45°C 的曲线节点设为 0%；实际停转由固件决定，点击应用后生效。")
                if !model.fanModeStatus.isEmpty {
                    Text(translated(model.fanModeStatus)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                Text(t("fanCurve")).font(.headline)
                Picker(t("fan_3e41bc3f"), selection: $model.selectedCurveFan) {
                    Text(t("fan_1")).tag(0)
                    Text(t("fan_2")).tag(1)
                }.pickerStyle(.segmented)
                .disabled(!canEdit)
                if !isAutoMode {
                    Picker("调节方式", selection: Binding(get: { model.fixedFanSpeed }, set: {
                        model.setFanAdjustmentMode($0)
                    })) {
                        Text("按曲线调节").tag(false)
                        Text("固定转速").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canEdit)
                }
                if model.fixedFanSpeed && !isAutoMode {
                    HStack(alignment: .center, spacing: 12) {
                        Text("输出比例").frame(width: 70, alignment: .leading)
                        Slider(value: Binding(get: { model.editableCurve.first?.speed ?? 40 }, set: {
                            model.setFixedSpeed($0)
                        }), in: 20...100, step: 1)
                        Text("\(Int(model.editableCurve.first?.speed ?? 40))%")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    .disabled(!canEdit)
                } else {
                FanCurveChart(model: model, monitor: model.monitor, canEdit: canEdit)
                .grayscale(isAutoMode ? 1 : 0)
                .opacity(isAutoMode ? 0.5 : 1)
                Group {
                if model.selectedCurveFan == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($model.curvePoints) { $point in
                            CurveSlider(point: $point, isDisabled: !canEdit, allowsZero: model.zeroRPM) { model.markFanCustom() }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($model.gpuCurvePoints) { $point in
                            CurveSlider(point: $point, isDisabled: !canEdit, allowsZero: model.zeroRPM) { model.markFanCustom() }
                        }
                    }
                }
                }
                .opacity(isAutoMode ? 0.5 : 1)
                }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(t("applyCurve"), systemImage: "checkmark") { model.applyCurve() }
                    .disabled(!canEdit || !model.curveDirty).help(t("applyCurve"))
            }
        }
        .onAppear { model.readFan() }
        .onChange(of: model.selectedCurveFan) { _, _ in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                model.fixedFanSpeed = false
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isAutoMode)
    }
}

private struct FanPresetButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

private struct FanCurveChart: View {
    @ObservedObject var model: MSIControlModel
    @ObservedObject var monitor: SystemMonitor
    let canEdit: Bool
    @State private var draggedIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var temperatures: [Double] { Array(Set(model.editableCurve.map(\.temperature))).sorted() }
    private var temperatureDomain: ClosedRange<Double> {
        let lower = temperatures.first ?? 0
        return lower...max(lower + 1, temperatures.last ?? 100)
    }
    var body: some View {
                Chart {
                ForEach(model.editableCurve) { point in
                    LineMark(x: .value("°C", point.temperature), y: .value("%", point.speed))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("°C", point.temperature), y: .value("%", point.speed))
                }
                if let temperature = monitor.sensors.temperature.value, temperature.isFinite,
                   temperatureDomain.contains(temperature) {
                    RuleMark(x: .value("CPU °C", temperature))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                }
                .chartXScale(domain: temperatureDomain)
                .chartYScale(domain: 0...100).chartXAxisLabel("°C").chartYAxisLabel("%")
                .chartXAxis {
                    AxisMarks(position: .bottom, values: temperatures) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)
                .chartPlotStyle { plot in plot.background(.clear) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        // Keep the live label outside Charts' retained mark annotations.
                        if let anchor = proxy.plotFrame,
                           let temperature = monitor.sensors.temperature.value,
                           temperature.isFinite, temperatureDomain.contains(temperature),
                           let x = proxy.position(forX: temperature) {
                            let frame = geometry[anchor]
                            Text("\(temperature, specifier: "%.0f")°C")
                                .font(.caption2).foregroundStyle(.primary)
                                .monospacedDigit().lineLimit(1).fixedSize()
                                .transaction { $0.animation = nil }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: Capsule())
                                .position(
                                    x: min(max(frame.minX + 28, frame.minX + x), max(frame.minX + 28, frame.maxX - 28)),
                                    y: frame.minY - 16
                                )
                                .allowsHitTesting(false)
                        }
                        if canEdit, let anchor = proxy.plotFrame {
                            let frame = geometry[anchor]
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { gesture in
                                        guard canEdit else { return }
                                        var points = model.editableCurve
                                        if draggedIndex == nil {
                                            draggedIndex = points.indices.min { a, b in
                                                distance(points[a], proxy, frame, gesture.startLocation) < distance(points[b], proxy, frame, gesture.startLocation)
                                            }
                                            if let index = draggedIndex,
                                               distance(points[index], proxy, frame, gesture.startLocation) > 28 { draggedIndex = nil; return }
                                        }
                                        guard let index = draggedIndex, points.indices.contains(index),
                                              let speed: Double = proxy.value(atY: gesture.location.y - frame.minY) else { return }
                                        let minimum = model.zeroRPM && points[index].temperature < 45 ? 0.0 : 20.0
                                        points[index].speed = min(100, max(minimum, speed.rounded()))
                                        model.editableCurve = points
                                    }
                                    .onEnded { _ in draggedIndex = nil })
                        }
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: model.editableCurve)
                .animation(reduceMotion ? nil : .linear(duration: 0.5), value: monitor.sensors.temperature.value)
                .padding(.top, 20)
                .onChange(of: model.selectedCurveFan) { _, _ in draggedIndex = nil }
                .onChange(of: canEdit) { _, _ in draggedIndex = nil }
    }
    private func distance(_ point: CurvePoint, _ proxy: ChartProxy, _ frame: CGRect, _ location: CGPoint) -> Double {
        guard let x = proxy.position(forX: point.temperature), let y = proxy.position(forY: point.speed) else { return .infinity }
        return hypot(x + frame.minX - location.x, y + frame.minY - location.y)
    }
}

private struct CurveSlider: View {
    @Binding var point: CurvePoint
    let isDisabled: Bool
    var allowsZero = false
    var onChange: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(Int(point.temperature)) °C").frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { point.speed }, set: { point.speed = $0; onChange() }), in: (allowsZero && point.temperature < 45 ? 0.0 : 20.0)...100, step: 1)
                .disabled(isDisabled)
                .accessibilityLabel("\(Int(point.temperature)) °C")
            Text("\(Int(point.speed))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
                .opacity(isDisabled ? 0.5 : 1)
        }
    }
}

struct LightingPage: View {
    @ObservedObject var lighting: KeyboardLightingModel
    @State private var showingDiagnostics = false
    @State private var showingApplied = false

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
        HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 16) {
            Text(translated(lighting.status))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(t("mode")) {
                Picker(t("mode"), selection: $lighting.configuration.effect) {
                    ForEach(LightingEffect.allCases) { effect in
                        Text(effectTitle(effect)).tag(effect)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(lighting.isBusy)
            }
                HStack(spacing: 12) {
                    Text(t("brightness")).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(get: { Double(lighting.configuration.brightness) },
                        set: { lighting.configuration.brightness = Int($0.rounded()) }), in: 0...4, step: 1)
                    Text("\(lighting.configuration.brightness)/4").monospacedDigit().frame(width: 48, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.2), value: lighting.configuration.brightness)
                }
                .disabled(lighting.isBusy || lighting.configuration.effect == .off)
            HStack(spacing: 12) {
                Text(t("period")).frame(width: 64, alignment: .leading)
                Slider(value: $lighting.configuration.period, in: LightingConfiguration.periodRange, step: 0.5)
                Text(String(format: "%.1f s", lighting.configuration.period)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.2), value: lighting.configuration.period)
            }
            .disabled(lighting.isBusy || !lighting.configuration.effect.isAnimated)
            .opacity(lighting.configuration.effect.isAnimated ? 1 : 0.5)
            HStack(spacing: 10) {
            Button { lighting.loadSaved() } label: {
                Label(t("savedLighting"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!lighting.canControl)
            }.controlSize(.small)
            if lighting.configuration.effect.usesSelectedColors {
                Divider()
                HStack {
                    Text(t("zoneRGB")).font(.headline)
                    Spacer()
                    Button(t("chooseAll")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            lighting.selectedZone = nil
                        }
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(lighting.isBusy)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6), alignment: .leading, spacing: 12) {
                    ForEach(0..<LightingConfiguration.zoneCount, id: \.self) { zone in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                lighting.selectedZone = zone
                            }
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        } label: {
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(lighting.configuration.colors[zone].displayColor)
                                    .frame(width: 40, height: 40)
                                    .animation(.easeInOut(duration: 0.3), value: lighting.configuration.colors[zone])
                                    .overlay {
                                        if lighting.selectedZone == zone {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.accentColor, lineWidth: 3)
                                                .frame(width: 46, height: 46)
                                        }
                                    }
                                Text(localized("lightingZone", zone + 1)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(lighting.selectedZone == zone ? 1.05 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: lighting.selectedZone)
                        .accessibilityLabel(localized("lightingZone", zone + 1))
                        .accessibilityValue(lighting.configuration.colors[zone].hex)
                        .accessibilityAddTraits(lighting.selectedZone == zone ? .isSelected : [])
                        .disabled(lighting.isBusy)
                    }
                }
                .frame(width: 304, alignment: .leading)
            }
            Divider()
            DisclosureGroup(t("deviceDiagnostics"), isExpanded: $showingDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(lighting.report?.scan.status ?? t("openPageScan")).font(.subheadline)
                    Button { Task { await lighting.exportDiagnostics() } } label: {
                        Label(t("export_diagnostics"), systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered).controlSize(.small).disabled(!lighting.canExport)
                }
            }
        }.padding(.trailing, 24)
        .frame(width: max(320, geometry.size.width - (lighting.configuration.effect.usesSelectedColors ? 308 : 48)), alignment: .topLeading)
        if lighting.configuration.effect.usesSelectedColors {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                Text(lighting.selectedZone.map { "编辑区域 \($0 + 1)" } ?? t("globalLightingSettings"))
                    .font(.headline)
                LightingColorEditor(lighting: lighting)
            }
            .id(lighting.selectedZone.map(String.init) ?? "global")
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: lighting.selectedZone)
                .disabled(lighting.isBusy)
        }
        .padding(.leading, 24)
        .frame(width: 260, alignment: .topLeading)
        .overlay(alignment: .leading) { Divider() }
        }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await lighting.refresh() } } label: {
                    Label(t("refreshInterface"), systemImage: "arrow.clockwise")
                }.disabled(lighting.isBusy)
                Button { lighting.apply() } label: {
                    Label(t("apply"), systemImage: "checkmark")
                }.disabled(!lighting.canControl)
            }
        }
        .task { if lighting.report == nil { await lighting.refresh() } }
        .onChange(of: lighting.configuration.effect) { _, effect in
            if !effect.usesSelectedColors { lighting.selectedZone = nil }
        }
        .onChange(of: lighting.successfulApplyCount) { _, _ in
            showingApplied = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        .task(id: lighting.successfulApplyCount) {
            guard lighting.successfulApplyCount > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(1500)) }
            catch { return }
            showingApplied = false
        }
    }
}

private struct LightingColorEditor: View {
    @ObservedObject var lighting: KeyboardLightingModel
    @State private var hexText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(lighting.selectedZone == nil ? t("allZonesColor") : t("lightingColor")) {
                ColorPicker("", selection: Binding(
                    get: { lighting.editorColor.displayColor },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        let hex = String(format: "#%02X%02X%02X",
                            Int((rgb.redComponent * 255).rounded()),
                            Int((rgb.greenComponent * 255).rounded()),
                            Int((rgb.blueComponent * 255).rounded()))
                        if let value = LightingRGB(hex: hex) { lighting.setColor(value) }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            LabeledContent("HEX") {
                TextField("#RRGGBB", text: Binding(get: { hexText }, set: {
                    hexText = $0
                    if let color = LightingRGB(hex: $0) { lighting.setColor(color) }
                }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit {
                        if let color = LightingRGB(hex: hexText) { lighting.setColor(color) }
                    }
            }
            .onAppear { hexText = lighting.editorColor.hex }
            .onChange(of: lighting.editorColor) { _, color in hexText = color.hex }
            .onChange(of: lighting.selectedZone) { _, _ in hexText = lighting.editorColor.hex }
            if lighting.selectedZone != nil {
                Button("应用到全部区域") {
                    guard let color = LightingRGB(hex: hexText) else { return }
                    lighting.selectedZone = nil
                    lighting.setColor(color)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(LightingRGB(hex: hexText) == nil || !lighting.canControl)
            }
        }
    }
}
/*
                LabeledContent(t("mode")) {
                Picker(t("mode"), selection: $lighting.configuration.effect) {
                    ForEach(lighting.availableEffects) { effect in Text(effectTitle(effect)).tag(effect) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(lighting.isBusy)
                }
                HStack(spacing: 12) {
                    Text(t("brightness")).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(get: { Double(lighting.configuration.brightness) },
                        set: { lighting.configuration.brightness = Int($0.rounded()) }), in: 0...4, step: 1)
                        .accessibilityLabel(t("brightnessLabel"))
                    Text("\(lighting.configuration.brightness)/4").monospacedDigit().frame(width: 48, alignment: .trailing)
                }.disabled(lighting.isBusy || lighting.configuration.effect == .off)
                HStack(spacing: 12) {
                    Text(t("period")).frame(width: 64, alignment: .leading)
                    Slider(value: $lighting.configuration.period, in: LightingConfiguration.periodRange, step: 0.5)
                        .accessibilityLabel(t("period"))
                    Text(String(format: "%.1f s", lighting.configuration.period)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }.disabled(lighting.isBusy || !lighting.configuration.effect.isAnimated)
                    .opacity(lighting.configuration.effect.isAnimated ? 1 : 0.5)
                Button { lighting.loadSaved() } label: { Label(t("savedLighting"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).disabled(!lighting.canControl)
                Text(translated(lighting.status)).foregroundStyle(.secondary).textSelection(.enabled)
                if lighting.configuration.effect.usesSelectedColors {
                    Divider()
                    HStack {
                        Text(t("zoneRGB")).font(.headline)
                        Spacer()
                        Button(t("chooseAll")) { lighting.selectedZone = nil; showingInspector = true }
                            .disabled(lighting.isBusy)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 8), count: 6), alignment: .leading, spacing: 10) {
                        ForEach(0..<LightingConfiguration.zoneCount, id: \.self) { zone in
                            Button { lighting.selectedZone = zone; showingInspector = true } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.sRGB,
                                            red: Double(lighting.configuration.colors[zone].red) / 255,
                                            green: Double(lighting.configuration.colors[zone].green) / 255,
                                            blue: Double(lighting.configuration.colors[zone].blue) / 255,
                                            opacity: 1))
                                        .frame(width: 40, height: 40)
                                        .overlay {
                                            if lighting.selectedZone == zone {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.accentColor, lineWidth: 3)
                                                    .padding(-3)
                                            }
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            if lighting.selectedZone == zone {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(Color.accentColor, Color(nsColor: .windowBackgroundColor))
                                                    .offset(x: 7, y: -7)
                                            }
                                        }
                                    Text(localized("lightingZone", zone + 1)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localized("zoneColor", zone + 1))
                            .accessibilityValue(lighting.configuration.colors[zone].hex)
                            .accessibilityAddTraits(lighting.selectedZone == zone ? .isSelected : [])
                            .disabled(lighting.isBusy)
                        }
                    }
                    Divider().padding(.top, 16)
                }
                if let sent = lighting.lastSentDescription { Text(localized("lastApplied", translated(sent))).foregroundStyle(.secondary) }
                Divider()
                DisclosureGroup(t("deviceDiagnostics"), isExpanded: $showingDiagnostics) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text(translated(lighting.report?.scan.status ?? t("openPageScan")))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let scan = lighting.report?.scan {
                        ForEach(scan.devices) { device in
                            LabeledContent(device.name) {
                                Text("\(device.identifier) · \(device.transport)")
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    Button { Task { await lighting.exportDiagnostics() } } label: {
                        Label(t("export_diagnostics"), systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered).controlSize(.small).disabled(!lighting.canExport)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .inspector(isPresented: Binding(
            get: {
                showingInspector &&
                lighting.configuration.effect.usesSelectedColors
            },
            set: { showingInspector = $0 }
        )) {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(lighting.selectedZone.map { localized("editingLightingZone", $0 + 1) } ?? t("globalLightingSettings"))
                    .font(.headline)
                LightingColorEditor(lighting: lighting)
            }
            .controlSize(.small)
            .disabled(lighting.isBusy || !lighting.configuration.effect.usesSelectedColors)
            .padding(24)
        }
        .inspectorColumnWidth(min: 250, ideal: 280, max: 300)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await lighting.refresh() } } label: { Label(t("refreshInterface"), systemImage: "arrow.clockwise") }
                    .labelStyle(.titleAndIcon).disabled(lighting.isBusy).help(t("refreshInterface"))
                Button { lighting.turnOn() } label: { Label(t("turnOn"), systemImage: "lightbulb") }
                    .disabled(!lighting.canControl).help(t("turnOn"))
                Button { lighting.turnOff() } label: { Label(t("turnOff"), systemImage: "lightbulb.slash") }
                    .disabled(!lighting.canControl).help(t("turnOff"))
                if lighting.isAnimating {
                    Button { lighting.stopAnimation() } label: { Label(t("pause"), systemImage: "pause") }.help(t("pause"))
                }
                Button { lighting.apply() } label: { Label(t("apply"), systemImage: "checkmark") }
                    .labelStyle(.titleAndIcon).disabled(!lighting.canControl).help(t("apply"))
            }
        }
        .task { if lighting.report == nil { await lighting.refresh() } }
    }
}

private struct LightingColorEditor: View {
    @ObservedObject var lighting: KeyboardLightingModel
    @State private var hexText = ""
    var body: some View {
        LabeledContent(lighting.selectedZone == nil ? t("allZonesColor") : t("lightingColor")) {
            ColorPicker("", selection: $lighting.editorCGColor, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(lighting.selectedZone == nil ? t("allZonesColor") : t("lightingColor"))
        }
        LabeledContent("HEX") {
        TextField("#RRGGBB", text: Binding(get: { hexText }, set: {
            hexText = $0
            if let color = LightingRGB(hex: $0) { lighting.setColor(color) }
        }))
        .textFieldStyle(.roundedBorder)
        .frame(width: 110)
        .font(.body.monospaced()).accessibilityLabel(t("six_digit_rgb_hexadecimal_color"))
        .onAppear { hexText = lighting.editorColor.hex }
        .onChange(of: lighting.editorColor) { _, color in hexText = color.hex }
        .onChange(of: lighting.selectedZone) { _, _ in hexText = lighting.editorColor.hex }
        }
        Button(t("applyToAllZones")) {
            let color = lighting.editorColor
            lighting.selectedZone = nil
            lighting.setColor(color)
        }.buttonStyle(.borderedProminent)
            .disabled(LightingRGB(hex: hexText) == nil)
        if LightingRGB(hex: hexText) == nil { Text(t("enter_a_six_digit_rgb_value_such_as_3366ff")).foregroundStyle(.red) }
    }
}

*/

struct DriverConfigurationPage: View {
    @ObservedObject var model: MSIControlModel
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EFIMountSection()
                Divider().padding(.vertical, 8)
                Text(t("ecDriverFirmware")).font(.headline)
                driverRow("MSI EC Bridge", translated(monitor.ecStatus))
                Divider()
                driverRow(t("ecIdentity"), translated(monitor.ecIdentity))
                Divider()
                driverRow("OpenCore", monitor.openCoreVersion.map { "\(t("openCoreDetected")) · \($0)" } ?? t("openCoreVersionUnavailable"),
                          secondaryValue: monitor.openCoreVersion == nil)
                Button(t("configureDriver"), systemImage: "wrench.and.screwdriver") { model.installDriver() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .foregroundStyle(.white)
                    .controlSize(.regular)
                    .fixedSize()
                    .help(t("configureDriver"))
                Text(t("driverConfigurationContext"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { monitor.refresh() } label: { Label(t("refreshDriverStatus"), systemImage: "arrow.clockwise") }
                    .labelStyle(.titleAndIcon).help(t("refreshDriverStatus"))
            }
        }
        .alert(t("ec_driver_configuration"), isPresented: $model.showingInstallResult) {
            Button(t("ok"), role: .cancel) {}
        } message: { Text(translated(model.installMessage)) }
    }

    private func driverRow(_ label: String, _ value: String, secondaryValue: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 20) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).foregroundStyle(secondaryValue ? .secondary : .primary).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity)
    }
}
