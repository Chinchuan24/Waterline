import Charts
import WaterlineCore
import SwiftUI

struct HistoryTab: View {
  let monitor: MemoryMonitor

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        LiveChart(values: monitor.panel.live)
        DayChart(history: monitor.panel.usage)
        DayStats(history: monitor.panel.usage)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
    }
  }
}

private struct SectionTitle: View {
  let title: String
  let trailing: String?

  var body: some View {
    HStack {
      Text(title).font(.subheadline.weight(.semibold))
      Spacer()
      if let trailing {
        Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }
}

private struct LiveChart: View {
  let values: [Double]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      let range = values.min().flatMap { low in values.max().map { "\(Int((low * 100).rounded()))–\(Int(($0 * 100).rounded()))%" } }
      SectionTitle(title: "Last 3 minutes", trailing: range)
      Canvas { context, size in
        guard values.count > 1 else { return }
        let step = size.width / CGFloat(MemoryMonitor.liveLength - 1)
        let offset = CGFloat(MemoryMonitor.liveLength - values.count) * step
        let points = values.enumerated().map { index, value in
          CGPoint(x: offset + CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
        }
        var line = Path()
        line.addLines(points)
        var area = line
        area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
        area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
          Gradient(colors: [.blue.opacity(0.28), .blue.opacity(0.02)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
      }
      .frame(height: 44)
      .background(alignment: .center) { Rectangle().fill(.quaternary).frame(height: 0.5) }
      .background(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 0.5) }
    }
  }
}

private struct DayChart: View {
  let history: UsageHistory

  static func segments(of points: [UsagePoint]) -> [[UsagePoint]] {
    var runs: [[UsagePoint]] = []
    for point in points {
      if let last = runs.last?.last, point.time.timeIntervalSince(last.time) <= UsageHistory.pointInterval * 3 {
        runs[runs.count - 1].append(point)
      } else {
        runs.append([point])
      }
    }
    return runs
  }

  /// Whole-hour ticks spaced so there are about four labels and none repeat.
  static func hourStride(for history: UsageHistory) -> Int {
    guard let first = history.points.first?.time, let last = history.points.last?.time else { return 1 }
    let hours = last.timeIntervalSince(first) / 3600
    return max(1, Int((hours / 4).rounded(.up)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionTitle(title: "Last 24 hours", trailing: nil)
      if history.points.count < 2 {
        Text("Waterline records one point a minute. The day's chart fills in as it runs.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
          .multilineTextAlignment(.center)
      } else {
        Chart {
          ForEach(history.points.filter { $0.pressure > .normal }, id: \.time) { point in
            RectangleMark(
              xStart: .value("Start", point.time.addingTimeInterval(-UsageHistory.pointInterval)),
              xEnd: .value("End", point.time),
              yStart: .value("Bottom", 0),
              yEnd: .value("Top", 100))
            .foregroundStyle(point.pressure.color.opacity(0.18))
          }
          // Each unbroken run of minutes is its own series, so sleep or time with the app
          // closed shows as a gap rather than a line drawn straight across it.
          ForEach(Array(Self.segments(of: history.points).enumerated()), id: \.offset) { index, segment in
            ForEach(segment, id: \.time) { point in
              AreaMark(x: .value("Time", point.time), y: .value("Used", point.usedFraction * 100),
                       series: .value("Run", index))
                .foregroundStyle(.linearGradient(
                  colors: [.blue.opacity(0.3), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
              LineMark(x: .value("Time", point.time), y: .value("Used", point.usedFraction * 100),
                       series: .value("Run", index))
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
          }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
          AxisMarks(values: [0, 50, 100]) { value in
            AxisGridLine()
            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
          }
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .hour, count: Self.hourStride(for: history))) {
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour())
          }
        }
        .frame(height: 110)
      }
    }
  }
}

private struct DayStats: View {
  let history: UsageHistory

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      GridRow {
        stat("Peak", history.peak.map {
          "\(Int(($0.usedFraction * 100).rounded()))% at \($0.time.formatted(date: .omitted, time: .shortened))"
        } ?? "—")
        stat("Average", history.averageUsed.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
      }
      GridRow {
        stat("Under pressure", Duration.seconds(history.timeUnderPressure)
          .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        stat("Swap peak", Bytes.format(history.peakSwap))
      }
    }
    .font(.callout)
  }

  private func stat(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).monospacedDigit()
    }
  }
}
