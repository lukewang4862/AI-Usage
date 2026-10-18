import AppKit
import WebKit

// Muse authentication remains in this app's persistent WebKit cookie store.
// Never reads Muse.app's keychain or exports cookies/tokens.
final class MuseBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView!
    private var window: NSWindow?
    private var completion: ((Result<GrokUsage, Error>) -> Void)?
    private var deadline: Timer?
    private var navigationAttempts = 0
    private var navigationTimer: Timer?
    private var loading = false
    private var hasUsage = false
    private var queryStarted = false
    private var readinessTimer: Timer?
    private let discovery = MuseActionDiscovery()
    private var recoveryAttempted = false
    private var recovering = false

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "museUsage")
        config.userContentController.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: config)
        webView.navigationDelegate = self; webView.uiDelegate = self
        prepareWindow()
    }

    func read(completion: @escaping (Result<GrokUsage, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        recoveryAttempted = false
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            self?.readinessTimer?.invalidate()
            self?.hasUsage = false
            self?.finish(.failure(WidgetError.message("Muse 查询超时，请刷新；仍失败可在 Settings 打开 Muse 检查")))
        }
        // Do not interrupt a login that the user is completing.
        if window?.isVisible == true && !hasUsage { navigationAttempts = 0; openUsageWhenReady(); return }
        navigationAttempts = 0
        loading = true; queryStarted = false
        webView.load(URLRequest(url: URL(string: "https://muse.ai/")!, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func prepareWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "AI Usage · Muse 登录"; w.isReleasedWhenClosed = false
            w.contentView = webView; w.center(); window = w
        }
    }

    func showLogin() {
        prepareWindow()
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        if webView.url == nil { webView.load(URLRequest(url: URL(string: "https://muse.ai/")!, cachePolicy: .reloadIgnoringLocalCacheData)) }
        openUsageWhenReady()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        queryStarted = false; readinessTimer?.invalidate()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.webView.url?.host == "muse.ai" else { return }
            self.webView.evaluateJavaScript("document.readyState !== 'loading' && typeof window.__museReadAction === 'function'") { value, _ in
                if value as? Bool == true { timer.invalidate(); self.beginQuery() }
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { beginQuery() }
    private func beginQuery() {
        guard !queryStarted else { return }; queryStarted = true
        loading = false; navigationAttempts = 0
        diagnostic("query", "page ready")
        if webView.url?.host == "muse.ai", let request = UserDefaults.standard.dictionary(forKey: "museReadAction"), let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("void window.__museReadAction(\(json))", completionHandler: nil)
        } else if webView.url?.host == "muse.ai" { recoverReadAction() }
        else { openUsageWhenReady() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false; finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false; finish(.failure(error)) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Normal Meta login links can target a new window. Keep authentication in this WebKit store.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    private func recoverReadAction() {
        guard !recovering, !recoveryAttempted else {
            finish(.failure(WidgetError.message("Muse 额度查询暂时无法恢复，稍后将重试"))); return
        }
        recoveryAttempted = true; recovering = true
        diagnostic("recovery", "discovering named read action from current page modules")
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.discovery.cancel(); self?.recovering = false
            self?.finish(.failure(WidgetError.message("Muse 自动恢复超时，稍后将重试")))
        }
        webView.evaluateJavaScript("[...new Set([...document.scripts].map(x=>x.src).filter(x=>x.startsWith(location.origin+'/_next/static/chunks/')))]") { [weak self] value, error in
            guard let self, self.recovering else { return }
            guard error == nil, let sources = value as? [String], !sources.isEmpty else {
                self.recovering = false; self.finish(.failure(WidgetError.message("Muse 页面尚未就绪，请稍后刷新"))); return
            }
            self.discovery.discover(sources: sources) { [weak self] result in
                guard let self, self.recovering else { return }
                self.recovering = false
                switch result {
                case .failure(let error): self.finish(.failure(error))
                case .success(let action):
                    self.diagnostic("candidate", "found read action; validating live response")
                    // This is only a candidate: persist it only after validated usage arrives.
                    let spec = ["action": action, "body": "[{\"includeAgreement\":true}]"]
                    guard let data = try? JSONSerialization.data(withJSONObject: spec), let json = String(data: data, encoding: .utf8) else { return }
                    self.webView.evaluateJavaScript("void window.__museReadAction(\(json))") { _, error in
                        if let error { self.finish(.failure(error)) }
                    }
                }
            }
        }
    }

    private func openUsageWhenReady() {
        navigationTimer?.invalidate()
        guard webView.url?.host == "muse.ai", !loading else { return }
        navigationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.navigationAttempts += 1
            if self.navigationAttempts > 30 { timer.invalidate(); return }
            self.webView.evaluateJavaScript(Self.openSettingsScript) { value, _ in
                self.diagnostic("settings", value as? String ?? "script error: " + String(describing: value))
                if value as? String == "ready" { timer.invalidate() }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "muse.ai",
              let row = message.body as? [String: Any] else { return }
        if let failure = row["failure"] as? String {
            let status = row["status"] as? Int ?? 0
            diagnostic("requestError", "\(failure), HTTP \(status)")
            if failure == "action", !recoveryAttempted { recoverReadAction(); return }
            let detail: String
            switch failure {
            case "login": detail = "Muse 登录已过期，请在 Settings 中重新登录"
            case "action": detail = "Muse 网页正在更新，自动恢复暂未成功；稍后将重试"
            case "format": detail = "Muse 返回的数据格式已变化，暂时无法读取额度"
            default: detail = "Muse 查询失败（HTTP \(status)），请稍后刷新"
            }
            finish(.failure(WidgetError.message(detail))); return
        }
        guard let used = (row["percentUsed"] as? NSNumber)?.doubleValue,
              used.isFinite, (0...100).contains(used),
              let reset = (row["resetsAt"] as? NSNumber)?.doubleValue, reset > 0 else { return }
        if let request = row["request"] as? [String: String], let action = request["action"], let body = request["body"],
           action.count <= 200, action.allSatisfy({ $0.isHexDigit }), body.count <= 100,
           let bytes = body.data(using: .utf8), let arguments = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
           arguments.count <= 1, arguments.allSatisfy({ Set($0.keys).isSubset(of: ["includeAgreement"]) }) {
            UserDefaults.standard.set(request, forKey: "museReadAction")
        }
        hasUsage = true
        diagnostic("usage", "remaining=\(100-used), reset=\(reset)")
        finish(.success(GrokUsage(remaining: 100 - used, reset: Date(timeIntervalSince1970: reset))))
    }

    private func finish(_ result: Result<GrokUsage, Error>) {
        discovery.cancel(); recovering = false
        readinessTimer?.invalidate(); navigationTimer?.invalidate()
        deadline?.invalidate(); deadline = nil
        let callback = completion; completion = nil; callback?(result)
        if case .success = result { navigationTimer?.invalidate() }
        onUpdate?(result)
    }
    var onUpdate: ((Result<GrokUsage, Error>) -> Void)?

    private func diagnostic(_ stage: String, _ value: String) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.luke.codexusage")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data: [String: Any] = ["stage": stage, "value": value, "host": webView.url?.host ?? "", "time": Date().timeIntervalSince1970]
        if let encoded = try? JSONSerialization.data(withJSONObject: data) { try? encoded.write(to: directory.appendingPathComponent("Muse-status.json"), options: .atomic) }
    }
    func stop() { discovery.cancel(); readinessTimer?.invalidate(); deadline?.invalidate(); navigationTimer?.invalidate(); webView.stopLoading() }

    static let openSettingsScript = #"""
    (() => {
      if(location.hostname !== 'muse.ai') return 'login';
      if(document.querySelector('[role="dialog"] [role="progressbar"]')) return 'ready';
      const promo=[...document.querySelectorAll('[role="dialog"]')].find(e=>/了解 Mac|Muse for Mac/i.test(e.textContent));
      if(promo){const close=promo.querySelector('button[aria-label="关闭"],button[aria-label="Close"]');if(close){close.click();return 'opening'}}
      const menu = [...document.querySelectorAll('[role="menuitem"]')].find(e => /^(设置|Settings)(\s|⌘|$)/i.test(e.textContent.trim()));
      if(menu) { menu.click(); return 'opening settings'; }
      const button = [...document.querySelectorAll('button')].find(e => ['设置','Settings'].includes(e.getAttribute('aria-label')));
      if(button && !document.querySelector('[role="dialog"]')) { button.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerType:'mouse'})); button.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,button:0,pointerType:'mouse'})); button.click(); return 'opening menu'; }
      return 'waiting: '+JSON.stringify([...document.querySelectorAll('button[aria-label]')].map(e=>e.getAttribute('aria-label')).filter(x=>/setting|menu|设置|菜单/i.test(x))); 
    })()
    """#
    static let captureScript = #"""
    (() => {
      if(location.hostname !== 'muse.ai') return;
      const report = (text,request) => {
        let found=false;
        // Next server actions return JSON frames. Parse values, never send raw bodies or authentication to native code.
        for(const line of text.split('\n')) {
          const index=line.indexOf(':'); const candidate=index>=0?line.slice(index+1):line;
          let root;try {root=JSON.parse(candidate)} catch {continue}
          const visit=(v,d=0)=>{
            if(!v||typeof v!=='object'||d>12)return;
            if(v.usage && typeof v.usage.percentUsed==='number' && typeof v.usage.resetsAt==='number') {
              found=true;window.webkit.messageHandlers.museUsage.postMessage({percentUsed:v.usage.percentUsed,resetsAt:v.usage.resetsAt,request}); return;
            }
            for(const x of Object.values(v))visit(x,d+1);
          };visit(root);
        }
        return found;
      };
      const original=window.fetch;
      const failure=(kind,status)=>window.webkit.messageHandlers.museUsage.postMessage({failure:kind,status});
      window.__museReadAction=async spec=>{
        try {
          const query=async request=>{
            const r=await original('/',{method:'POST',credentials:'same-origin',headers:{'Next-Action':request.action,'Content-Type':'text/plain;charset=UTF-8','Accept':'text/x-component'},body:request.body,signal:AbortSignal.timeout(12000)});
            return {r,text:await r.text()};
          };
          let result=await query(spec);
          if(result.r.status===404 && /Server action not found|Failed to find Server Action/i.test(result.text)){
            failure('action',404);return;
          }
          if(result.r.status===401 || result.r.status===403){failure('login',result.r.status);return}
          if(!result.r.ok){failure('http',result.r.status);return}
          if(!report(result.text,spec))failure('format',result.r.status);
        }catch{failure('network',0)}
      };
      window.fetch=async function(...args){
        let candidate;
        try {
          const q=new Request(...args), u=new URL(q.url);
          const action=q.headers.get('Next-Action');
          if(u.origin===location.origin && q.method==='POST' && action) {
            const body=await q.clone().text();
            let a;try{a=JSON.parse(body)}catch{}
            if(body.length<=100 && Array.isArray(a) && a.length<=1 && a.every(x=>x && typeof x==='object' && Object.keys(x).every(k=>k==='includeAgreement')))candidate={action,body};
          }
        }catch{}
        const r=await original.apply(this,args);
        try { const u=new URL(typeof args[0]==='string'?args[0]:args[0].url,location.href);
          if(u.origin===location.origin && r.ok)r.clone().text().then(text=>report(text,candidate)).catch(()=>{});
        }catch{}
        return r;
      };
    })();
    """#
}
