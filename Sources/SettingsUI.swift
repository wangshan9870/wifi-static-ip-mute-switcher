import AppKit
import CoreLocation
import ServiceManagement

private enum UIStyle {
    static let ink = NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.22, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.39, green: 0.47, blue: 0.52, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.03, green: 0.49, blue: 0.57, alpha: 1)
    static let line = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.93, alpha: 1)
    static let paper = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
}

private class Surface: NSView {
    override var isFlipped: Bool { true }
    init(_ frame: NSRect, color: NSColor, radius: CGFloat = 0, border: Bool = false) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
        if border { layer?.borderWidth = 1; layer?.borderColor = UIStyle.line.cgColor }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// Created only while the settings window is open. All actions use the same
// handlers as the menu bar; this view owns no polling or network operations.
final class SettingsUI: NSView {
    override var isFlipped: Bool { true }
    private weak var app: AppDelegate?
    private var pages: [NSView] = []
    private var navigation: [NSButton] = []
    let ssidField = NSTextField(string: "")
    let ipField = NSTextField(string: "")
    private let modeTitle = NSTextField(labelWithString: "")
    private let modeDetail = NSTextField(wrappingLabelWithString: "")
    private let modeBadge = NSTextField(labelWithString: "")
    private let modeIcon = NSImageView()
    private let networkName = NSTextField(labelWithString: "")
    private let networkHint = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private let addressHint = NSTextField(labelWithString: "")
    private let speaker = NSTextField(labelWithString: "")
    private let speakerDetail = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let locationState = NSTextField(labelWithString: "")
    private let helperState = NSTextField(labelWithString: "")
    private let loginState = NSTextField(labelWithString: "")
    private let automatic = NSSwitch()
    private let protection = NSSwitch()
    private let login = NSSwitch()
    private var operationButtons: [NSButton] = []
    private var locationButton: NSButton!
    private var helperButton: NSButton!

