import Foundation
import Testing
@testable import WaterlineCore

private let gb = Bytes.gigabyte
private let mb = Bytes.megabyte

private func memory(
  used usedGB: Double, total totalGB: UInt64 = 16, cached cachedGB: Double = 2,
  pressure: MemoryPressure = .normal
) -> SystemMemory {
  SystemMemory(
    total: totalGB * gb, app: UInt64(usedGB * Double(gb)), cached: UInt64(cachedGB * Double(gb)),
    pressure: pressure)
}

private func app(_ name: String, _ footprint: UInt64) -> AppGroup {
  AppGroup(id: name, name: name, processes: [ProcessSample(pid: 1, name: name, footprint: footprint)])
}

// MARK: - Verdict

@Suite struct VerdictTests {
  @Test func `critical pressure says out of memory and names the biggest app`() {
    let verdict = VerdictEngine.evaluate(
      memory: memory(used: 15, pressure: .critical), swapGrowth: 0, topApp: app("Chrome", 6 * gb))
    #expect(verdict.level == .critical)
    #expect(verdict.detail.contains("Quitting Chrome would free about 6.0 GB"))
  }

  @Test func `warning pressure is tight`() {
    let verdict = VerdictEngine.evaluate(memory: memory(used: 13, pressure: .warning), swapGrowth: 0, topApp: nil)
    #expect(verdict.level == .tight)
  }

  @Test func `swap growth under normal pressure is tight`() {
    let verdict = VerdictEngine.evaluate(memory: memory(used: 10), swapGrowth: Int64(gb), topApp: nil)
    #expect(verdict.level == .tight)
    #expect(verdict.headline.contains("swapping"))
  }

  @Test func `low usage is relaxed and explains the cache`() {
    let verdict = VerdictEngine.evaluate(memory: memory(used: 6, cached: 6), swapGrowth: 0, topApp: nil)
    #expect(verdict.level == .relaxed)
    #expect(verdict.detail.contains("file cache"))
  }

  @Test func `high usage with low pressure is fine but near the limit`() {
    let verdict = VerdictEngine.evaluate(memory: memory(used: 14.5), swapGrowth: 0, topApp: nil)
    #expect(verdict.level == .fine)
    #expect(verdict.headline.contains("close to the limit"))
  }
}

// MARK: - Leak detection

@Suite struct LeakDetectorTests {
  let start = Date(timeIntervalSince1970: 1_000_000)

  func feed(_ detector: inout LeakDetector, minutes: Int, footprint: (Int) -> UInt64) {
    for step in 0...(minutes * 2) {  // one sample every 30 s
      detector.record([app("Slack", footprint(step))], at: start.addingTimeInterval(Double(step) * 30))
    }
  }

  @Test func `steady growth is flagged`() {
    var detector = LeakDetector()
    feed(&detector, minutes: 30) { step in 600 * mb + UInt64(step) * 20 * mb }  // +1.2 GB over 30 min
    let report = try! #require(detector.report(for: "Slack"))
    #expect(report.isSuspect)
    #expect(report.growth > Int64(gb))
    #expect(detector.suspects().map(\.name) == ["Slack"])
  }

  @Test func `flat usage is not flagged`() {
    var detector = LeakDetector()
    feed(&detector, minutes: 30) { _ in 2 * gb }
    #expect(detector.suspects().isEmpty)
  }

  @Test func `growth that keeps coming back down is not flagged`() {
    var detector = LeakDetector()
    feed(&detector, minutes: 30) { step in step % 6 < 3 ? 1 * gb : 2 * gb }  // sawtooth
    #expect(detector.suspects().isEmpty)
  }

  @Test func `short bursts are not flagged before the minimum duration`() {
    var detector = LeakDetector()
    feed(&detector, minutes: 10) { step in 500 * mb + UInt64(step) * 60 * mb }
    #expect(detector.report(for: "Slack")?.isSuspect == false)
  }

  @Test func `samples closer than the interval are ignored`() {
    var detector = LeakDetector()
    let first = detector.record([app("A", gb)], at: start)
    let tooSoon = detector.record([app("A", gb)], at: start.addingTimeInterval(5))
    #expect(first && !tooSoon)
    #expect(detector.trend(for: "A").count == 1)
  }

