import SwiftUI

/// Shown when a share batch arrives (cold start included). The files have
/// already been staged; this sheet only chooses the destination conversation.
struct ShareComposerView: View {
    @EnvironmentObject private var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let batch: ShareInbox.Batch

    var body: some View {
        NavigationStack {
            List {
                Section("\(batch.items.count) 个文件") {
                    ForEach(batch.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item.type))
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        deliver(.newSession)
                    } label: {
                        Label("发送到新会话", systemImage: "plus.bubble")
                    }
                    Button {
                        deliver(.currentSession)
                    } label: {
                        Label("发送到当前会话", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    Button {
                        deliver(.saveOnly)
                    } label: {
                        Label("仅保存到 /workspace", systemImage: "folder")
                    }
                } footer: {
                    Text("文件会保存到 guest 内 /workspace/inbox，并预填一条消息；发送前可以继续编辑。")
                }
            }
            .navigationTitle("发送到 idsh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deliver(_ mode: ShareDeliveryMode) {
        model.deliverShare(batch, mode: mode)
        dismiss()
    }

    private func icon(for type: String) -> String {
        if type.contains("image") { return "photo" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("text") { return "doc.text" }
        return "doc"
    }
}
