import HarnessISH
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum LauncherStatus: String, Equatable {
    case idle, extracting, booting, starting, ready, degraded, failed, stopped
    var label: String {
        switch self {
        case .idle: return "空闲"
        case .extracting: return "解压 rootfs"
        case .booting: return "启动 Linux"
        case .starting: return "启动 DSH"
        case .ready: return "运行中"
        case .degraded: return "降级"
        case .failed: return "失败"
        case .stopped: return "已停止"
        }
    }
}

enum ShareDeliveryMode {
    case newSession, currentSession, saveOnly
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var status: LauncherStatus = .idle
    @Published var headline = "准备启动"
    @Published var detail = "等待初始化"
    @Published var progress: Double = 0
    @Published var bootStartedAt: Date?
    @Published var showPerformanceHUD = UserDefaults.standard.bool(forKey: "idshPerformanceHUD")
    @Published var showConfigEditor = false
    @Published var configFile = LauncherModel.configFiles[0]
    @Published var configText = ""
    @Published var configStatus = ""
    @Published var configLoading = false

    static let configFiles = [
        "cordis.patch.yml",
        "cordis.yml",
        "package.json",
        "pnpm-workspace.yaml",
        "dsh.profile.bundles.yml",
    ]
    @Published var serverURL: URL?
    @Published var showDSH = false
    @Published var showTerminal = false
    @Published var showPlugins = false
    @Published var showSettings = false
    @Published var terminalCommand = ""
    @Published var audioKeepAlive = true
    @Published var continuedProcessing = true
    @Published var backgroundBoot = UserDefaults.standard.object(forKey: "idshBackgroundBoot") as? Bool ?? true
    @Published var fastStartup = UserDefaults.standard.bool(forKey: "idshFastStartup")
    @Published var backgroundBootArmed = false
    @Published var port = 8790
    @Published var rootfsPath = "—"
    @Published var pendingShare: ShareInbox.Batch?
    @Published var showShareComposer = false
    @Published var shareNotice: String?
    @Published var dshVersion = "—"
    @Published var latestDSHVersion: String?
    @Published var updateStatus = ""
    @Published var checkingUpdate = false

    private let installer = ISHRootfsInstaller()
    private var started = false
    private var pollingTask: Task<Void, Never>?
    private var rootURL: URL?
    private var supervisorProcess: ISHShellProcess?
    private var evalTask: Task<Void, Never>?
    private var workspaceURL: URL?
    private var pendingShareBatchID: String?
    private var pendingShareMode: ShareDeliveryMode = .currentSession
    private var dshPageReady = false
    private var pendingJS: String?
    private var webReadyObserver: NSObjectProtocol?
    private var evalResultObserver: NSObjectProtocol?
    private var pendingAutoEnter = false
    private var bootInProgress: Bool {
        status == .extracting || status == .booting || status == .starting
    }

    var portText: String { ":\(port)" }

