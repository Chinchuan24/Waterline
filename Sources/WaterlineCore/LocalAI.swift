import Foundation
import Metal

/// How much memory a local model can use.
///
/// On Apple Silicon the GPU shares RAM (unified memory) but is capped; a model's weights
/// must fit under that cap to run on the GPU, no matter how much RAM is free. Intel Macs
/// have separate (or tiny shared) video memory, so local models run mostly on the CPU
/// from ordinary RAM, and the limit is simply physical memory.
public struct GPUBudget: Sendable, Equatable {
  public let limit: UInt64
  /// The user raised or lowered the cap with `sysctl iogpu.wired_limit_mb`.
  public let isCustom: Bool
  /// False on Intel Macs: the GPU doesn't share RAM, so `limit` is RAM for CPU inference.
  public let hasUnifiedMemory: Bool

  public init(limit: UInt64, isCustom: Bool, hasUnifiedMemory: Bool = true) {
    self.limit = limit
    self.isCustom = isCustom
    self.hasUnifiedMemory = hasUnifiedMemory
  }

  public static func current(totalMemory: UInt64) -> GPUBudget {
    let device = MTLCreateSystemDefaultDevice()
    guard device?.hasUnifiedMemory ?? false else {
      return GPUBudget(limit: totalMemory, isCustom: false, hasUnifiedMemory: false)
    }
    if let megabytes = Sysctl.integer("iogpu.wired_limit_mb"), megabytes > 0 {
      return GPUBudget(limit: UInt64(megabytes) * Bytes.megabyte, isCustom: true)
    }
    if let device {
      return GPUBudget(limit: device.recommendedMaxWorkingSetSize, isCustom: false)
    }
    return GPUBudget(limit: totalMemory / 4 * 3, isCustom: false)
  }
}

public enum Quantization: String, CaseIterable, Sendable, Identifiable, Codable {
  case q4, q8, f16

  public var id: Self { self }

  public var title: String {
    switch self {
    case .q4: "4-bit"
    case .q8: "8-bit"
    case .f16: "16-bit"
    }
  }

  /// Typical GGUF/MLX sizes: Q4_K_M ≈ 4.8 bits, Q8_0 ≈ 8.5 bits per weight.
  public var bytesPerParameter: Double {
    switch self {
    case .q4: 0.6
    case .q8: 1.07
    case .f16: 2.0
    }
  }
}

public struct ModelClass: Sendable, Identifiable, Equatable {
  public let label: String
  public let billions: Double
  public let examples: String
  public var id: String { label }

  public init(label: String, billions: Double, examples: String) {
    self.label = label
    self.billions = billions
    self.examples = examples
  }

  /// Weights plus room for the runtime and an ~8K-token context.
  public func requiredBytes(_ quantization: Quantization) -> UInt64 {
    let weights = billions * 1e9 * quantization.bytesPerParameter
    let overhead = Double(Bytes.gigabyte) + weights * 0.08
    return UInt64(weights + overhead)
  }

  public static let catalog: [ModelClass] = [
    ModelClass(label: "4B", billions: 4, examples: "Gemma 3 4B, Qwen3 4B"),
    ModelClass(label: "8B", billions: 8, examples: "Llama 3.1 8B, Qwen3 8B"),
    ModelClass(label: "14B", billions: 14, examples: "Qwen3 14B, Phi-4"),
    ModelClass(label: "27B", billions: 27, examples: "Gemma 3 27B"),
    ModelClass(label: "32B", billions: 32, examples: "Qwen3 32B"),
    ModelClass(label: "70B", billions: 70, examples: "Llama 3.3 70B"),
    ModelClass(label: "120B", billions: 120, examples: "gpt-oss-120b"),
    ModelClass(label: "235B", billions: 235, examples: "Qwen3 235B"),
  ]
}

public enum ModelFit: Sendable, Equatable {
  case fitsNow
  /// Fits under the GPU cap, but this much more memory has to be freed first.
  case needsFreeing(UInt64)
  /// Fits in RAM, but above the GPU's wired-memory cap.
  case overGPULimit
  case tooBig

  public static func evaluate(
    required: UInt64, available: UInt64, gpuLimit: UInt64, totalMemory: UInt64
  ) -> ModelFit {
    if required > totalMemory { return .tooBig }
    if required > gpuLimit { return .overGPULimit }
    if required <= available { return .fitsNow }
    return .needsFreeing(required - available)
  }
}

public enum LocalAIRuntime {
  private static let prefixes = [
    "ollama", "lm studio", "lmstudio", "llama-server", "llama-cli", "koboldcpp", "gpt4all",
    "msty", "localai", "mlx_lm",
  ]
  private static let exactNames: Set<String> = ["jan"]

  /// Running local-model runtimes (Ollama, LM Studio, llama.cpp, …) from a snapshot.
  public static func detect(in groups: [AppGroup]) -> [AppGroup] {
    groups.filter { group in
      let name = group.name.lowercased()
      return exactNames.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }
  }
}
