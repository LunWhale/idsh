import SwiftUI

/// In-app replacement for the desktop-only "open configuration file" action.
/// Files are read and written through the guest shell so fakefs' meta.db stays
/// in sync (writing the host `data/` directory directly is not reliable).
struct DSHConfigEditorView: View {
    @EnvironmentObject private var model: LauncherModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("文件", selection: $model.configFile) {
                    ForEach(LauncherModel.configFiles, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Text("/root/.dsh/profiles/web/\(model.configFile)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                TextEditor(text: $model.configText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.06))
                    .padding(12)
                    .disabled(model.configLoading)

                HStack(spacing: 12) {
                    Button(model.configLoading ? "载入中…" : "重新载入") {
                        model.loadConfigFile()
                    }
                    .disabled(model.configLoading)

                    Button("保存并重启 DSH") {
                        model.saveConfigFileAndRestart()
                    }
                    .disabled(model.configLoading || model.status != .ready)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if !model.configStatus.isEmpty {
                    Text(model.configStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
            .background(Color.black)
            .navigationTitle("DSH 配置文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { model.loadConfigFile() }
        }
        .preferredColorScheme(.dark)
    }
}
