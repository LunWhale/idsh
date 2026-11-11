import UIKit
import UniformTypeIdentifiers

/// Share Extension: stage bytes + manifest into the App Group, then hand off
/// to the main app. Never starts iSH or DSH here — extensions are short-lived
/// and memory-limited.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let openButton = UIButton(type: .system)
    private var stagedBatchID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let title = UILabel()
        title.text = "发送到 idsh"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white

        statusLabel.text = "正在接收文件…"
        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.65, alpha: 1)
        statusLabel.numberOfLines = 0

        spinner.color = .white
        spinner.startAnimating()

        openButton.setTitle("打开 idsh 继续", for: .normal)
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)
        openButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [title, statusLabel, spinner, openButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task { await stage() }
    }

    @objc private func openApp() {
        guard let id = stagedBatchID,
              let url = URL(string: "idsh://share/\(id)") else { return }
        extensionContext?.open(url) { _ in }
    }

    private func stage() async {
        do {
            let root = try ShareInbox.ensureRoot()
            let id = UUID().uuidString
            let dir = root.appendingPathComponent(id, isDirectory: true)
            let filesDir = dir.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

            var items: [ShareInbox.Item] = []
            let providers = providersFromInputItems()
            for (index, provider) in providers.enumerated() {
                if let item = await copy(provider: provider, index: index, into: filesDir) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else {
                await finish(message: "没有可发送的文件", batchID: nil)
                return
            }

            let batch = ShareInbox.Batch(
                id: id,
                createdAt: Date(),
                sourceApp: nil,
                items: items,
                status: "pending"
            )
            try ShareInbox.save(batch)
            stagedBatchID = id
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            await finish(
                message: "已接收 \(items.count) 个文件（\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))）",
                batchID: id
            )
        } catch {
            await finish(message: "接收失败：\(error.localizedDescription)", batchID: nil)
        }
    }

    private func providersFromInputItems() -> [NSItemProvider] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    private func copy(provider: NSItemProvider, index: Int, into dir: URL) async -> ShareInbox.Item? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let src = await loadFile(provider: provider) {
                let name = src.lastPathComponent.isEmpty ? "file-\(index)" : src.lastPathComponent
                let dst = dir.appendingPathComponent("\(index)-\(name)")
                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                    let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64) ?? 0
                    return .init(relativePath: "files/\(dst.lastPathComponent)",
                                 name: name,
                                 type: UTType(filenameExtension: dst.pathExtension)?.identifier ?? "public.data",
                                 size: size)
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider: provider, type: UTType.image.identifier) {
            let name = "image-\(index).png"
            let dst = dir.appendingPathComponent(name)
            if (try? data.write(to: dst)) != nil {
                return .init(relativePath: "files/\(name)", name: name, type: "public.image", size: Int64(data.count))
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider: provider) {
            let name = "text-\(index).txt"
            let dst = dir.appendingPathComponent(name)
            let data = Data(text.utf8)
            if (try? data.write(to: dst)) != nil {
                return .init(relativePath: "files/\(name)", name: name, type: "public.plain-text", size: Int64(data.count))
            }
        }
        return nil
    }

    private func loadFile(provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    private func loadData(provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    private func loadText(provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                cont.resume(returning: item as? String)
            }
        }
    }

    @MainActor
    private func finish(message: String, batchID: String?) {
        spinner.stopAnimating()
        statusLabel.text = message
        stagedBatchID = batchID
        if batchID != nil {
            openButton.isHidden = false
            if let id = batchID, let url = URL(string: "idsh://share/\(id)") {
                extensionContext?.open(url) { [weak self] ok in
                    Task { @MainActor in
                        if ok { self?.extensionContext?.completeRequest(returningItems: nil) }
                    }
                }
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
