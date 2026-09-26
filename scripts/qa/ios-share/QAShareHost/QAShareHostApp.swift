import SwiftUI
import UIKit

/// Stand-in for "any third-party app" sharing into Sonar (scripts/qa/ios-share-smoke.sh).
///
/// The UI test launches this app with `QA_SHARE_ITEMS`, a JSON array of
/// `{"kind": "file"|"image"|"text"|"url"|"export", "path"?, "name"?, "value"?, "type"?}`. Files
/// are copied into this app's own container first — a real app shares a URL it
/// owns, not a path in someone else's — then the "QA Share" button presents a
/// `UIActivityViewController` over those items, exactly as a mail client or a
/// document viewer does. The share extension therefore sees the same
/// `NSItemProvider` shape real apps produce, which is the thing #559 is about.
///
/// `export` is the other common shape: an app that builds a document in memory
/// ("Export CSV") and hands over its OWN provider — the bytes registered under
/// `type` plus a `suggestedName` — through `UIActivityItemsConfiguration`.
@main
struct QAShareHostApp: App {
    var body: some Scene {
        WindowGroup { QAShareHostView() }
    }
}

private struct QAShareItemSpec: Decodable {
    let kind: String
    let path: String?
    let name: String?
    let value: String?
    let type: String?
}

private struct QAShareHostView: View {
    @State private var items: [Any] = []
    @State private var providers: [NSItemProvider] = []
    @State private var status = "loading"
    @State private var presenting = false

    var body: some View {
        VStack(spacing: 24) {
            Text("QA share host").font(.headline)
            Text(status).font(.footnote).accessibilityIdentifier("qa-share-status")
            Button("QA Share") { presenting = true }
                .accessibilityIdentifier("qa-share-button")
                .disabled(items.isEmpty && providers.isEmpty)
        }
        .padding()
        .onAppear(perform: load)
        .sheet(isPresented: $presenting) {
            QAActivityView(items: items, providers: providers)
        }
    }

    private func load() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["QA_SHARE_ITEMS"], let data = raw.data(using: .utf8),
              let specs = try? JSONDecoder().decode([QAShareItemSpec].self, from: data)
        else {
            status = "no QA_SHARE_ITEMS"
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qa-share", isDirectory: true)
        try? fm.removeItem(at: root)
        var loaded: [Any] = []
        var exports: [NSItemProvider] = []
        for (index, spec) in specs.enumerated() {
            switch spec.kind {
            case "file":
                guard let path = spec.path else { continue }
                let source = URL(fileURLWithPath: path)
                // One directory per item so two items may share a filename —
                // that is one of the cases under test.
                let dir = root.appendingPathComponent("\(index)", isDirectory: true)
                let name = spec.name ?? source.lastPathComponent
                let dest = dir.appendingPathComponent(name)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: dest)
                    loaded.append(dest)
                } catch {
                    status = "copy failed: \(name): \(error.localizedDescription)"
                    return
                }
            case "image":
                guard let path = spec.path, let image = UIImage(contentsOfFile: path) else { continue }
                loaded.append(image)
            case "text":
                if let value = spec.value { loaded.append(value) }
            case "url":
                if let value = spec.value, let url = URL(string: value) { loaded.append(url) }
            case "export":
                guard let path = spec.path, let type = spec.type,
                      let data = FileManager.default.contents(atPath: path) else { continue }
                let provider = NSItemProvider(item: data as NSData, typeIdentifier: type)
                provider.suggestedName = spec.name
                exports.append(provider)
            default:
                continue
            }
        }
        items = loaded
        providers = exports
        status = "ready \(loaded.count + exports.count)"
    }
}

private struct QAActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let providers: [NSItemProvider]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        if !providers.isEmpty {
            return UIActivityViewController(
                activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: providers)
            )
        }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
