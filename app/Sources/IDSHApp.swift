import SwiftUI
import UIKit

@main
struct IDSHApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { model.startIfNeeded() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundKeeper.shared.register()
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var model: LauncherModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LauncherView()
        }
        .fullScreenCover(isPresented: $model.showDSH) {
            DSHView(url: model.serverURL)
                .environmentObject(model)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $model.showTerminal) {
            TerminalConsole()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $model.showPlugins) {
            PluginsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showShareComposer) {
            if let batch = model.pendingShare {
                ShareComposerView(batch: batch).environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .onOpenURL { url in
            model.handleOpenURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.shareNotice {
                Text(notice)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.8), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15)))
                    .padding(.bottom, 24)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        model.shareNotice = nil
                    }
            }
        }
    }
}

struct LauncherView: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("idsh").font(.system(size: 34, weight: .semibold, design: .rounded))
                Spacer()
                StatusDot(status: model.status)
            }
            .padding(.top, 28)

            Text("DeepSeek Harness")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("Alpine 3.21 · Node 22 · DSH 0.2.2-rc.1")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .padding(.top, 10)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.headline).font(.system(size: 17, weight: .semibold))
                Text(model.detail).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                if model.status == .starting || model.status == .extracting {
                    ProgressView(value: model.progress)
                        .tint(Color(red: 0.82, green: 0.62, blue: 0.18))
                        .padding(.top, 6)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.035))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.12)))

            Button {
                model.enterDSH()
            } label: {
                HStack {
                    Text(model.status == .ready ? "进入 DSH" : "启动中…")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 18)
                .frame(height: 54)
                .background(model.status == .ready ? Color(red: 0.82, green: 0.62, blue: 0.18) : Color(white: 0.12))
                .foregroundStyle(model.status == .ready ? .black : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(model.status != .ready)
            .padding(.top, 12)

            HStack(spacing: 10) {
                LauncherButton("终端", "terminal") { model.showTerminal = true }
                LauncherButton("插件", "puzzlepiece.extension") { model.showPlugins = true }
                LauncherButton("设置", "slider.horizontal.3") { model.showSettings = true }
                LauncherButton("日志", "doc.text.magnifyingglass") { model.showTerminal = true; model.terminalCommand = "tail -n 80 /var/log/dsh.log" }
            }
            .padding(.top, 12)

            HStack(spacing: 12) {
                Text("启动模式")
                Spacer()
                Picker("启动模式", selection: Binding(
                    get: { model.fastStartup },
                    set: { model.setFastStartup($0) }
                )) {
                    Text("完整").tag(false)
                    Text("极简 · 快").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(white: 0.62))
            .padding(.top, 14)

            HStack(spacing: 14) {
                Label("音频", systemImage: "waveform")
                Label("iOS 26", systemImage: "bolt.shield")
                Label(model.portText, systemImage: "network")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(white: 0.42))
            .padding(.top, 18)

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }
}

struct LauncherButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    init(_ title: String, _ icon: String, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color(white: 0.035))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.12)))
        }
        .foregroundStyle(.white)
    }
}

struct StatusDot: View {
    let status: LauncherStatus
    var color: Color {
        switch status {
        case .ready: return Color(red: 0.3, green: 0.85, blue: 0.55)
        case .failed: return Color(red: 0.95, green: 0.32, blue: 0.28)
        case .stopped: return Color(white: 0.4)
        default: return Color(red: 0.82, green: 0.62, blue: 0.18)
        }
    }
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.6))
        }
    }
}

struct PluginsView: View {
    @EnvironmentObject private var model: LauncherModel
    var body: some View {
        NavigationStack {
            List {
                Section("插件系统") {
                    Text("DSH 使用同一套 Cordis 插件系统。纯 JS 插件、Linux ARM64 原生插件与源码编译插件路径已保留。")
                    Text("安装/卸载与 Creator 新建请在 DSH 内完成；这里先做状态与入口。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("打开 DSH 插件管理器") { model.showPlugins = false; model.enterDSH() }
                    Button("重置 rootfs") { model.resetRootfs() }.foregroundStyle(.red)
                }
            }
            .navigationTitle("插件")
            .toolbar { Button("关闭") { model.showPlugins = false } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: LauncherModel
    var body: some View {
        NavigationStack {
            List {
                Section("启动") {
                    Toggle("极简启动（快速）", isOn: Binding(
                        get: { model.fastStartup },
                        set: { model.setFastStartup($0) }
                    ))
                    Text("极简启动关闭办公文档、自动化任务、子代理、网页工具等非核心插件，保留会话、工作区、文件、终端和插件管理器。切换后会自动重启 DSH；完整启动保留全部功能。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("后台") {
                    Toggle("音频保活", isOn: $model.audioKeepAlive)
                    Toggle("iOS 26 持续处理", isOn: $model.continuedProcessing)
                    Text("DSH 常驻在 iSH 中；后台 CPU governor 由原生控制。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("DeepSeek 账号") {
                    Text("DSH Web 宿主不提供交互式登录回调，点“登录”会返回 protocol 错误。请在 DSH 内用 API Key 连接。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("去 DSH 添加 API Key") {
                        model.showSettings = false
                        model.enterDSH()
                    }
                }
                Section("服务") {
                    LabeledContent("端口", value: "\(model.port)")
                    LabeledContent("Node", value: "22.23.4")
                    LabeledContent("DSH", value: model.dshVersion)
                    LabeledContent("rootfs", value: model.rootfsPath)
                }
                Section("DSH 更新") {
                    if let latest = model.latestDSHVersion, latest != model.dshVersion {
                        Button("更新到 \(latest)") { model.installDSHUpdate() }
                    }
                    Button(model.checkingUpdate ? "检查中…" : "检查更新") {
                        model.checkDSHUpdate()
                    }
                    .disabled(model.checkingUpdate)
                    if !model.updateStatus.isEmpty {
                        Text(model.updateStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("重启 DSH") { model.restartDSH() }
                    Button("导出诊断") { model.exportDiagnostics() }
                }
            }
            .navigationTitle("设置")
            .toolbar { Button("关闭") { model.showSettings = false } }
        }
    }
}
