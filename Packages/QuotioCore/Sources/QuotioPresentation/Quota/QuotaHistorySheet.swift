import Charts
import QuotioDomain
import SwiftUI

public struct QuotaHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: QuotaHistoryScreenModel
    @State private var confirmsClear = false
    @FocusState private var chartFocused: Bool
    private let accountName: String
    private let providerName: String
    private let displayMode: QuotaDisplayMode
    private let hideSensitiveInfo: Bool

    public init(model: QuotaHistoryScreenModel, accountName: String, providerName: String,
                displayMode: QuotaDisplayMode = .remaining, hideSensitiveInfo: Bool = false) {
        _model = State(initialValue: model)
        self.accountName = accountName; self.providerName = providerName
        self.displayMode = displayMode; self.hideSensitiveInfo = hideSensitiveInfo
    }
    private var helper: QuotaDisplayHelper { .init(displayMode: displayMode) }
    private var levelKey: String { displayMode == .remaining ? "history.remaining" : "history.used" }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("history.title".localized()).font(.title2.bold())
                    Text(providerName).font(.subheadline).foregroundStyle(.secondary)
                    SensitiveAccountText(value: accountName, isSensitive: hideSensitiveInfo)
                        .font(.headline).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("action.done".localized()) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    status
                    if let chart = model.chart {
                        if model.selectedMetric?.hasPercentage == true {
                            timeline(chart)
                            summary(chart)
                        } else {
                            message("history.amountOnly")
                            if !chart.bins.isEmpty {
                                Picker("history.observedAt".localized(), selection: Binding(get: { model.selectedBinID ?? chart.bins.last!.id }, set: { model.selectedBinID = $0 })) {
                                    ForEach(chart.bins) { bin in Text(time(bin.latest.fetchedAt) + " — " + valueText(bin.latest)).tag(bin.id) }
                                }
                            }
                        }
                        if chart.bins.isEmpty {
                            message(emptyKey)
                        } else if let bin = model.selectedBin {
                            detail(bin)
                        }
                        eventList
                    } else if !model.isLoading && model.error == nil {
                        message(model.catalog?.metrics.isEmpty == false && model.catalog?.metrics.contains(where: { $0.hasPercentage }) == false ? "history.amountOnly" : emptyKey)
                    }
                    Text("history.coverage".localized()).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("history.clearAccount".localized(), role: .destructive) { confirmsClear = true }
                            .disabled(!model.availability.connected || !model.availability.canWrite || model.isClearing)
                        Spacer()
                        if model.isClearing { ProgressView().controlSize(.small) }
                    }
                    if model.mutationError != nil { message("history.clearFailed") }
                }.padding(20)
            }
        }
        .frame(minWidth: 440, idealWidth: 720, maxWidth: 840, minHeight: 540, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("history.clearAccount".localized(), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("history.clearAccount".localized(), role: .destructive) { Task { await model.clearAccount() } }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: { Text("history.clearHelp".localized()) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let catalog = model.catalog, !catalog.metrics.isEmpty {
                Picker("history.metric".localized(), selection: Binding(get: { model.metricID ?? "" }, set: { model.select(metricID: $0) })) {
                    if model.metricID == nil { Text("history.chooseMetric".localized()).tag("") }
                    ForEach(catalog.metrics) { metric in
                        Text(metric.displayName + (metric.current ? "" : " — " + "history.historicalOnly".localized())).tag(metric.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("history.range".localized(), selection: Binding(get: { model.range }, set: { model.select(range: $0) })) {
                ForEach(QuotaHistoryRange.allCases) { range in Text(("history.range." + range.rawValue).localized()).tag(range) }
            }.pickerStyle(.segmented)
        }
    }
    @ViewBuilder private var status: some View {
        if model.isLoading { HStack { ProgressView().controlSize(.small); Text("history.loading".localized()) } }
        if let error = model.error {
            HStack(alignment: .top) {
                Label(errorKey(error).localized(), systemImage: error == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if error != .unsupported && error != .unauthorized && error != .hostChanged {
                    Button("action.retry".localized()) { model.reload() }
                }
            }.foregroundStyle(.secondary)
        }
        if model.catalog?.recordingEnabled == false || model.chart?.recordingEnabled == false { message("history.paused") }
        if model.catalog?.recordingError != nil || model.chart?.recordingError != nil { message("history.recordingFailed") }
    }
    private var emptyKey: String {
        if model.catalog?.recordingEnabled == false { return "history.disabledEmpty" }
        if model.catalog?.metrics.isEmpty == true || model.catalog?.firstObservedAt == nil { return "history.startedEmpty" }
        return "history.rangeEmpty"
    }
    private func errorKey(_ error: QuotaHistoryError) -> String {
        switch error {
        case .offline: "history.offline"
        case .hostChanged: "history.hostChanged"
        case .unsupported: "history.unsupported"
        case .unauthorized: "history.ownerOnly"
        case .storage: "history.storageFailed"
        case .invalidResponse, .requestFailed: "history.readFailed"
        }
    }
    private func message(_ key: String) -> some View {
        Text(key.localized()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func timeline(_ chart: QuotaHistoryChart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(levelKey.localized()).font(.headline)
            Chart {
                ForEach(chart.bins) { bin in
                    if let remaining = bin.latest.remainingPercent {
                        let value = helper.displayPercent(remainingPercent: remaining)
                        if value == 0 {
                            PointMark(x: .value("history.time", midpoint(bin)), y: .value("history.percent", 0))
                                .symbolSize(14).foregroundStyle(helper.statusColor(remainingPercent: remaining))
                        } else {
                            RectangleMark(xStart: .value("history.start", bin.startAt.addingTimeInterval(Double(chart.binSeconds) * 0.3)),
                                    xEnd: .value("history.end", bin.endAt.addingTimeInterval(-Double(chart.binSeconds) * 0.3)),
                                          yStart: .value("history.baseline", 0.0), yEnd: .value("history.percent", value))
                                .foregroundStyle(helper.statusColor(remainingPercent: remaining))
                        }
                    } else {
                        PointMark(x: .value("history.time", midpoint(bin)), y: .value("history.percent", 0))
                            .symbol(.square).symbolSize(20).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.events.filter { $0.kind == .basisChanged || $0.kind == .clockChanged }) { event in
                    RuleMark(x: .value("history.boundary", event.toAt)).lineStyle(.init(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary)
                }
                if let selected = model.selectedBin {
                    RuleMark(x: .value("history.selected", midpoint(selected)))
                        .foregroundStyle(Color.primary).lineStyle(.init(lineWidth: 1.5))
                }
            }
            .chartXScale(domain: chart.startAt...chart.endAt)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
            .frame(height: 230)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { select(location, proxy: proxy, geometry: geometry) }
                        }
                        .onTapGesture { location in select(location, proxy: proxy, geometry: geometry); chartFocused = true }
                }
            }
            .focusable().focused($chartFocused)
            .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(levelKey.localized())
            .accessibilityValue(model.selectedBin.map(accessibilityDetail) ?? "history.rangeEmpty".localized())
            .accessibilityHint("history.keyboardHelp".localized())
            .accessibilityAdjustableAction { direction in model.moveSelection(by: direction == .increment ? 1 : -1) }
            Text("history.keyboardHelp".localized()).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func midpoint(_ bin: QuotaHistoryBin) -> Date { bin.startAt.addingTimeInterval(bin.endAt.timeIntervalSince(bin.startAt) / 2) }
    private func select(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let rect = geometry[frame]
        guard rect.contains(location), let time: Date = proxy.value(atX: location.x - rect.minX) else { return }
        model.select(at: time)
    }
    private func percentage(_ value: Double) -> String { helper.displayPercent(remainingPercent: value).formatted(.number.precision(.fractionLength(0...1))) + "%" }
    private func valueText(_ observation: QuotaHistoryObservation) -> String {
        if let remaining = observation.remainingPercent { return percentage(remaining) }
        if let amount = observation.amount { return amount.formatted() + " " + (observation.unit ?? "") }
        return ("history.state." + observation.state.rawValue).localized()
    }
    private func confidenceText(_ observation: QuotaHistoryObservation) -> String { ("history.confidence." + observation.confidence.rawValue).localized() }
    private func time(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    private func accessibilityDetail(_ bin: QuotaHistoryBin) -> String {
        [time(bin.latest.fetchedAt), valueText(bin.latest), confidenceText(bin.latest), model.selectedEvents.map(eventText).joined(separator: ". ")].joined(separator: ", ")
    }

    private func summary(_ chart: QuotaHistoryChart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let latest = chart.latest {
                HStack(alignment: .firstTextBaseline) {
                    Text(valueText(latest)).font(.system(.largeTitle, design: .rounded).weight(.medium)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("history.latest".localized()).font(.headline)
                        Text(time(latest.fetchedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(confidenceText(latest)).font(.caption).foregroundStyle(.secondary)
                if latest.expiresAt.map({ $0 <= Date() }) == true {
                    Text("history.stale".localized() + " · " + latest.fetchedAt.formatted(.relative(presentation: .numeric))).font(.caption).foregroundStyle(.secondary)
                }
                reset(latest)
            }
            if let lowest = chart.lowestRemainingPercent {
                LabeledContent((displayMode == .remaining ? "history.lowest" : "history.highestUsed").localized(), value: percentage(lowest))
            }
        }
    }
    @ViewBuilder private func reset(_ observation: QuotaHistoryObservation) -> some View {
        if let date = observation.resetsAt { LabeledContent("history.expectedReset".localized(), value: time(date)) }
        else if let description = observation.resetDescription { LabeledContent("history.expectedReset".localized(), value: description) }
    }
    private func detail(_ bin: QuotaHistoryBin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("history.selection".localized()).font(.headline)
            LabeledContent("history.observedAt".localized(), value: time(bin.latest.fetchedAt))
            LabeledContent(levelKey.localized(), value: valueText(bin.latest))
            LabeledContent("history.confidence".localized(), value: confidenceText(bin.latest))
            LabeledContent("history.source".localized(), value: bin.latest.source)
            LabeledContent("history.samples".localized(), value: bin.sampleCount.formatted())
            if let minimum = bin.minRemainingPercent, let maximum = bin.maxRemainingPercent {
                let low = displayMode == .remaining ? minimum : maximum
                let high = displayMode == .remaining ? maximum : minimum
                LabeledContent("history.binExtrema".localized(), value: percentage(low) + " – " + percentage(high))
            }
            LabeledContent("history.states".localized(), value: bin.states.map { ("history.state." + $0.rawValue).localized() }.joined(separator: ", "))
            reset(bin.latest)
            ForEach(model.selectedEvents) { event in Text(eventText(event)).font(.caption) }
            if model.nextCursor != nil { Text("history.moreEventsHelp".localized()).font(.caption).foregroundStyle(.secondary) }
        }.font(.subheadline).textSelection(.enabled)
    }
    private var eventList: some View {
        DisclosureGroup("history.events".localized()) {
            VStack(alignment: .leading, spacing: 10) {
                if model.events.isEmpty { message("history.noEvents") }
                ForEach(model.events) { event in Text(eventText(event)).frame(maxWidth: .infinity, alignment: .leading) }
                if model.eventError != nil { message("history.eventsFailed") }
                if model.nextCursor != nil {
                    Button("history.moreEvents".localized()) { model.loadMoreEvents() }
                        .disabled(model.isLoadingEvents || !model.availability.connected)
                }
                if model.isLoadingEvents { ProgressView().controlSize(.small) }
            }.font(.caption).padding(.top, 8).textSelection(.enabled)
        }
    }
    private func eventText(_ event: QuotaHistoryEvent) -> String {
        switch event.kind {
        case .resetInferred:
            String(format: "history.event.reset".localized(), time(event.fromAt), time(event.toAt))
        case .quotaIncreased:
            "history.event.increased".localized() + " · " + time(event.fromAt) + " – " + time(event.toAt)
        case .basisChanged:
            "history.event.basis".localized() + " · " + time(event.toAt)
        case .clockChanged:
            "history.event.clock".localized() + " · " + time(event.fromAt) + " – " + time(event.toAt)
        }
    }
}
