import AppKit
import CoreWLAN
import CoreLocation
import ServiceManagement

let helperPath = "/Library/PrivilegedHelperTools/cn.wangshan.home-ip"
let helperConfigPath = "/Library/PrivilegedHelperTools/cn.wangshan.home-ip.conf"
func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
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
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var speakerTimer: Timer?
    var speakerPolicy = SpeakerTransitionPolicy()
    var settings = HomeSettings(
        ssid: UserDefaults.standard.string(forKey: "homeSSID") ?? HomeSettings.defaultSSID,
        ip: UserDefaults.standard.string(forKey: "homeIP") ?? HomeSettings.defaultIP)
    var ssidField: NSTextField?
    var ipField: NSTextField?
    var speakerProtection = UserDefaults.standard.object(forKey: "muteSpeakersAway") as? Bool ?? true
    var speakerStatus = "扬声器保护：正在检查…"
    let location = CLLocationManager()
    let queue = DispatchQueue(label: "home-ip.network")
    var policy = NetworkPolicy()
    var busy = false
    var enabled = UserDefaults.standard.bool(forKey: "automatic")
    var status = "正在读取网络…"
    var currentSSID = "未知"
    var currentIP = "—"
    var config = ""
    var failureUntil = Date.distantPast
    var window: NSWindow?
    var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple timers changing the same network service.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 {
            NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Wi-Fi 固定 IP 与静音切换器")
        location.delegate = self
        rebuildMenu()
        checkSpeakers()
        speakerTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkSpeakers() }
        RunLoop.main.add(speakerTimer!, forMode: .common)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 1
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.policy = NetworkPolicy(); self?.checkSpeakers(); self?.tick()
        }
        tick()
        if !UserDefaults.standard.bool(forKey: "introduced") { showSetup() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return true }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { tick() }
    var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }
    var settingsValid: Bool { HomeSettings.validSSID(settings.ssid) && HomeSettings.validIP(settings.ip) }
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
        window?.title = "Wi-Fi 固定 IP 与静音切换器 · \(currentSSID) · \(status)"
        let diagnostic = "authorization=\(location.authorizationStatus.rawValue) enabled=\(enabled) ssidAvailable=\(CWWiFiClient.shared().interface(withName: "en0")?.ssid() != nil) status=\(status) speakerProtection=\(speakerProtection) speakerStatus=\(speakerStatus)"
        try? diagnostic.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/cn.wangshan.home-ip-status.txt"), atomically: true, encoding: .utf8)
        let menu = NSMenu()
        menu.addItem(menuItem("Wi-Fi：\(currentSSID)"))
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
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(menuItem("设置与使用说明…", #selector(showSetup)))
        menu.addItem(menuItem("退出（恢复 DHCP）", #selector(quitSafely)))
        item.menu = menu
        item.button?.title = enabled ? "" : " 暂停"
    }
    @objc func checkNow() { failureUntil = .distantPast; checkSpeakers(); tick() }
    @objc func toggleSpeakerProtection() {
        speakerProtection.toggle()
        UserDefaults.standard.set(speakerProtection, forKey: "muteSpeakersAway")
        checkSpeakers(); rebuildMenu()
    }
    func checkSpeakers() {
        guard settingsValid else {
            if speakerStatus != "扬声器保护：请先设置家庭网络" {
                speakerStatus = "扬声器保护：请先设置家庭网络"; rebuildMenu()
            }
            return
        }
        let ssid = CWWiFiClient.shared().interface(withName: "en0")?.ssid()
        let desired = speakerPolicy.desiredMute(ssid: ssid, homeSSID: settings.ssid, enabled: speakerProtection)
        let next: String
        if !speakerProtection { next = "扬声器保护：已关闭" }
        else if let desired {
            let result = SpeakerAudio.setInternalSpeakersMuted(desired)
            if !desired && result.success { speakerPolicy.didRestoreHome() }
            next = result.status
        } else if speakerStatus == "扬声器保护：在家 · 已取消静音" || speakerStatus == "扬声器保护：在家 · 音量由你控制" {
            next = "扬声器保护：在家 · 音量由你控制"
        } else { next = "扬声器保护：正在确认家庭 Wi-Fi…" }
        if speakerStatus != next { speakerStatus = next; rebuildMenu() }
    }
    func tick() {
        guard !busy else { return }
        guard settingsValid else {
            status = "请先设置家庭 Wi-Fi 和固定 IP"; rebuildMenu(); return
        }
        let ssid = CWWiFiClient.shared().interface(withName: "en0")?.ssid()
        currentSSID = ssid ?? "未连接或尚未允许识别"
        let desired = policy.observe(ssid: ssid, homeSSID: settings.ssid, enabled: enabled)
        busy = true
        queue.async {
            let result = run("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
            DispatchQueue.main.async {
                self.busy = false; self.config = result.1
                self.currentIP = result.1.components(separatedBy: "\n").first(where: { $0.hasPrefix("IP address: ") })?.replacingOccurrences(of: "IP address: ", with: "") ?? "—"
                guard result.0 == 0 else { self.status = "读取 Wi-Fi 配置失败"; self.rebuildMenu(); return }
                if !self.enabled { self.status = "自动切换已暂停" }
                else if !self.helperInstalled || !self.helperConfigured { self.status = "请在设置中安装网络助手" }
                else if ssid == nil { self.status = "无法识别 Wi-Fi，保留当前设置" }
                else if Date() < self.failureUntil { /* preserve error during backoff */ }
                else if let desired {
                    if self.matches(desired) { self.status = desired == .home ? "家庭模式 · DHCP 手动地址" : "外出模式 · 自动 DHCP" }
                    else if CWWiFiClient.shared().interface(withName: "en0")?.ssid() == ssid { self.apply(desired); return }
                    else { self.policy = NetworkPolicy(); self.status = "Wi-Fi 已变化，等待重新确认" }
                } else { self.status = "正在确认 Wi-Fi，稍后自动切换…" }
                self.rebuildMenu()
            }
        }
    }
    func matches(_ mode: IPMode) -> Bool {
        if mode == .dhcp { return config.hasPrefix("DHCP Configuration") }
        return config.hasPrefix("Manually Using DHCP Router Configuration") && currentIP == settings.ip
    }
    func apply(_ mode: IPMode, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { completion?(false); return }
        guard helperInstalled, mode == .dhcp || helperConfigured else { status = "请先在设置中安装网络助手"; rebuildMenu(); completion?(false); return }
        busy = true; status = "正在切换网络配置…"; rebuildMenu()
        queue.async {
            let result = run("/usr/bin/sudo", ["-n", helperPath, mode.rawValue])
            let verify = run("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"])
            DispatchQueue.main.async {
                self.busy = false; self.config = verify.1
                self.currentIP = verify.1.components(separatedBy: "\n").first(where: { $0.hasPrefix("IP address: ") })?.replacingOccurrences(of: "IP address: ", with: "") ?? "—"
                let success = result.0 == 0 && verify.0 == 0 && self.matches(mode)
                if success { self.status = mode == .home ? "家庭模式 · \(self.settings.ip)" : "已恢复自动 DHCP" }
                else {
                    self.failureUntil = Date().addingTimeInterval(60)
                    self.status = result.0 == 73 ? "IP 可能被占用，已停止切换" : "切换未通过验证，请检查网络助手"
                    if completion != nil { self.alert(self.status, result.1.isEmpty ? "配置未达到预期，当前设置未被标记为成功。" : result.1) }
                }
                self.rebuildMenu(); completion?(success)
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "automatic"); policy = NetworkPolicy(); rebuildMenu()
    }
    @objc func toggleAutomatic() {
        if enabled { restore(); return }
        guard settingsValid else { showSetup(); alert("请先完成设置", "填写家庭 Wi-Fi 和固定 IP 后再开启自动切换。"); return }
        guard helperInstalled else { showSetup(); return }
        location.requestWhenInUseAuthorization()
        setEnabled(true); tick()
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
    @objc func authorizeLocation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.location.requestWhenInUseAuthorization()
        }
    }
    @objc func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    @objc func useCurrentWiFi() {
        guard let ssid = CWWiFiClient.shared().interface(withName: "en0")?.ssid(),
              HomeSettings.validSSID(ssid) else {
            alert("暂时无法识别当前 Wi-Fi", "请确认已连接 Wi-Fi，并在 macOS 定位服务中允许「Wi-Fi 固定 IP 与静音切换器」读取网络名称。授权后再点一次「使用当前 Wi-Fi」。")
            return
        }
        ssidField?.stringValue = ssid
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
        guard let ssidField, let ipField else { return }
        let candidate = HomeSettings(ssid: ssidField.stringValue, ip: ipField.stringValue)
        guard HomeSettings.validSSID(candidate.ssid) else {
            alert("Wi-Fi 名称无效", "请输入实际的 Wi-Fi 名称，最长 32 字节，不能包含控制字符。")
            return
        }
        guard HomeSettings.validIP(candidate.ip) else {
            alert("固定 IP 无效", "请输入可用的 IPv4 地址，例如 192.168.50.42。")
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
        UserDefaults.standard.set(candidate.ssid, forKey: "homeSSID")
        UserDefaults.standard.set(candidate.ip, forKey: "homeIP")
        policy = NetworkPolicy()
        speakerPolicy = SpeakerTransitionPolicy()
        failureUntil = .distantPast
        checkSpeakers(); tick()
        alert("家庭网络设置已保存", "家庭 Wi-Fi：\(candidate.ssid)\n固定 IP：\(candidate.ip)")
    }
    @objc func installHelper() {
        guard !busy, let resources = Bundle.main.resourcePath else { return }
        guard settingsValid else { alert("请先完成设置", "填写并保存家庭 Wi-Fi 和固定 IP 后再安装网络助手。"); return }
        let command = "/bin/bash " + shellQuote(resources + "/install-helper.sh") + " " + shellQuote(NSUserName()) + " " + shellQuote(settings.ip)
        // Installation is user-initiated; macOS owns the administrator password prompt.
        if let error = authorizeHelper(command) { alert("安装未完成", error) }
        else { alert("网络助手已安装", "接下来允许识别 Wi-Fi，然后在菜单栏勾选自动切换和登录时启动。"); tick() }
    }
    @objc func showSetup() {
        UserDefaults.standard.set(true, forKey: "introduced")
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wi-Fi 固定 IP 与静音切换器 · 设置"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)])
        func label(_ text: String, size: CGFloat = 14) {
            let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size); field.preferredMaxLayoutWidth = 504; stack.addArrangedSubview(field)
        }
        func button(_ title: String, _ action: Selector) { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; stack.addArrangedSubview(button) }
        label("回家固定 IP，出门自动获取", size: 23)
        label("家庭 Wi-Fi 使用指定的固定 IP；其他 Wi-Fi 使用自动 DHCP。\n连续两次识别同一网络后切换，间隔 5 秒。")
        func settingField(_ title: String, value: String) -> NSTextField {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
            let name = NSTextField(labelWithString: title); name.setContentHuggingPriority(.required, for: .horizontal)
            let field = NSTextField(string: value); field.frame.size.width = 320
            row.addArrangedSubview(name); row.addArrangedSubview(field); stack.addArrangedSubview(row)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            return field
        }
        ssidField = settingField("家庭 Wi-Fi", value: settings.ssid)
        button("使用当前 Wi-Fi", #selector(useCurrentWiFi))
        ipField = settingField("固定 IP", value: settings.ip)
        button("保存家庭网络设置", #selector(saveSettings))
        label("修改固定 IP 需要 macOS 管理员授权；Wi-Fi 名称可以直接保存。")
        label("离家自动静音内置扬声器：默认开启，每秒检查。断网或无法识别 Wi-Fi 时也静音；耳机和外接音频不受影响。连续两次确认家庭 Wi-Fi 后自动取消静音，之后可手动静音；关闭保护或退出时不改变声音。此开关独立于 IP 自动切换。")
        label("首次安装需要管理员授权。网络助手仅允许本用户执行上述两种固定操作，不保存密码。")
        button("1. 安装网络助手…", #selector(installHelper))
        button("2. 允许识别 Wi-Fi…", #selector(authorizeLocation))
        button("打开系统定位权限设置", #selector(openPrivacy))
        label("3. 在菜单栏开启「自动切换」和「登录时启动」。定位权限仅用于获取 Wi-Fi 名称，不采集或保存坐标。")
        label("固定 IP 应位于家庭路由器的网段，并在路由器地址池中预留或排除。占用检查无法发现所有离线设备。", size: 12)
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
