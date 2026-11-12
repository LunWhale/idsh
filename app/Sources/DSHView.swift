import SwiftUI
import WebKit

/// Full-screen wrapper around the DSH web UI, plus a floating home button that
/// returns to the launcher without tearing down the guest Linux process.
struct DSHView: View {
    @EnvironmentObject private var model: LauncherModel
    let url: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let url {
                DSHWebContainer(url: url)
                    .ignoresSafeArea()
            } else {
                ProgressView("等待 DSH URL").tint(.white).foregroundStyle(.white)
            }
            Button {
                model.showDSH = false
            } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.2)))
            }
            .padding(.top, 10)
            .padding(.leading, 12)
            .accessibilityLabel("返回启动器")
        }
        .overlay(alignment: .topTrailing) {
            if model.showPerformanceHUD {
                PerformanceHUDView()
                    .padding(.top, 8)
                    .padding(.trailing, 10)
            }
        }
        .statusBarHidden(false)
        .sheet(isPresented: $model.showShareComposer) {
            if let batch = model.pendingShare {
                ShareComposerView(batch: batch).environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showConfigEditor) {
            DSHConfigEditorView().environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .idshOpenConfig)) { _ in
            NSLog("idsh opening config editor")
            // The full-screen DSH cover cannot reliably present a second sheet;
            // return to the launcher (the guest keeps running) and let the
            // root view present the editor.
            model.showDSH = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                model.showConfigEditor = true
            }
        }
    }
}

extension Notification.Name {
    /// Posted with a JS source string; evaluated in the active DSH web view.
    static let idshEval = Notification.Name("idsh.eval")
    /// Posted when the DSH document has finished loading at least once.
    static let idshWebReady = Notification.Name("idsh.web.ready")
    /// Posted with the stringified result of an evaluated snippet.
    static let idshEvalResult = Notification.Name("idsh.eval.result")
    /// Posted when the web UI asks for the native configuration editor.
    static let idshOpenConfig = Notification.Name("idsh.open.config")
}

struct DSHWebContainer: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "idsh")
        controller.add(context.coordinator, name: "idshLog")
        controller.addUserScript(WKUserScript(source: Self.errorBridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.fontScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.configBridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        config.setURLSchemeHandler(FontSchemeHandler(), forURLScheme: "idsh-font")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .black
        context.coordinator.webView = view
        context.coordinator.registerEvalObserver()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Injected JavaScript

    /// Reports page errors and console output back to the app log.
    static let errorBridgeScript = """
    window.addEventListener('error', function(e){ try{window.webkit.messageHandlers.idshLog.postMessage('ERR '+(e.message||e.type)+' @ '+(e.filename||'')+':'+(e.lineno||0));}catch(_){}});
    window.addEventListener('unhandledrejection', function(e){ try{window.webkit.messageHandlers.idshLog.postMessage('REJ '+(e.reason&&(e.reason.stack||e.reason.message)||e.reason));}catch(_){}});
    (function(){['warn','error'].forEach(function(k){var old=console[k];console[k]=function(){try{window.webkit.messageHandlers.idshLog.postMessage('CONSOLE '+k+' '+Array.prototype.slice.call(arguments).map(String).join(' ').slice(0,600));}catch(_){}return old.apply(console,arguments);};});})();
    """

    /// Injects a bundled CJK font under the family names the DSH stylesheet
    /// asks for, so text renders on runtimes without PingFang (simulators).
    static let fontScript = """
    (function(){
      var face="@font-face{font-family:'PingFang SC';src:url('idsh-font://cjk/STHeitiSC-Medium.woff2') format('woff2');font-weight:100 900;font-style:normal;font-display:swap;}@font-face{font-family:'PingFang TC';src:url('idsh-font://cjk/STHeitiSC-Medium.woff2') format('woff2');font-weight:100 900;font-style:normal;font-display:swap;}@font-face{font-family:'Hiragino Sans GB';src:url('idsh-font://cjk/STHeitiSC-Medium.woff2') format('woff2');font-weight:100 900;font-style:normal;font-display:swap;}";
      function add(root){
        if(!root || root.__idshFont) return;
        root.__idshFont=1;
        var s=document.createElement('style');
        s.textContent=face;
        (root.head||root).appendChild(s);
      }
      function scan(root){
        add(root);
        var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (var i = 0; i < all.length; i++) { if (all[i].shadowRoot) add(all[i].shadowRoot); }
      }
      scan(document);
      window.addEventListener('load', function(){ scan(document); });
      setTimeout(function(){ scan(document); }, 1500);
    })();
    """

    /// The desktop build opens the provider config file through a host-owned
    /// operation that the web host does not implement. Intercept that action
    /// and route it to the app's built-in config editor instead of letting the
    /// DSH settings page show "cannot open".
    static let configBridgeScript = """
    (function(){
      var labels = ['打开配置文件','Open configuration file','設定ファイルを開く','Abrir archivo de configuración','Ouvrir le fichier de configuration','Konfigurationsdatei öffnen','Открыть файл конфигурации','Abra o arquivo de configuração'];
      document.addEventListener('click', function(e){
        var el = e.target;
        while (el && el !== document) {
          if (el.tagName === 'BUTTON' || el.getAttribute && el.getAttribute('role') === 'button') break;
          el = el.parentElement;
        }
        if (!el || el === document) return;
        var text = (el.innerText || el.textContent || '').trim();
        var hit = labels.some(function(label){ return text.indexOf(label) !== -1; });
        if (!hit) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        try { window.webkit.messageHandlers.idsh.postMessage('openConfig'); } catch(_) {}
      }, true);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var observer: NSObjectProtocol?

        /// Allows the launcher (or automation) to evaluate JavaScript in the
        /// live DSH page without holding a reference to the web view.
        func registerEvalObserver() {
            observer = NotificationCenter.default.addObserver(forName: .idshEval, object: nil, queue: .main) { [weak self] note in
                guard let js = note.object as? String, let webView = self?.webView else { return }
                webView.evaluateJavaScript(js) { value, error in
                    let text: String
                    if let error {
                        text = "error: \(error.localizedDescription)"
                        NSLog("idsh eval error: \(error.localizedDescription)")
                    } else {
                        text = String(describing: value ?? "nil")
                        NSLog("idsh eval result: \(text)")
                    }
                    NotificationCenter.default.post(name: .idshEvalResult, object: text)
                }
            }
        }

        func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        NSLog("idsh popup blocked (web host has no interactive auth surface): \(navigationAction.request.url?.absoluteString ?? "nil")")
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("idsh webview finished loading")
            NotificationCenter.default.post(name: .idshWebReady, object: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("idsh webview navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("idsh webview provisional failed: \(error.localizedDescription)")
            // The supervisor reports "ready" slightly before the listener
            // accepts connections; retry once the port is actually live.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let url = webView.url else { return }
                webView.load(URLRequest(url: url))
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "idshLog" {
                NSLog("idsh js: \(message.body)")
                return
            }
            guard message.name == "idsh" else { return }
            if let action = message.body as? String, action == "openConfig" {
                NSLog("idsh openConfig requested from web UI")
                NotificationCenter.default.post(name: .idshOpenConfig, object: nil)
            }
        }
    }
}

/// Serves the bundled CJK font over the private `idsh-font://` scheme.
final class FontSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "cjk" else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let name = (url.path as NSString).lastPathComponent
        guard let file = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "woff2"),
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "font/woff2", "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=31536000"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
