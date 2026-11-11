import HarnessISH
import SwiftUI

@MainActor
final class TerminalModel: ObservableObject {
    @Published var lines = "idsh console\n"
    @Published var command = "node -v"
    @Published var busy = false

    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        lines += "\n$ \(trimmed)\n"
        let pid = ISHShellExecutor.executeCommand(trimmed, lineCallback: { [weak self] line, isErr in
            Task { @MainActor in
                self?.lines += (isErr ? "[stderr] " : "") + line + "\n"
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                self?.busy = false
                self?.lines += "[exit \(result.exitCode)]\n"
            }
        })
        if pid < 0 {
            busy = false
            lines += "[failed to start: \(pid)]\n"
        }
    }
}

struct TerminalConsole: View {
    @EnvironmentObject private var model: LauncherModel
    @StateObject private var terminal = TerminalModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(terminal.lines)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("end")
                    }
                    .background(Color.black)
                    .onChange(of: terminal.lines) { _, _ in
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                HStack(spacing: 8) {
                    Text("$").font(.system(size: 13, design: .monospaced)).foregroundStyle(.green)
                    TextField("命令", text: $terminal.command)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { terminal.run(terminal.command) }
                    Button("运行") { terminal.run(terminal.command) }
                        .disabled(terminal.busy)
                }
                .padding(10)
                .background(Color(white: 0.06))
            }
            .navigationTitle("终端")
            .toolbar {
                Button("关闭") { dismiss() }
                Button("日志") { terminal.run("tail -n 120 /var/log/dsh.log") }
            }
        }
        .onAppear { if !model.terminalCommand.isEmpty { terminal.run(model.terminalCommand); model.terminalCommand = "" } }
    }
}