    /// Host-visible command channel used to drive the DSH page during
    /// development and verification: writing JavaScript into
    /// `Library/Caches/idsh-eval-in.js` evaluates it in the live web view.
    private var evalInbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-eval-in.js")
    }
    private var evalOutbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-eval-out.txt")
    }
    /// Supervisor stdout/stderr tail, kept away from the eval outbox so
    /// automated UI probes are not clobbered by guest log lines.
    private var supervisorLog: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-supervisor.log")
    }

    /// Host-visible shell channel: writing a command line into
    /// `Library/Caches/idsh-cmd-in.txt` runs it through the same
    /// `ISHShellExecutor` path the in-app terminal uses, and streams the
    /// output into `idsh-cmd-out.txt`. Used for automated verification of the
    /// guest (pnpm, dsh, terminals) without driving the UI.
    private var cmdInbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-cmd-in.txt")
    }
    private var cmdOutbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-cmd-out.txt")
    }

    func startEvalWatcher() {
        if evalResultObserver == nil {
            evalResultObserver = NotificationCenter.default.addObserver(
                forName: .idshEvalResult, object: nil, queue: .main
            ) { [weak self] note in
                guard let text = note.object as? String else { return }
                Task { @MainActor in
                    guard let self else { return }
                    try? text.write(to: self.evalOutbox, atomically: true, encoding: .utf8)
                }
            }
        }
        if webReadyObserver == nil {
            webReadyObserver = NotificationCenter.default.addObserver(
                forName: .idshWebReady, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.dshPageReady = true
                    if let js = self.pendingJS {
                        self.pendingJS = nil
                        NotificationCenter.default.post(name: .idshEval, object: js)
                    }
                }
            }
        }
        guard evalTask == nil else { return }
        evalTask = Task { [weak self] in
            var last: String?
            var lastCmd: String?
            while !Task.isCancelled {
                if let self, let js = try? String(contentsOf: self.evalInbox, encoding: .utf8),
                   !js.isEmpty, js != last {
                    last = js
                    NSLog("idsh eval in: \(js.prefix(200))")
                    NotificationCenter.default.post(name: .idshEval, object: js)
                }
                if let self,
                   let cmd = try? String(contentsOf: self.cmdInbox, encoding: .utf8),
                   !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   cmd != lastCmd {
                    lastCmd = cmd
                    let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                    NSLog("idsh cmd in: \(trimmed.prefix(200))")
                    let outbox = self.cmdOutbox
                    var buffer = "$ \(trimmed)\n"
                    try? buffer.write(to: outbox, atomically: true, encoding: .utf8)
                    _ = ISHShellExecutor.executeCommand(
                        trimmed,
                        lineCallback: { line, isErr in
                            buffer += (isErr ? "[err] " : "") + line + "\n"
                            try? buffer.write(to: outbox, atomically: true, encoding: .utf8)
                        },
                        completion: { result in
                            buffer += "IDSH_CMD_EXIT:\(result.exitCode) pid=\(result.pid) error=\(result.error.rawValue)\n"
                            try? buffer.write(to: outbox, atomically: true, encoding: .utf8)
                            NSLog("idsh cmd done: exit=\(result.exitCode)")
                        }
                    )
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        if audioKeepAlive { BackgroundKeeper.shared.startAudio() }
        startEvalWatcher()
        loadRecentPendingShare()
        Task { await start() }
    }

    private func start() async {
        let firstRun = !(await installer.isInstalled)
        status = .extracting
        headline = firstRun ? "首次启动" : "检查 rootfs"
        detail = firstRun
            ? "首次启动需展开 Alpine 文件系统，约 2–3 分钟；可切到后台继续"
            : "正在准备 Alpine 文件系统"
        progress = 0
        bootStartedAt = Date()
        armBackgroundBootIfNeeded()
        // Notification permission is only requested when the user opts into
        // background boot in Settings; never block first launch with a prompt.
        do {
            let installation = try await installer.installIfNeeded { progressInfo in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.progress = min(0.5, progressInfo.fraction * 0.5)
                    self.headline = "解压 rootfs"
                    self.detail = "已完成 \(progressInfo.completedEntries)/\(progressInfo.totalEntries) 个文件"
                    self.updateBackgroundBootProgress()
                }
            }
            rootURL = installation.rootURL
            rootfsPath = installation.rootURL.lastPathComponent
            progress = 0.55
            status = .booting
            headline = "启动 Linux"
            detail = "挂载 fakefs、初始化 PID 1"
            updateBackgroundBootProgress()
            let rc = ISHKernel.shared.boot(withRootPath: installation.rootURL.path)
            guard rc >= 0 else {
                fail("iSH boot 失败：\(rc)")
                return
            }
            ISHKernel.shared.guestNetworkEnabled = true
            mountShareWorkspace()
            status = .starting
            headline = "启动 DSH"
            detail = "Node supervisor 正在拉起 dsh web"
            progress = 0.6
            updateBackgroundBootProgress()
            for name in ["dsh.url", "dsh.state"] {
                try? FileManager.default.removeItem(
                    at: installation.rootURL.appendingPathComponent("data/tmp/\(name)")
                )
            }
            startSupervisor()
            pollForURL()
        } catch {
            fail("rootfs 安装失败：\(error.localizedDescription)")
        }
    }

    private func startSupervisor() {
        supervisorProcess?.terminate()
        var pending = ""
        let process = ISHShellExecutor.startPersistentExecutable(
            "/usr/local/bin/dsh-node",
            arguments: ["/usr/local/bin/dsh-supervisor.mjs"],
            environment: {
                var env = [
                    "HOME": "/root",
                    "PATH": "/usr/local/bin:/usr/bin:/bin",
                    "DSH_FAST_MODE": fastStartup ? "1" : "0",
                    "NODE_EXTRA_CA_CERTS": "/etc/ssl/cert.pem",
                    "SSL_CERT_FILE": "/etc/ssl/cert.pem",
                ]
                if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty {
                    env["DEEPSEEK_API_KEY"] = key
                }
                // Tested providers used by the desktop profile. Only keys explicitly
                // passed by the launcher are forwarded; secrets never come from the bundle.
                for name in ["UNCENSORED_API_KEY", "AUTO_NEW_API_KEY", "RJK66_BACKUP_API_KEY",
                             "NITIAN_API_KEY", "OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"] {
                    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
                        env[name] = value
                    }
                }
                return env
            }(),
            fsContext: 0,
            outputCallback: { [weak self] data, isErr in
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                Task { @MainActor in
                    guard let self else { return }
                    pending += text
                    if pending.count > 4096 { pending = String(pending.suffix(2048)) }
                    let lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
                    if lines.count > 1 {
                        pending = String(lines.last ?? "")
                        let visible = lines.dropLast().filter {
                            let line = $0.trimmingCharacters(in: .whitespaces)
                            // iSH injects LD_PRELOAD=/lib/zero_free.so for any binary named "node".
                            // Debian has no such hook; glibc warns once and continues. Keep it out of the launcher.
                            return !line.isEmpty && !line.contains("LD_PRELOAD cannot be preloaded")
                        }
                        if let last = visible.last {
                            self.detail = String(last).prefix(300).description
                            try? String(last).write(to: self.supervisorLog, atomically: true, encoding: .utf8)
                        }
                    }
                    _ = isErr
                }
            },
            completion: { result in
                NSLog("SUPERVISOR_EXIT code=\(result.exitCode) pid=\(result.pid) err=\(result.errorOutput.prefix(600)) out=\(result.output.prefix(600))")
            }
        )
        supervisorProcess = process
        if process == nil {
            detail = "supervisor 启动失败"
        }
    }

    private func pollForURL() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            for tick in 0..<420 {
                if Task.isCancelled { return }
                if self.status == .starting {
                    self.progress = max(self.progress, 0.6 + min(0.3, Double(tick) / 420.0 * 0.3))
                }
                if let root = self.rootURL {
                    let file = root.appendingPathComponent("data/tmp/dsh.url")
                    let stateFile = root.appendingPathComponent("data/tmp/dsh.state")
                    let state = (try? String(contentsOf: stateFile, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if state == "ready",
                       let text = try? String(contentsOf: file, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       let url = URL(string: text), !text.isEmpty {
                        self.serverURL = url
                        self.port = url.port ?? 8790
                        self.status = .ready
                        self.progress = 1
                        self.headline = "DSH 已就绪"
                        self.detail = "\(url.host ?? "127.0.0.1"):\(self.port) · token 已就绪" + (self.fastStartup ? " · 极简模式" : "")
                        self.backgroundBootArmed = false
                        BackgroundKeeper.shared.finishContinued(success: true)
                        BackgroundKeeper.shared.endBackgroundExecution()
                        if ProcessInfo.processInfo.arguments.contains("--open-config") {
                            self.showConfigEditor = true
                            self.showDSH = false
                        } else if UIApplication.shared.applicationState == .active {
                            self.showDSH = true
                            self.pendingAutoEnter = false
                        } else {
                            // Creating the WebView while suspended wastes the
                            // memory budget that the guest still needs. Enter on
                            // the next foreground instead.
                            self.pendingAutoEnter = true
                            self.notifyReadyIfNeeded()
                        }
                        self.presentQueuedShareIfNeeded()
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self.fail("dsh web 在 420 秒内没有写出 URL")
        }
    }

    private func fail(_ message: String) {
        status = .failed
        headline = "启动失败"
        detail = message
        progress = 0
        backgroundBootArmed = false
        BackgroundKeeper.shared.finishContinued(success: false)
        BackgroundKeeper.shared.endBackgroundExecution()
    }

    // MARK: - Background boot

    /// Called while the app is still foregrounded. Submits the iOS 26
    /// continued-processing request so the user can leave immediately.
    func prepareBackgroundBoot() {
        guard bootInProgress else { return }
        backgroundBootArmed = true
        // Notification permission is only requested when the user opts into
        // background boot in Settings; never block first launch with a prompt.
        BackgroundKeeper.shared.startAudio()
        BackgroundKeeper.shared.beginBackgroundExecution()
        BackgroundKeeper.shared.submitContinued(
            title: "idsh 正在准备",
            subtitle: detail,
            progress: progress
        )
        shareNotice = "已开启后台准备，可以切到其他 App；完成后会通知你"
        updateBackgroundBootProgress()
    }

    private func armBackgroundBootIfNeeded() {
        guard backgroundBoot, bootInProgress else { return }
        backgroundBootArmed = true
    }

    private func updateBackgroundBootProgress() {
        guard backgroundBootArmed else { return }
        BackgroundKeeper.shared.updateContinued(
            title: "idsh 正在准备",
            subtitle: detail,
            progress: progress
        )
    }

    private func requestNotificationPermissionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "idshNotificationAsked") == false else { return }
        UserDefaults.standard.set(true, forKey: "idshNotificationAsked")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("idsh notification permission granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
        }
    }

    private func notifyReadyIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "idsh 已就绪"
        content.body = "DSH 已在后台启动完成，点按进入。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "idsh.ready",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("idsh ready notification failed: \(error.localizedDescription)") }
        }
    }

    func setBackgroundBoot(_ enabled: Bool) {
        backgroundBoot = enabled
        UserDefaults.standard.set(enabled, forKey: "idshBackgroundBoot")
        if enabled { requestNotificationPermissionIfNeeded() }
    }

    func enterDSH() {
        guard serverURL != nil else { return }
        showDSH = true
    }

    func setPerformanceHUD(_ enabled: Bool) {
        showPerformanceHUD = enabled
        UserDefaults.standard.set(enabled, forKey: "idshPerformanceHUD")
    }

    // MARK: - Config editor (guest-side, fakefs-aware)

    private var profileDir: String { "/root/.dsh/profiles/web" }

    func loadConfigFile() {
        guard status == .ready else {
            configStatus = "DSH 未就绪，无法读取 guest 文件"
            return
        }
        guard !configLoading else { return }
        configLoading = true
        configStatus = "读取 \(configFile)…"
        let path = "\(profileDir)/\(configFile)"
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var output = ""
        DispatchQueue.main.async {
            _ = ISHShellExecutor.executeCommand(
                "/bin/base64 -w0 \(quoted)",
                lineCallback: { line, _ in
                    output += line
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.configLoading = false
                        if result.exitCode == 0, let data = Data(base64Encoded: output),
                           let text = String(data: data, encoding: .utf8) {
                            self.configText = text
                            self.configStatus = "已载入 \(text.count) 字符"
                        } else {
                            self.configText = ""
                            self.configStatus = "读取失败（exit=\(result.exitCode)）"
                        }
                    }
                }
            )
        }
    }

    func saveConfigFileAndRestart() {
        guard status == .ready else {
            configStatus = "DSH 未就绪，无法写入 guest 文件"
            return
        }
        guard !configLoading else { return }
        configLoading = true
        configStatus = "写入 \(configFile)…"
        let path = "\(profileDir)/\(configFile)"
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let base64 = Data(configText.utf8).base64EncodedString()
        let command = "printf '%s' '\(base64)' | /bin/base64 -d > \(quoted)"
        DispatchQueue.main.async {
            _ = ISHShellExecutor.executeCommand(
                command,
                lineCallback: { _, _ in },
                completion: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.configLoading = false
                        if result.exitCode == 0 {
                            self.configStatus = "已保存，正在重启 DSH…"
                            self.showConfigEditor = false
                            self.restartDSH()
                        } else {
                            self.configStatus = "保存失败（exit=\(result.exitCode)）"
                        }
                    }
                }
            )
        }
    }

    var elapsedText: String {
        guard let start = bootStartedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The minimal startup layer is a different `dsh web` invocation, so it
    /// only takes effect on the next start. Persist the choice first so a
    /// failed restart still remembers what the user asked for.
    func setFastStartup(_ enabled: Bool) {
        guard fastStartup != enabled else { return }
        fastStartup = enabled
        UserDefaults.standard.set(enabled, forKey: "idshFastStartup")
        shareNotice = enabled ? "已切换极简启动，正在重启 DSH…" : "已切换完整启动，正在重启 DSH…"
        if started && status == .ready { restartDSH() }
    }

    func restartDSH() {
        serverURL = nil
        status = .starting
        headline = "重启 DSH"
        detail = "停止旧进程并重新拉起"
        supervisorProcess?.terminate()
        supervisorProcess = nil
        startSupervisor()
        pollForURL()
    }

    // MARK: - Share Extension hand-off

    /// Cold-start / foreground hook for `idsh://share/<batch-id>`.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "idsh" else { return }
        switch url.host {
        case "config":
            showConfigEditor = true
            return
        case "settings":
            showSettings = true
            return
        case "hud":
            setPerformanceHUD(!showPerformanceHUD)
            return
        case "share":
            break
        default:
            return
        }
        let id = url.lastPathComponent
        guard let batch = ShareInbox.loadBatches().first(where: { $0.id == id }) else {
            shareNotice = "分享批次已失效"
            return
        }
        if status == .ready {
            pendingShare = batch
            showShareComposer = true
        } else {
            pendingShareBatchID = batch.id
            pendingShareMode = .currentSession
            shareNotice = "分享已排队，DSH 就绪后继续"
        }
    }

    /// On launch, only resurface a hand-off that happened minutes ago, so a
    /// cancelled sheet does not reappear forever.
    private func loadRecentPendingShare() {
        let recent = ShareInbox.loadBatches().first {
            $0.status == "pending" && Date().timeIntervalSince($0.createdAt) < 600
        }
        if let recent {
            pendingShareBatchID = recent.id
            pendingShare = recent
        }
    }

    private func presentQueuedShareIfNeeded() {
        guard let id = pendingShareBatchID,
              let batch = ShareInbox.loadBatches().first(where: { $0.id == id }) else { return }
        if ProcessInfo.processInfo.environment["IDSH_AUTO_DELIVER"] == "1" {
            deliverShare(batch, mode: .newSession)
            return
        }
        pendingShare = batch
        showShareComposer = true
    }

    /// Bind the host Documents/workspace into the guest. fakefs only indexes
    /// paths that exist in meta.db at boot, so a bind mount is the reliable
    /// way to expose files written by iOS later.
    private func mountShareWorkspace() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ws = docs.appendingPathComponent("workspace", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        } catch {
            NSLog("idsh workspace mkdir failed: \(error)")
        }
        let rc = ISHKernel.shared.bindMountPath("/workspace", toHostPath: ws.path)
        NSLog("idsh bind /workspace -> \(ws.path) rc=\(rc)")
        workspaceURL = rc >= 0 ? ws : nil
        if rc < 0 {
            shareNotice = "无法挂载 /workspace，分享文件将只留在 App 内"
        }
    }

    /// Dismissing the share sheet must not leave the batch pending, otherwise
    /// the next launch resurfaces the same sheet (observed in testing).
    func cancelShare() {
        if let batch = pendingShare {
            ShareInbox.markCancelled(batch.id)
        }
        pendingShare = nil
        pendingShareBatchID = nil
        showShareComposer = false
    }

    func deliverShare(_ batch: ShareInbox.Batch, mode: ShareDeliveryMode) {
        guard let workspace = workspaceURL else {
            shareNotice = "workspace 未挂载"
            return
        }
        let inbox = workspace.appendingPathComponent("inbox/\(batch.id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            for (index, item) in batch.items.enumerated() {
                guard let src = ShareInbox.itemURL(item, in: batch.id) else { continue }
                let name = "\(index)-\(item.name)"
                let dst = inbox.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
            }
        } catch {
            shareNotice = "复制失败：\(error.localizedDescription)"
            return
        }

        if mode == .saveOnly {
            ShareInbox.markDelivered(batch.id)
            shareNotice = "已保存到 /workspace/inbox/\(batch.id)"
            return
        }

        guard status == .ready else {
            pendingShareBatchID = batch.id
            pendingShareMode = mode
            shareNotice = "已排队，DSH 就绪后预填消息"
            return
        }
        injectSharePrompt(batch, mode: mode)
    }

    private func injectSharePrompt(_ batch: ShareInbox.Batch, mode: ShareDeliveryMode) {
        let lines = batch.items.enumerated().map { index, item in
            "/workspace/inbox/\(batch.id)/\(index)-\(item.name)"
        }.joined(separator: "、")
        let prompt = "我通过 iOS 分享面板加入了这些文件：\(lines)。请先确认内容，然后等待我的下一条指令。"

        var payload: [String: Any] = ["text": prompt]
        if mode == .newSession { payload["newSession"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (function(){
          var p = \(json);
          var tries = 0;
          function log(m){ try { window.webkit.messageHandlers.idshLog.postMessage('SHARE ' + m); } catch(e) {} }
          function modalButton(){
            var labels = ['继续','知道了','关闭'];
            return Array.from(document.querySelectorAll('button')).find(function(x){
              var t = (x.textContent || '').trim();
              var a = (x.getAttribute('aria-label') || '').trim();
              return labels.indexOf(t) >= 0 || labels.indexOf(a) >= 0;
            });
          }
          function dismiss(){
            var b = modalButton();
            if (b) { log('dismiss ' + (b.textContent || '').trim()); b.click(); return true; }
            return false;
          }
          function fill(){
            tries++;
            if (dismiss()) { setTimeout(fill, 600); return 'dismissed'; }
            var el = document.querySelector('textarea') ||
                     document.querySelector('[contenteditable="true"]');
            if (!el) {
              if (tries < 80) { setTimeout(fill, 500); return 'waiting'; }
              log('no-input');
              return 'no-input';
            }
            el.click();
            el.focus();
            if (el.tagName === 'TEXTAREA') {
              var setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
              setter.call(el, p.text);
              el.dispatchEvent(new Event('input', { bubbles: true }));
            } else {
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, p.text);
            }
            var value = (el.value !== undefined ? el.value : el.innerText) || '';
            log('filled ' + value.length + ' focused=' + (document.activeElement === el));
            if (value.length < 4 && tries < 12) { setTimeout(fill, 400); return 'retry'; }
            return 'ok:' + value.slice(0, 40);
          }
          function start(){
            if (dismiss()) { setTimeout(start, 700); return 'dismissed'; }
            if (!p.newSession) return fill();
            var b = Array.from(document.querySelectorAll('button'))
              .find(function(x){ return (x.textContent || '').trim() === '新会话'; });
            if (b) { b.click(); tries = 0; setTimeout(fill, 800); log('new-session'); return 'new-session'; }
            if (tries < 4) { tries++; setTimeout(start, 500); return 'waiting-session'; }
            tries = 0;
            return fill();
          }
          return start();
        })()
        """
        if dshPageReady {
            NotificationCenter.default.post(name: .idshEval, object: js)
        } else {
            pendingJS = js
        }
        ShareInbox.markDelivered(batch.id)
        pendingShareBatchID = nil
        shareNotice = "已放入 /workspace/inbox/\(batch.id) 并预填消息"
    }

    // MARK: - DSH update

    func refreshDSHVersion() {
        guard let root = rootURL else { return }
        let pkg = root.appendingPathComponent(
            "data/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json"
        )
        if let data = try? Data(contentsOf: pkg),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = obj["version"] as? String {
            dshVersion = version
        }
    }

    func checkDSHUpdate() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateStatus = "查询 npm registry…"
        refreshDSHVersion()
        Task {
            defer { checkingUpdate = false }
            do {
                let url = URL(string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = obj["version"] as? String else {
                    updateStatus = "registry 响应无法解析"
                    return
                }
                await MainActor.run {
                    latestDSHVersion = version
                    updateStatus = version == dshVersion
                        ? "已是最新（\(version)）"
                        : "可更新：\(dshVersion) → \(version)"
                }
            } catch {
                updateStatus = "检查失败：\(error.localizedDescription)"
            }
        }
    }

    func installDSHUpdate() {
        guard status == .ready else {
            updateStatus = "DSH 未就绪，稍后再试"
            return
        }
        updateStatus = "正在安装更新…"
        DispatchQueue.main.async {
            _ = ISHShellExecutor.executeCommand(
                "/usr/local/bin/dsh-update",
                lineCallback: { [weak self] line, _ in
                    Task { @MainActor in self?.updateStatus = String(line.prefix(120)) }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        if result.exitCode == 0 {
                            self.updateStatus = "更新完成，重启 DSH"
                            self.refreshDSHVersion()
                            self.restartDSH()
                        } else {
                            self.updateStatus = "更新失败，exit=\(result.exitCode)"
                        }
                    }
                }
            )
        }
    }

    func resetRootfs() {
        detail = "rootfs 重置尚未在 App 内开放；请删除 App 后重装。"
    }

    func exportDiagnostics() {
        let text = """
        idsh diagnostics
        status: \(status.rawValue)
        detail: \(detail)
        rootfs: \(rootfsPath)
        port: \(port)
        server: \(serverURL?.absoluteString ?? "nil")
        """
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idsh-diagnostics.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        detail = "诊断已写入 \(url.lastPathComponent)"
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if audioKeepAlive { BackgroundKeeper.shared.startAudio() }
            if bootInProgress && backgroundBoot {
                backgroundBootArmed = true
                BackgroundKeeper.shared.beginBackgroundExecution()
                BackgroundKeeper.shared.submitContinued(
                    title: "idsh 正在准备",
                    subtitle: detail,
                    progress: progress
                )
            }
            // Do not throttle during boot: iOS already backgrounds us, and
            // halving the interpreter's duty cycle can triple startup time.
            // Once DSH is up, a 55% duty cycle keeps the event loop responsive
            // without looking like a runaway CPU consumer.
            if status == .ready {
                ISHKernel.shared.enableCPUThrottle(withDutyCycle: 0.55)
            } else {
                ISHKernel.shared.disableCPUThrottle()
            }
        case .inactive:
            if audioKeepAlive { BackgroundKeeper.shared.startAudio() }
            if bootInProgress && backgroundBoot {
                // `inactive` still counts as foreground for the scheduler and
                // is the last reliable moment to submit the request.
                backgroundBootArmed = true
                BackgroundKeeper.shared.beginBackgroundExecution()
                BackgroundKeeper.shared.submitContinued(
                    title: "idsh 正在准备",
                    subtitle: detail,
                    progress: progress
                )
            }
        case .active:
            ISHKernel.shared.disableCPUThrottle()
            if audioKeepAlive { BackgroundKeeper.shared.startAudio() }
            else { BackgroundKeeper.shared.stopAudio() }
            BackgroundKeeper.shared.endBackgroundExecution()
            if pendingAutoEnter && serverURL != nil {
                pendingAutoEnter = false
                showDSH = true
            }
            if bootInProgress && backgroundBootArmed {
                BackgroundKeeper.shared.submitContinued(
                    title: "idsh 正在准备",
                    subtitle: detail,
                    progress: progress
                )
            }
        default:
            break
        }
    }
}
