import AppKit
import ServiceManagement

let helperPath = "/Library/PrivilegedHelperTools/cn.wangshan.home-ip"
let helperConfigPath = "/Library/PrivilegedHelperTools/cn.wangshan.home-ip.conf"
func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    return autoreleasepool {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path); task.arguments = arguments
        task.standardOutput = pipe; task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var item: NSStatusItem!
    var speakerPolicy = SpeakerTransitionPolicy()
    var settings = HomeSettings(
        router: UserDefaults.standard.string(forKey: "homeRouter") ?? HomeSettings.defaultRouter,
        ip: UserDefaults.standard.string(forKey: "homeIP") ?? HomeSettings.defaultIP)
    var routerField: NSTextField?
    var ipField: NSTextField?
    var speakerProtection = UserDefaults.standard.object(forKey: "muteSpeakersAway") as? Bool ?? true
    var speakerStatus = "扬声器保护：正在检查…"
    let queue = DispatchQueue(label: "home-ip.network", autoreleaseFrequency: .workItem)
    private var displayedMenuState: [String] = []
    var policy = NetworkPolicy()
    var busy = false
    var enabled = UserDefaults.standard.bool(forKey: "automatic")
    var status = "正在读取网络…"
    var observation: GatewayObservation?
    var currentIP = "—"
    var config = ""
    var failureUntil = Date.distantPast
    var window: NSWindow?
    var settingsUI: SettingsUI?
    var wakeObserver: NSObjectProtocol?
    private var networkMonitor: NetworkChangeMonitor?
    private var speakerMonitor: SpeakerChangeMonitor?
    private var evaluating = false
    private var evaluateAgain = false
    private var evaluationTimer: Timer?
    private var speakerRetryTimer: Timer?
    private var safetyTimer: Timer?
    private var readRetries = 0
    var updateState = UpdateState.idle
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 24 * 3600
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    // Two reads this far apart confirm a network before acting on it.
    private let confirmDelay: TimeInterval = 2

    var atHome: Bool { settingsValid && observation?.mac == settings.router }
    var networkDescription: String {
        switch observation {
        case nil: return "正在读取…"
        case .disconnected?: return "未连接 Wi-Fi"
        case let .unresolved(router)?: return "正在识别路由器 \(router)"
        case let .network(_, router)?: return atHome ? "家庭网络 · 路由器 \(router)" : "其他网络 · 路由器 \(router)"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple instances changing the same network service.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 {
            NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Wi-Fi 固定 IP 与静音切换器")
        rebuildMenu()
        // Network and audio changes arrive as notifications; nothing polls.
        let monitor = NetworkChangeMonitor { [weak self] in self?.scheduleEvaluation(after: 1) }
        let subscribed = monitor.start()
        networkMonitor = monitor
        speakerMonitor = SpeakerChangeMonitor { [weak self] in self?.enforceSpeakers() }
        speakerMonitor?.start()
        // Low-frequency safety net in case a notification is ever missed; a
        // shorter interval only if the system refused the subscription.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: subscribed ? 300 : 30, repeats: true) { [weak self] _ in self?.evaluate() }
        safetyTimer?.tolerance = 30
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.policy = NetworkPolicy(); self?.speakerMonitor?.start(); self?.evaluate()
        }
        evaluate()
        // Update check: shortly after launch, then at most once a day. The
        // hourly timer only compares a date; it makes no request by itself.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkForUpdatesIfDue() }
        updateTimer?.tolerance = 600
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkForUpdatesIfDue() }
        if !UserDefaults.standard.bool(forKey: "introduced") { showSetup() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return true }
    var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }
    var settingsValid: Bool { HomeSettings.validRouter(settings.router) && HomeSettings.validIP(settings.ip) }
    var helperConfigured: Bool {
        if let installedIP = try? String(contentsOfFile: helperConfigPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            return installedIP == settings.ip
        }
        return false
    }
    func menuItem(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self; return result
    }
    func rebuildMenu() {
        let loginEnabled = SMAppService.mainApp.status == .enabled
        let state = [networkDescription, currentIP, status, speakerStatus, String(enabled),
                     String(speakerProtection), String(busy), String(loginEnabled), String(describing: updateState)]
        settingsUI?.update(self)
        guard state != displayedMenuState else { return }
        displayedMenuState = state
        // No router address or network history is written to disk.
        let known = observation?.mac != nil
        let diagnostic = "enabled=\(enabled) networkKnown=\(known) atHome=\(atHome) status=\(status) speakerProtection=\(speakerProtection) speakerStatus=\(speakerStatus)"
        try? diagnostic.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/cn.wangshan.home-ip-status.txt"), atomically: true, encoding: .utf8)
        let menu = NSMenu()
        if case let .available(release) = updateState {
            menu.addItem(menuItem("发现新版本 v\(release.version)，前往下载…", #selector(openUpdatePage)))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("网络：\(networkDescription)"))
        menu.addItem(menuItem("当前 IP：\(currentIP)"))
        menu.addItem(menuItem(status))
        menu.addItem(menuItem(speakerStatus))
        let protect = menuItem("离家自动静音内置扬声器", #selector(toggleSpeakerProtection))
        protect.state = speakerProtection ? .on : .off
        menu.addItem(protect)
        menu.addItem(.separator())
        let automatic = menuItem("自动切换", #selector(toggleAutomatic))
        automatic.state = enabled ? .on : .off; automatic.isEnabled = !busy
        menu.addItem(automatic)
        menu.addItem(menuItem("恢复 DHCP 并暂停", #selector(restore)))
        menu.addItem(menuItem("立即检查", #selector(checkNow)))
        let login = menuItem("登录时启动", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(menuItem("设置与使用说明…", #selector(showSetup)))
        menu.addItem(menuItem("检查更新…", #selector(checkForUpdates)))
        menu.addItem(menuItem("退出（恢复 DHCP）", #selector(quitSafely)))
        item.menu = menu
        item.button?.title = enabled ? "" : " 暂停"
    }
    func checkForUpdatesIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= updateInterval else { return }
        fetchUpdate(manual: false)
    }
    @objc func checkForUpdates() { fetchUpdate(manual: true) }
    private func fetchUpdate(manual: Bool) {
        guard updateState != .checking else { return }
        let previous = updateState
        updateState = .checking; rebuildMenu()
        UpdateChecker.fetchLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(release):
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                self.updateState = AppVersion.isNewer(release.version, than: self.currentVersion) ? .available(release) : .upToDate
            case let .failure(error):
                // A silent background failure keeps the last known result.
                self.updateState = manual ? .failed(error.localizedDescription) : previous
            }
            self.rebuildMenu()
            self.relieveMemory()
            guard manual else { return }
            if case let .available(release) = self.updateState {
                self.offerUpdate(release)
            } else if case let .failed(message) = self.updateState, self.window == nil {
                self.alert("检查更新失败", message)
            } else if self.updateState == .upToDate, self.window == nil {
                self.alert("已是最新版本", "当前版本 \(self.currentVersion)。")
            }
        }
    }
    private func offerUpdate(_ release: ReleaseInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(release.version)"
        alert.informativeText = "当前版本 \(currentVersion)。前往 GitHub 下载 DMG，退出本应用后替换安装即可，设置会保留。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { openUpdatePage() }
    }
    @objc func openUpdatePage() {
        let page: String
        if case let .available(release) = updateState { page = release.page } else { page = ReleaseInfo.releasesPage + "/latest" }
        if let url = URL(string: page) { NSWorkspace.shared.open(url) }
    }
    /// Returns freed malloc pages to the system after transient work (closing
    /// the settings window, a network request) so the idle footprint drops.
    func relieveMemory() {
        // Delay so autoreleased views from the closing window are gone first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = malloc_zone_pressure_relief(nil, 0) }
    }
    @objc func checkNow() { failureUntil = .distantPast; evaluate() }
    @objc func toggleSpeakerProtection() {
        speakerProtection.toggle()
        UserDefaults.standard.set(speakerProtection, forKey: "muteSpeakersAway")
        evaluate()
    }

    /// Coalesces bursts of notifications; keeps the earliest pending deadline.
    func scheduleEvaluation(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(0, delay))
        if let timer = evaluationTimer, timer.isValid, timer.fireDate <= deadline { return }
        evaluationTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.evaluationTimer = nil; self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    /// Reads the gateway and Wi-Fi configuration off the main thread, then
    /// updates IP and speaker policy. Triggered by events, never by polling.
    func evaluate() {
        evaluationTimer?.invalidate(); evaluationTimer = nil
        guard settingsValid else {
            status = "请先绑定家庭网络并设置固定 IP"; enforceSpeakers(); rebuildMenu(); return
        }
        guard !evaluating, !busy else { evaluateAgain = true; return }
        evaluating = true
        queue.async {
            let observed = WiFiGateway.observe()
            let info = run("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
            DispatchQueue.main.async { self.evaluating = false; self.handle(observed, info) }
        }
    }

    private func handle(_ observed: GatewayObservation, _ info: (Int32, String)) {
        guard settingsValid else { evaluate(); return }
        observation = observed
        config = info.1
        currentIP = ipAddress(in: info.1)
        let network = observed.mac
        let desired = policy.observe(network: network, homeNetwork: settings.router, enabled: enabled)
        _ = speakerPolicy.desiredMute(network: network, homeNetwork: settings.router, enabled: speakerProtection)
        enforceSpeakers()
        var next: TimeInterval?
        // An unanswered router or unreadable configuration has no event to
        // wait for, so retry with backoff (3 s doubling to 60 s).
        if observed.router != nil && network == nil || info.0 != 0 {
            next = min(3 * pow(2, Double(readRetries)), 60); readRetries += 1
        } else { readRetries = 0 }
        if info.0 != 0 { status = "读取 Wi-Fi 配置失败" }
        else if !enabled { status = "自动切换已暂停" }
        else if !helperInstalled || !helperConfigured { status = "请在设置中安装网络助手" }
        else if network == nil { status = observed == .disconnected ? "未连接 Wi-Fi，保留当前设置" : "正在识别路由器，保留当前设置" }
        else if Date() < failureUntil { next = failureUntil.timeIntervalSinceNow }
        else if let desired, let network {
            if matches(desired) { status = desired == .home ? "家庭模式 · DHCP 手动地址" : "外出模式 · 自动 DHCP" }
            else { apply(desired, expecting: network); return }
        } else { status = "正在确认网络，稍后自动切换…" }
        if policy.awaitingConfirmation || speakerPolicy.awaitingConfirmation { next = min(next ?? confirmDelay, confirmDelay) }
        rebuildMenu()
        if let next { scheduleEvaluation(after: next) }
        if evaluateAgain { evaluateAgain = false; scheduleEvaluation(after: 0.5) }
    }

    /// Applies the speaker desire for the latest observation. Called after each
    /// network read and on CoreAudio change notifications.
    func enforceSpeakers() {
        guard settingsValid else {
            if speakerStatus != "扬声器保护：请先绑定家庭网络" {
                speakerStatus = "扬声器保护：请先绑定家庭网络"; rebuildMenu()
            }
            return
        }
        let next: String
        var retry = false
        if !speakerProtection { next = "扬声器保护：已关闭" }
        else if let desired = speakerPolicy.currentDesire {
            let result = SpeakerAudio.setInternalSpeakersMuted(desired)
            if !desired && result.success { speakerPolicy.didRestoreHome() }
            // Missing speakers reappear through the device-list notification.
            retry = !result.success && result.status != "扬声器保护：未识别到内置扬声器"
            next = result.status
        } else if speakerStatus == "扬声器保护：在家 · 已取消静音" || speakerStatus == "扬声器保护：在家 · 音量由你控制" {
            next = "扬声器保护：在家 · 音量由你控制"
        } else { next = "扬声器保护：正在确认家庭网络…" }
        speakerRetryTimer?.invalidate(); speakerRetryTimer = nil
        if retry {
            speakerRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.enforceSpeakers() }
        }
        if speakerStatus != next { speakerStatus = next; rebuildMenu() }
    }
    func ipAddress(in info: String) -> String {
        info.components(separatedBy: "\n").first(where: { $0.hasPrefix("IP address: ") })?.replacingOccurrences(of: "IP address: ", with: "") ?? "—"
    }
    func matches(_ mode: IPMode) -> Bool {
        if mode == .dhcp { return config.hasPrefix("DHCP Configuration") }
        return config.hasPrefix("Manually Using DHCP Router Configuration") && currentIP == settings.ip
    }
    /// `expecting` is the network the automatic decision was made for; the
    /// gateway is re-read right before switching and the switch is skipped if
    /// it changed. Manual actions pass nil.
    func apply(_ mode: IPMode, expecting network: String? = nil, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { completion?(false); return }
        guard helperInstalled, mode == .dhcp || helperConfigured else { status = "请先在设置中安装网络助手"; rebuildMenu(); completion?(false); return }
        busy = true; status = "正在切换网络配置…"; rebuildMenu()
        queue.async {
            if let network, WiFiGateway.observe().mac != network {
                DispatchQueue.main.async {
                    self.busy = false; self.policy = NetworkPolicy()
                    self.status = "网络已变化，等待重新确认"; self.rebuildMenu()
                    self.scheduleEvaluation(after: self.confirmDelay); completion?(false)
                }
                return
            }
            let result = run("/usr/bin/sudo", ["-n", helperPath, mode.rawValue])
            let verify = run("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
            DispatchQueue.main.async {
                self.busy = false; self.config = verify.1
                self.currentIP = self.ipAddress(in: verify.1)
                let success = result.0 == 0 && verify.0 == 0 && self.matches(mode)
                if success { self.status = mode == .home ? "家庭模式 · \(self.settings.ip)" : "已恢复自动 DHCP" }
                else {
                    self.failureUntil = Date().addingTimeInterval(60)
                    self.status = result.0 == 73 ? "IP 可能被占用，已停止切换" : "切换未通过验证，请检查网络助手"
                    if completion != nil { self.alert(self.status, result.1.isEmpty ? "配置未达到预期，当前设置未被标记为成功。" : result.1) }
                }
                self.rebuildMenu(); completion?(success)
                if !success { self.scheduleEvaluation(after: 60) }
                if self.evaluateAgain { self.evaluateAgain = false; self.scheduleEvaluation(after: 0.5) }
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "automatic"); policy = NetworkPolicy(); rebuildMenu()
    }
    @objc func toggleAutomatic() {
        if enabled { restore(); return }
        guard settingsValid else { showSetup(); alert("请先完成设置", "绑定家庭网络并填写固定 IP 后再开启自动切换。"); return }
        guard helperInstalled else { showSetup(); settingsUI?.selectPage(2); return }
        setEnabled(true); evaluate()
    }
    @objc func restore() {
        guard !busy else { alert("正在处理网络", "请稍后再试。"); return }
        setEnabled(false); apply(.dhcp)
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("登录启动设置未完成", error.localizedDescription) }
        rebuildMenu()
    }
    @objc func quitSafely() {
        guard !busy else { alert("正在处理网络", "请稍后再退出。"); return }
        if config.hasPrefix("DHCP Configuration") || !helperInstalled { NSApp.terminate(nil); return }
        apply(.dhcp) { success in if success { NSApp.terminate(nil) } }
    }
    func alert(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.runModal()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    /// Fills the router field with the current Wi-Fi gateway's MAC address.
    @objc func useCurrentNetwork() {
        queue.async {
            let observed = WiFiGateway.observe()
            DispatchQueue.main.async {
                self.observation = observed
                guard let mac = observed.mac else {
                    self.alert("暂时无法识别当前网络", observed == .disconnected
                        ? "请先连接家庭 Wi-Fi，再点击「使用当前网络」。"
                        : "已连接 Wi-Fi，但路由器 \(observed.router ?? "") 暂未响应。请稍后重试。")
                    self.rebuildMenu(); return
                }
                self.routerField?.stringValue = mac
                self.rebuildMenu()
            }
        }
    }
    func authorizeHelper(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error.flatMap { ($0[NSAppleScript.errorMessage] as? String) ?? "管理员授权未完成。" }
    }
    @objc func saveSettings() {
        guard let routerField, let ipField else { return }
        guard let router = GatewayParser.normalizeMAC(routerField.stringValue) else {
            settingsUI?.showFeedback("请在家中点击「使用当前网络」，或输入路由器硬件地址，例如 a4:91:b1:0c:22:7e。", error: true)
            return
        }
        routerField.stringValue = router
        let candidate = HomeSettings(router: router, ip: ipField.stringValue)
        guard HomeSettings.validIP(candidate.ip) else {
            settingsUI?.showFeedback("请输入可用的 IPv4 地址，例如 192.168.50.42。", error: true)
            return
        }
        guard !busy else { alert("正在处理网络", "请稍后再保存。"); return }
        if candidate.ip != settings.ip {
            guard let resources = Bundle.main.resourcePath else { return }
            let command = "/bin/bash " + shellQuote(resources + "/install-helper.sh") + " "
                + shellQuote(NSUserName()) + " " + shellQuote(candidate.ip)
            if let error = authorizeHelper(command) {
                alert("固定 IP 尚未保存", error)
                return
            }
            guard (try? String(contentsOfFile: helperConfigPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == candidate.ip else {
                alert("固定 IP 尚未保存", "网络助手的地址与设置不一致，请重试。")
                return
            }
        }
        settings = candidate
        UserDefaults.standard.set(candidate.router, forKey: "homeRouter")
        UserDefaults.standard.set(candidate.ip, forKey: "homeIP")
        policy = NetworkPolicy()
        speakerPolicy = SpeakerTransitionPolicy()
        failureUntil = .distantPast
        evaluate()
        settingsUI?.showFeedback("家庭网络已保存。")
    }
    @objc func installHelper() {
        guard !busy, let resources = Bundle.main.resourcePath else { return }
        guard settingsValid else { alert("请先完成设置", "绑定并保存家庭网络和固定 IP 后再安装网络助手。"); return }
        let command = "/bin/bash " + shellQuote(resources + "/install-helper.sh") + " " + shellQuote(NSUserName()) + " " + shellQuote(settings.ip)
        // Installation is user-initiated; macOS owns the administrator password prompt.
        if let error = authorizeHelper(command) { alert("安装未完成", error) }
        else { alert("网络助手已安装", "接下来在菜单栏勾选自动切换和登录时启动。"); evaluate() }
    }
    @objc func showSetup() {
        UserDefaults.standard.set(true, forKey: "introduced")
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wi-Fi 固定 IP 与静音切换器"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let ui = SettingsUI(app: self)
        window.contentView = ui
        settingsUI = ui
        routerField = ui.routerField
        ipField = ui.ipField
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        routerField = nil
        ipField = nil
        window = nil
        settingsUI = nil
        relieveMemory()
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
