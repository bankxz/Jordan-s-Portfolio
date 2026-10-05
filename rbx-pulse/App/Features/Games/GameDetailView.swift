import Charts
import RBXPulseKit
import SwiftUI

struct GameDetailView: View {
    let gameID: Int64

    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .day
    @State private var series: SeriesState = .loading

    enum SeriesState: Equatable {
        case loading
        case loaded(MetricSeries)
        case failed
    }

    var body: some View {
        Group {
            if let game = model.game(id: gameID) {
                content(game)
            } else if model.dashboard == nil {
                ProgressView()
            } else {
                EmptyStateView(title: "Game not found",
                               message: "This game is no longer linked to your account.",
                               systemImage: "questionmark.square.dashed")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        // Reloads when the range changes; the previous request is cancelled automatically.
        .task(id: range) { await loadSeries() }
    }

    private func content(_ game: Game) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(game.name)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("gameDetailTitle")
                FreshnessLabel(updatedAt: game.stats.updatedAt, now: model.currentDate)

                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                chartCard

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        MetricCard(title: "Playing", value: MetricFormatter.compact(game.stats.ccu),
                                   change: game.stats.ccuChange, systemImage: "person.2")
                        MetricCard(title: "Robux 24h",
                                   value: game.stats.robux24h.map(MetricFormatter.robux) ?? "—",
                                   systemImage: "chart.line.uptrend.xyaxis")
                    }
                    GridRow {
                        MetricCard(title: "Visits", value: MetricFormatter.compact(game.stats.visits), systemImage: "eye")
                        MetricCard(title: "Favourites", value: MetricFormatter.compact(game.stats.favourites),
                                   systemImage: "star")
                    }
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await model.toggleWorkingOn(gameID: game.id) }
                } label: {
                    Label(game.isWorkingOn ? "Stop working on" : "Mark working on",
                          systemImage: game.isWorkingOn ? "hammer.fill" : "hammer")
                }
                Button {
                    Task { await model.toggleFavourite(gameID: game.id) }
                } label: {
                    Label(game.isFavourite ? "Remove favourite" : "Favourite",
                          systemImage: game.isFavourite ? "star.fill" : "star")
                }
                .accessibilityIdentifier("favouriteButton")
            }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        switch series {
        case .loading:
            LoadingCard(lines: 5)
        case .failed:
            ErrorCard(message: "Couldn't load the chart.") { await loadSeries() }
        case .loaded(let series):
            if series.points.count < 2 {
                Text("Not enough data yet for this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                CCUChart(series: series, range: range)
                    .card()
            }
        }
    }

    private func loadSeries() async {
        if case .loaded = series {} else { series = .loading }
        do {
            series = .loaded(try await model.service.series(gameID: gameID, metric: .ccu, range: range))
        } catch is CancellationError {
            return
        } catch {
            series = .failed
        }
    }
}

/// CCU line with touch selection (iOS 17 `chartXSelection`) and a peak marker.
struct CCUChart: View {
    let series: MetricSeries
    let range: TimeRange
    @State private var selectedDate: Date?

    /// Keep the chart cheap regardless of history length.
    private var points: [MetricPoint] { series.downsampled(to: 120) }

    private var selectedPoint: MetricPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Chart {
                ForEach(points, id: \.date) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Players", point.value))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value("Players", point.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let selectedPoint {
                    RuleMark(x: .value("Selected time", selectedPoint.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("Selected time", selectedPoint.date),
                              y: .value("Players", selectedPoint.value))
                        .symbolSize(60)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(MetricFormatter.compact(number))
                        }
                    }
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Concurrent players over the last \(range.title)")
        }
    }

    private var header: some View {
        let shown = selectedPoint ?? points.last
        return VStack(alignment: .leading, spacing: 2) {
            Text(selectedPoint == nil ? "Players now" : "Players")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text(MetricFormatter.compact(shown?.value ?? 0))
                .font(.title.weight(.bold).monospacedDigit())
            if let shown {
                Text(shown.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selectedPoint == nil, let peak = series.peak {
                Text("Peak \(MetricFormatter.compact(peak.value))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack { GameDetailView(gameID: SampleData.seeds[0].id) }
        .environment(PreviewSupport.model(.normal))
}