  @Test func `apps that quit lose their history`() {
    var detector = LeakDetector()
    detector.record([app("A", gb), app("B", gb)], at: start)
    detector.record([app("A", gb)], at: start.addingTimeInterval(60))
    #expect(detector.trend(for: "B").isEmpty)
    #expect(detector.trend(for: "A").count == 2)
  }
}

// MARK: - Local AI

@Suite struct LocalAITests {
  @Test func `an 8B model at 4 bits needs about 6 GB`() {
    let eightB = try! #require(ModelClass.catalog.first { $0.label == "8B" })
    let required = Double(eightB.requiredBytes(.q4)) / Double(gb)
    #expect(required > 5 && required < 7)
  }

  @Test(arguments: [
    (required: 5, available: 10, limit: 12, total: 16, expected: ModelFit.fitsNow),
    (required: 11, available: 10, limit: 12, total: 16, expected: ModelFit.needsFreeing(1 * gb)),
    (required: 14, available: 10, limit: 12, total: 16, expected: ModelFit.overGPULimit),
    (required: 20, available: 10, limit: 12, total: 16, expected: ModelFit.tooBig),
  ])
  func `fit categories`(
    _ input: (required: UInt64, available: UInt64, limit: UInt64, total: UInt64, expected: ModelFit)
  ) {
    let fit = ModelFit.evaluate(
      required: input.required * gb, available: input.available * gb,
      gpuLimit: input.limit * gb, totalMemory: input.total * gb)
    #expect(fit == input.expected)
  }

  @Test func `detects local model runtimes by name`() {
    let found = LocalAIRuntime.detect(in: [app("Ollama", gb), app("LM Studio", gb), app("Janitor", gb), app("Jan", gb)])
    #expect(found.map(\.name) == ["Ollama", "LM Studio", "Jan"])
  }

  @Test func `GPU budget is never more than physical memory`() {
    let total = ProcessInfo.processInfo.physicalMemory
    let budget = GPUBudget.current(totalMemory: total)
    #expect(budget.limit > 0 && budget.limit <= total)
  }
}

// MARK: - History, formatting, sampling

@Suite struct HistoryTests {
  @Test func `points older than 24 hours are dropped`() {
    let now = Date()
    var history = UsageHistory()
    history.append(UsagePoint(time: now.addingTimeInterval(-25 * 3600), usedFraction: 0.9, pressure: .critical, swapUsed: 0))
    history.append(UsagePoint(time: now, usedFraction: 0.4, pressure: .normal, swapUsed: 0))
    #expect(history.points.count == 1)
    #expect(history.peak?.usedFraction == 0.4)
    #expect(history.timeUnderPressure == 0)
  }

  @Test func `peak keeps the worst of a minute`() {
    let a = UsagePoint(time: Date(), usedFraction: 0.5, pressure: .warning, swapUsed: 10)
    let b = UsagePoint(time: Date(), usedFraction: 0.7, pressure: .normal, swapUsed: 5)
    let peak = a.peak(with: b)
    #expect(peak.usedFraction == 0.7 && peak.pressure == .warning && peak.swapUsed == 10)
  }
}

@Suite struct FormattingAndSamplingTests {
  @Test(arguments: [
    (UInt64(0), "0 MB"), (512 * mb, "512 MB"), (UInt64(1.5 * Double(gb)), "1.5 GB"), (UInt64(2048), "2 KB"),
  ])
  func `byte formatting`(_ input: (bytes: UInt64, text: String)) {
    #expect(Bytes.format(input.bytes) == input.text)
  }

  @Test func `outermost app bundle groups nested helpers`() {
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(ProcessSampler.outermostAppBundle(helper) == "/Applications/Google Chrome.app")
    #expect(ProcessSampler.outermostAppBundle("/usr/bin/python3") == nil)
  }

  @Test func `a live snapshot includes this test process`() {
    let snapshot = ProcessSampler.snapshot()
    let me = getpid()
    #expect(snapshot.groups.contains { $0.processes.contains { $0.pid == me } })
    #expect(snapshot.measuredTotal > 0)
  }

  @Test func `live system memory adds up`() {
    let memory = SystemMemory.current()
    #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
    #expect(memory.used > 0 && memory.used <= memory.total)
  }
}