    init(app: AppDelegate) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        wantsLayer = true
        layer?.backgroundColor = UIStyle.paper.cgColor
        buildSidebar()
        for _ in 0..<3 {
            let page = Surface(NSRect(x: 210, y: 0, width: 690, height: 650), color: UIStyle.paper)
            addSubview(page); pages.append(page)
        }
        buildOverview(pages[0], app)
        buildNetwork(pages[1], app)
        buildPermissions(pages[2], app)
        ssidField.stringValue = app.settings.ssid
        ipField.stringValue = app.settings.ip
        selectPage(app.settingsValid ? 0 : 1)
        update(app)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    private func text(_ value: String, in view: NSView, _ frame: NSRect,
                      size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = UIStyle.ink) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color; field.maximumNumberOfLines = 0
        view.addSubview(field)
        return field
    }
    private func dynamic(_ field: NSTextField, in view: NSView, _ frame: NSRect,
                         size: CGFloat = 13, weight: NSFont.Weight = .regular,
                         color: NSColor = UIStyle.ink) {
        field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color; field.lineBreakMode = .byTruncatingTail
        view.addSubview(field)
    }
    private func symbol(_ name: String, in view: NSView, _ frame: NSRect, size: CGFloat = 20) -> NSImageView {
        let image = NSImageView(frame: frame)
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        image.contentTintColor = UIStyle.accent
        view.addSubview(image); return image
    }
    @discardableResult
    private func button(_ title: String, in view: NSView, _ frame: NSRect,
                        target: AnyObject, action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.frame = frame; button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: primary ? .medium : .regular)
        if primary { button.bezelColor = UIStyle.accent; button.contentTintColor = .white }
        view.addSubview(button); return button
    }
    private func divider(in view: NSView, y: CGFloat, x: CGFloat = 0, width: CGFloat = 618) {
        view.addSubview(Surface(NSRect(x: x, y: y, width: width, height: 1), color: UIStyle.line))
    }
    private func heading(_ title: String, subtitle: String, in view: NSView) {
        text(title, in: view, NSRect(x: 36, y: 32, width: 460, height: 34), size: 25, weight: .semibold)
        text(subtitle, in: view, NSRect(x: 36, y: 75, width: 520, height: 22), color: UIStyle.muted)
    }
    private func toggleRow(in view: NSView, y: CGFloat, title: String, detail: String,
                           control: NSSwitch, app: AppDelegate, action: Selector) {
        text(title, in: view, NSRect(x: 20, y: y + 17, width: 490, height: 20), weight: .medium)
        text(detail, in: view, NSRect(x: 20, y: y + 44, width: 500, height: 24), size: 11, color: UIStyle.muted)
        control.frame = NSRect(x: 552, y: y + 27, width: 42, height: 24)
        control.target = app; control.action = action
        control.setAccessibilityLabel(title)
        view.addSubview(control)
    }
    private func buildSidebar() {
        let side = Surface(NSRect(x: 0, y: 0, width: 210, height: 650),
                           color: NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.95, alpha: 1))
        addSubview(side)
        side.addSubview(Surface(NSRect(x: 209, y: 0, width: 1, height: 650), color: UIStyle.line))
        let icon = NSImageView(frame: NSRect(x: 24, y: 30, width: 42, height: 42))
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        side.addSubview(icon)
        text("回家，安心外放", in: side, NSRect(x: 76, y: 29, width: 126, height: 24), size: 14, weight: .semibold)
        text("Wi-Fi 与声音自动切换", in: side, NSRect(x: 76, y: 57, width: 122, height: 32), size: 10, color: UIStyle.muted)
        for (index, entry) in [("当前状态", "wifi"), ("家庭网络", "slider.horizontal.3"), ("权限与启动", "checkmark.shield")].enumerated() {
            let nav = NSButton(title: "  " + entry.0, target: self, action: #selector(navigate(_:)))
            nav.tag = index; nav.frame = NSRect(x: 16, y: 114 + index * 49, width: 178, height: 40)
            nav.isBordered = false; nav.alignment = .left; nav.imagePosition = .imageLeading
            nav.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            nav.font = .systemFont(ofSize: 13, weight: .medium)
            nav.wantsLayer = true; nav.layer?.cornerRadius = 7
            side.addSubview(nav); navigation.append(nav)
        }
        text("● 菜单栏后台运行", in: side, NSRect(x: 26, y: 550, width: 172, height: 22), size: 11, color: UIStyle.accent)
        text("关闭窗口后仍会自动检查\n从菜单栏随时打开", in: side, NSRect(x: 26, y: 577, width: 169, height: 45), size: 11, color: UIStyle.muted)
    }
    @objc private func navigate(_ sender: NSButton) { selectPage(sender.tag) }
    func selectPage(_ index: Int) {
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        for (i, nav) in navigation.enumerated() {
            nav.layer?.backgroundColor = (i == index ? NSColor.white : .clear).cgColor
            nav.contentTintColor = i == index ? UIStyle.accent : UIStyle.muted
            nav.setAccessibilityValue(i == index ? "已选择" : "")
        }
        window?.makeFirstResponder(navigation[index])
    }
    private func buildOverview(_ page: NSView, _ app: AppDelegate) {
        heading("当前状态", subtitle: "从家到办公室，自动照顾网络与声音。", in: page)
        operationButtons.append(button("立即检查", in: page, NSRect(x: 562, y: 38, width: 100, height: 32), target: app, action: #selector(AppDelegate.checkNow)))
        let hero = Surface(NSRect(x: 36, y: 117, width: 618, height: 116),
                           color: NSColor(calibratedRed: 0.89, green: 0.96, blue: 0.96, alpha: 1), radius: 12, border: true)
        page.addSubview(hero)
        let tile = Surface(NSRect(x: 24, y: 27, width: 60, height: 60), color: .white, radius: 17)
        hero.addSubview(tile)
        modeIcon.frame = NSRect(x: 13, y: 13, width: 34, height: 34)
        modeIcon.contentTintColor = UIStyle.accent; tile.addSubview(modeIcon)
        dynamic(modeTitle, in: hero, NSRect(x: 104, y: 24, width: 380, height: 31), size: 22, weight: .semibold)
        dynamic(modeDetail, in: hero, NSRect(x: 104, y: 64, width: 488, height: 38), size: 12, color: UIStyle.muted)
        dynamic(modeBadge, in: page, NSRect(x: 36, y: 245, width: 600, height: 21), size: 11, color: UIStyle.accent)
        let fields = [(networkName, networkHint, "当前 Wi-Fi"), (address, addressHint, "IPv4 地址"), (speaker, nil, "内置扬声器")]
        for (i, entry) in fields.enumerated() {
            let x = CGFloat(36 + i * 210)
            text(entry.2, in: page, NSRect(x: x, y: 280, width: 190, height: 18), size: 11, color: UIStyle.muted)
            dynamic(entry.0, in: page, NSRect(x: x, y: 308, width: 190, height: 22), size: 14, weight: .medium)
            if let hint = entry.1 { dynamic(hint, in: page, NSRect(x: x, y: 338, width: 190, height: 19), size: 11, color: UIStyle.muted) }
            else { text("耳机与外接音频不受影响", in: page, NSRect(x: x, y: 338, width: 195, height: 20), size: 10, color: UIStyle.muted) }
        }
        divider(in: page, y: 375, x: 36)
        let group = Surface(NSRect(x: 36, y: 394, width: 618, height: 156), color: .white, radius: 10, border: true)
        page.addSubview(group)
        toggleRow(in: group, y: 0, title: "自动切换 IP", detail: "在家使用固定 IP，其他网络恢复自动 DHCP。", control: automatic, app: app, action: #selector(AppDelegate.toggleAutomatic))
        divider(in: group, y: 78)
        toggleRow(in: group, y: 78, title: "离家静音保护", detail: "外出或无法识别网络时静音，确认回家后恢复声音。", control: protection, app: app, action: #selector(AppDelegate.toggleSpeakerProtection))
        dynamic(speakerDetail, in: page, NSRect(x: 36, y: 565, width: 618, height: 25), size: 11, color: UIStyle.muted)
        operationButtons.append(button("恢复 DHCP 并暂停自动切换", in: page, NSRect(x: 30, y: 601, width: 224, height: 30), target: app, action: #selector(AppDelegate.restore)))
    }
    private func buildNetwork(_ page: NSView, _ app: AppDelegate) {
        heading("家庭网络", subtitle: "告诉应用，哪一个 Wi-Fi 是你的家。", in: page)
        let group = Surface(NSRect(x: 36, y: 117, width: 618, height: 279), color: .white, radius: 10, border: true)
        page.addSubview(group)
        text("家庭 Wi-Fi 名称", in: group, NSRect(x: 20, y: 21, width: 570, height: 22), weight: .medium)
        ssidField.frame = NSRect(x: 20, y: 57, width: 411, height: 32)
        ssidField.placeholderString = "例如：我的家"; ssidField.setAccessibilityLabel("家庭 Wi-Fi 名称")
        group.addSubview(ssidField)
        button("使用当前 Wi-Fi", in: group, NSRect(x: 444, y: 55, width: 154, height: 36), target: app, action: #selector(AppDelegate.useCurrentWiFi))
        text("按网络名称精确匹配，保留大小写和空格。", in: group, NSRect(x: 20, y: 103, width: 578, height: 23), size: 11, color: UIStyle.muted)
        divider(in: group, y: 139)
        text("家庭固定 IPv4 地址", in: group, NSRect(x: 20, y: 160, width: 570, height: 22), weight: .medium)
        ipField.frame = NSRect(x: 20, y: 196, width: 578, height: 32)
        ipField.placeholderString = "例如：192.168.50.42"; ipField.setAccessibilityLabel("家庭固定 IPv4 地址")
        group.addSubview(ipField)
        text("请在家庭路由器的网段中选择地址，并预留或排除该地址。", in: group, NSRect(x: 20, y: 240, width: 578, height: 25), size: 11, color: UIStyle.muted)
        dynamic(feedback, in: page, NSRect(x: 36, y: 413, width: 618, height: 34), size: 12)
        text("修改固定 IP 时需要管理员授权。", in: page, NSRect(x: 36, y: 465, width: 350, height: 25), size: 11, color: UIStyle.muted)
        operationButtons.append(button("保存家庭网络", in: page, NSRect(x: 513, y: 455, width: 149, height: 36), target: app, action: #selector(AppDelegate.saveSettings), primary: true))
        divider(in: page, y: 520, x: 36)
        text("为什么需要固定 IP？", in: page, NSRect(x: 36, y: 544, width: 600, height: 24), weight: .medium)
        text("固定地址让家里的设备能稳定访问这台 Mac。应用使用「DHCP 手动地址」，由路由器继续提供网关信息；离开家后恢复自动获取地址。", in: page, NSRect(x: 36, y: 579, width: 618, height: 56), size: 12, color: UIStyle.muted)
    }
    private func buildPermissions(_ page: NSView, _ app: AppDelegate) {
        heading("权限与启动", subtitle: "完成一次设置，之后在菜单栏自动工作。", in: page)
        let group = Surface(NSRect(x: 36, y: 117, width: 618, height: 309), color: .white, radius: 10, border: true)
        page.addSubview(group)
        for (index, entry) in [("wifi", "识别 Wi-Fi 名称", "需要定位权限，仅用于读取当前网络名。"), ("checkmark.shield", "网络助手", "经管理员授权后，才能切换固定 IP 与 DHCP。")].enumerated() {
            let y = CGFloat(index * 106)
            _ = symbol(entry.0, in: group, NSRect(x: 20, y: y + 28, width: 32, height: 32))
            text(entry.1, in: group, NSRect(x: 68, y: y + 17, width: 378, height: 23), weight: .medium)
            text(entry.2, in: group, NSRect(x: 68, y: y + 44, width: 388, height: 22), size: 11, color: UIStyle.muted)
            divider(in: group, y: y + 105)
        }
        dynamic(locationState, in: group, NSRect(x: 68, y: 73, width: 450, height: 19), size: 11, color: UIStyle.accent)
        dynamic(helperState, in: group, NSRect(x: 68, y: 179, width: 450, height: 19), size: 11, color: UIStyle.accent)
        locationButton = button("允许识别", in: group, NSRect(x: 491, y: 26, width: 108, height: 32), target: app, action: #selector(AppDelegate.authorizeLocation))
        helperButton = button("安装助手", in: group, NSRect(x: 491, y: 132, width: 108, height: 32), target: app, action: #selector(AppDelegate.installHelper))
        operationButtons.append(helperButton)
        toggleRow(in: group, y: 212, title: "登录时启动", detail: "登录 Mac 后，自动在菜单栏运行。", control: login, app: app, action: #selector(AppDelegate.toggleLogin))
        dynamic(loginState, in: page, NSRect(x: 36, y: 442, width: 618, height: 23), size: 11, color: UIStyle.muted)
        button("系统定位权限", in: page, NSRect(x: 29, y: 475, width: 140, height: 32), target: app, action: #selector(AppDelegate.openPrivacy))
        button("系统登录项设置", in: page, NSRect(x: 174, y: 475, width: 150, height: 32), target: app, action: #selector(AppDelegate.openLoginSettings))
        text("你的隐私", in: page, NSRect(x: 36, y: 544, width: 600, height: 24), weight: .medium)
        text("不采集或保存位置坐标，不保存管理员密码。\n仅管理 Wi-Fi 的 IPv4 配置与内置扬声器静音状态。", in: page, NSRect(x: 36, y: 579, width: 618, height: 55), size: 12, color: UIStyle.muted)
    }
    func showFeedback(_ value: String, error: Bool = false) {
        feedback.stringValue = value
        feedback.textColor = error ? .systemRed : UIStyle.accent
        selectPage(1)
    }
    func update(_ app: AppDelegate) {
        let ssid = app.currentSSID
        let unknown = ssid == "未知" || ssid == "未连接或尚未允许识别"
        let home = app.settingsValid && !unknown && ssid == app.settings.ssid
        modeTitle.stringValue = !app.settingsValid ? "先设置你的家庭网络" : unknown ? "暂时无法识别当前网络" : home ? "已连接家庭网络" : "已连接外出网络"
        modeDetail.stringValue = app.status
        modeIcon.image = NSImage(systemSymbolName: home ? "house" : unknown ? "wifi.slash" : "checkmark.shield", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
        modeBadge.stringValue = app.enabled ? "IP 自动切换已开启" : "IP 自动切换已暂停"
        networkName.stringValue = unknown ? "未识别" : ssid
        networkHint.stringValue = unknown ? "断网或尚未允许识别" : home ? "与家庭网络名称一致" : "非家庭网络"
        address.stringValue = app.currentIP
        addressHint.stringValue = app.config.hasPrefix("DHCP Configuration") ? "自动 DHCP" : app.config.hasPrefix("Manually Using DHCP Router Configuration") ? "DHCP 手动地址" : "等待确认网络配置"
        speakerDetail.stringValue = app.speakerStatus
        if app.speakerStatus.contains("未确认在家 · 已静音") { speaker.stringValue = "已静音" }
        else if app.speakerStatus.contains("在家 ·") { speaker.stringValue = "声音由你控制" }
        else if !app.speakerProtection { speaker.stringValue = "保护已关闭" }
        else { speaker.stringValue = "等待确认" }
        automatic.state = app.enabled ? .on : .off
        protection.state = app.speakerProtection ? .on : .off
        automatic.isEnabled = !app.busy
        for button in operationButtons { button.isEnabled = !app.busy }
        let authorized = app.location.authorizationStatus == .authorizedAlways
        locationState.stringValue = !CLLocationManager.locationServicesEnabled() ? "系统定位服务已关闭" : authorized ? "已允许识别网络名称" : app.location.authorizationStatus == .denied || app.location.authorizationStatus == .restricted ? "未允许，请在系统定位权限中开启" : "尚未授权"
        locationButton.title = authorized ? "已允许" : "允许识别"
        locationButton.isEnabled = !authorized
        let configured = app.helperInstalled && app.helperConfigured
        helperState.stringValue = configured ? "已安装，家庭地址已同步" : app.helperInstalled ? "家庭地址待同步，请重新安装助手" : "尚未安装网络助手"
        helperButton.title = configured ? "已安装" : "安装助手"
        helperButton.isEnabled = !app.busy && !configured
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginState.stringValue = SMAppService.mainApp.status == .requiresApproval ? "请在系统登录项中允许此应用后台运行。" : SMAppService.mainApp.status == .enabled ? "已开启，登录 Mac 后会在菜单栏运行。" : "已关闭，需要时请手动打开应用。"
    }
}
