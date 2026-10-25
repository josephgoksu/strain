import Foundation

/// Where AI tools keep data: models, transcripts, a sandbox VM. Strain sizes and reveals them, never deletes them:
/// a model is a big download, a transcript is yours. Caches of the same tools are Clean items (`.chromium`).
struct AIData: Identifiable {
    let id: String, title: String, detail: String, symbol: String
    let rel: String              // path relative to home
    var models: ModelLayout? = nil

    /// How a tool lays out its models on disk, to list them by name.
    enum ModelLayout { case ollama, huggingFace, lmStudio }

    static let all: [AIData] = [
        .init(id: "claudevm", title: "Claude sandbox", detail: "The Linux VM Claude runs code in. Claude manages it; deleting it by hand can break Claude's sandbox.",
              symbol: "shippingbox", rel: "Library/Application Support/Claude/vm_bundles"),
        .init(id: "claudecode", title: "Claude Code sessions", detail: "Your Claude Code transcripts, per project. Resume and history read them.",
              symbol: "text.bubble", rel: ".claude/projects"),
        .init(id: "codex", title: "Codex sessions", detail: "Your Codex transcripts. Resume reads them.", symbol: "text.bubble", rel: ".codex/sessions"),
        .init(id: "codexruntime", title: "Codex runtime", detail: "The runtime the Codex app downloaded to run tasks.", symbol: "gearshape.2", rel: ".cache/codex-runtimes"),
        .init(id: "ollama", title: "Ollama models", detail: "Models Ollama pulled. Remove one with `ollama rm <name>`.", symbol: "cube", rel: ".ollama/models", models: .ollama),
        .init(id: "huggingface", title: "Hugging Face models", detail: "Models downloaded by transformers and other Hugging Face tools.",
              symbol: "cube", rel: ".cache/huggingface", models: .huggingFace),
        .init(id: "lmstudio", title: "LM Studio models", detail: "Models LM Studio downloaded. Remove them in LM Studio's My Models.", symbol: "cube", rel: ".lmstudio/models", models: .lmStudio),
    ]

    func url(home: String = NSHomeDirectory()) -> URL { URL(fileURLWithPath: home + "/" + rel) }

    /// Model names, as each tool names them.
    func modelNames(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        func children(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
        switch models {
        case .ollama:  // manifests/<registry>/<namespace>/<model>/<tag>
            let registries = url(home: home).appendingPathComponent("manifests")
            return children(registries).flatMap { r in
                children(registries.appendingPathComponent(r)).flatMap { ns in
                    children(registries.appendingPathComponent("\(r)/\(ns)")).flatMap { m in
                        children(registries.appendingPathComponent("\(r)/\(ns)/\(m)")).map { ns == "library" ? "\(m):\($0)" : "\(ns)/\(m):\($0)" }
                    }
                }
            }
        case .huggingFace:  // hub/models--<org>--<name>
            return children(url(home: home).appendingPathComponent("hub")).filter { $0.hasPrefix("models--") }
                .map { $0.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/") }
        case .lmStudio:  // <publisher>/<model>
            return children(url(home: home)).flatMap { p in children(url(home: home).appendingPathComponent(p)).map { "\(p)/\($0)" } }
        case nil:
            return []
        }
    }
}
