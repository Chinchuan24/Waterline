import WaterlineCore
import SwiftUI

/// "Can I run this model?" — sized against the GPU's unified-memory cap and what's
/// actually available right now.
struct LocalAITab: View {
  let monitor: MemoryMonitor
  @AppStorage(Settings.quantization) private var quantization: Quantization = .q4

  var body: some View {
    let memory = monitor.panel.system
    let available = min(memory.available, monitor.panel.gpu.limit)
    let runtimes = LocalAIRuntime.detect(in: monitor.panel.processes.groups)
    let fits = ModelClass.catalog.map { model in
      (model, ModelFit.evaluate(
        required: model.requiredBytes(quantization), available: available,
        gpuLimit: monitor.panel.gpu.limit, totalMemory: memory.total))
    }

    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 16) {
          if monitor.panel.gpu.hasUnifiedMemory {
            figure("GPU can use", Bytes.format(monitor.panel.gpu.limit),
                   note: monitor.panel.gpu.isCustom ? "custom limit" : "\(Int((Double(monitor.panel.gpu.limit) / Double(max(memory.total, 1)) * 100).rounded()))% of RAM")
              .help("macOS caps how much unified memory the GPU may use. A model must fit under this cap to run on the GPU.")
          } else {
            figure("Runs on", "CPU", note: "Intel Mac · uses RAM")
              .help("Intel Macs don't share RAM with the GPU, so local models run mostly on the CPU from ordinary memory. Expect them to be much slower than on Apple Silicon.")
          }
          figure("Available now", Bytes.format(available), note: "free + reclaimable")
            .help("Memory a model could take right now without anything being compressed or swapped.")
          Spacer()
        }

        Picker("Quantization", selection: $quantization) {
          ForEach(Quantization.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("4-bit is what most people run locally (e.g. Q4_K_M in Ollama and LM Studio).")

        VStack(spacing: 0) {
          ForEach(fits, id: \.0.id) { model, fit in
            ModelRow(model: model, required: model.requiredBytes(quantization), fit: fit)
            if model.id != ModelClass.catalog.last?.id { Divider().opacity(0.5) }
          }
        }

        if !runtimes.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            Text("Running now").font(.caption).foregroundStyle(.secondary)
            ForEach(runtimes) { runtime in
              HStack {
                AppIcon(bundlePath: runtime.bundlePath)
                Text(runtime.name)
                Spacer()
                Text(Bytes.format(runtime.footprint, gbDecimals: 2)).monospacedDigit()
              }
              .font(.callout)
            }
          }
        }

        Text(footnote(hasOverLimit: fits.contains { $0.1 == .overGPULimit }))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
    }
  }

  private func figure(_ title: String, _ value: String, note: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
      Text(note).font(.caption2).foregroundStyle(.tertiary)
    }
  }

  private func footnote(hasOverLimit: Bool) -> String {
    var text = "Estimates for an ~8K-token context; longer contexts need more."
    // Leave macOS at least 8 GB (or 15% on big Macs), and only suggest a raise.
    let total = monitor.panel.system.total
    let reserve = max(8 * Bytes.gigabyte, total / 100 * 15)
    if hasOverLimit, monitor.panel.gpu.hasUnifiedMemory, total > reserve,
       total - reserve > monitor.panel.gpu.limit {
      text += " To let the GPU use more memory until the next restart, run: sudo sysctl iogpu.wired_limit_mb=\((total - reserve) / Bytes.megabyte)"
    }
    return text
  }
}

private struct ModelRow: View {
  let model: ModelClass
  let required: UInt64
  let fit: ModelFit

  var body: some View {
    HStack(spacing: 10) {
      Text(model.label)
        .font(.body.weight(.semibold).monospacedDigit())
        .frame(width: 44, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.examples).font(.callout).lineLimit(1)
        Text("needs ~\(Bytes.format(required))").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      FitPill(fit: fit)
    }
    .padding(.vertical, 5)
  }
}

private struct FitPill: View {
  let fit: ModelFit

  private var style: (text: String, tint: Color) {
    switch fit {
    case .fitsNow: ("Fits now", .green)
    case .needsFreeing(let bytes): ("Free \(Bytes.format(bytes))", .yellow)
    case .overGPULimit: ("Over GPU cap", .orange)
    case .tooBig: ("Too big", .red)
    }
  }

  // Primary text plus a colored dot: tinted text on a tinted pill is too faint in light mode.
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(style.tint).frame(width: 6, height: 6)
      Text(style.text)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(style.tint.opacity(0.16), in: Capsule())
  }
}
