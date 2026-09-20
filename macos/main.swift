import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    private let port = 48_321
    private var window: NSWindow!
    private var webView: WKWebView!
    private var serverProcess: Process?
    private var bonjourService: NetService?
    private var healthTimer: Timer?
    private var healthAttempts = 0
    private lazy var downloadDirectory: URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("My MP3", isDirectory: true)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        createWindow()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        bonjourService?.stop()
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    private func createMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "My MP3 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "My MP3 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.loadHTMLString("""
        <html><body style="margin:0;background:#0a0a09;color:#f7f5ef;font:16px -apple-system;display:grid;place-items:center;height:100vh">앱을 준비하고 있습니다…</body></html>
        """, baseURL: nil)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "My MP3"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 560)
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func startServer() {
        guard let resources = Bundle.main.resourceURL else {
            showFatalError("앱 리소스를 찾을 수 없습니다.")
            return
        }

        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [resources.appendingPathComponent("app.py").path]
        process.currentDirectoryURL = resources
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        guard let tokenURL = Bundle.main.url(forResource: "remote-token", withExtension: "txt"),
              let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            showFatalError("개인 연결 토큰을 읽을 수 없습니다.")
            return
        }
        environment["APP_HOST"] = "0.0.0.0"
        environment["APP_PORT"] = String(port)
        environment["MY_MP3_DOWNLOAD_DIR"] = downloadDirectory.path
        environment["MY_MP3_REMOTE_TOKEN"] = token
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                environment["MY_MP3_FFMPEG"] = path
                break
            }
        }
        process.environment = environment

        do {
            try process.run()
            serverProcess = process
            waitForServer()
        } catch {
            showFatalError("내부 서버를 시작하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func waitForServer() {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.healthAttempts += 1
            if self.healthAttempts > 50 {
                timer.invalidate()
                self.showFatalError("앱 준비 시간이 초과되었습니다.")
                return
            }
            URLSession.shared.dataTask(with: healthURL) { [weak self] _, response, _ in
                guard let self,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }
                DispatchQueue.main.async {
                    timer.invalidate()
                    self.publishBonjourService()
                    self.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/")!))
                }
            }.resume()
        }
    }

    private func publishBonjourService() {
        guard bonjourService == nil else { return }
        let service = NetService(domain: "local.", type: "_mymp3._tcp.", name: "My MP3 Mac", port: Int32(port))
        service.includesPeerToPeer = true
        service.publish()
        bonjourService = service
    }

    private func showFatalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "My MP3를 실행할 수 없습니다"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.host == "127.0.0.1" && url.path.hasPrefix("/downloads/") {
            let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            NSWorkspace.shared.activateFileViewerSelecting([downloadDirectory.appendingPathComponent(filename)])
            decisionHandler(.cancel)
            return
        }
        if let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != "127.0.0.1" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
