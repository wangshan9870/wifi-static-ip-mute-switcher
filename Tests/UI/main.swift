import AppKit

func labels(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let app = AppDelegate()
let homeRouter = "a4:91:b1:0c:22:7e"
app.settings = HomeSettings(router: homeRouter, ip: "192.168.50.42")
app.observation = .network(mac: homeRouter, router: "192.168.50.1")
app.currentIP = "192.168.50.42"
app.config = "Manually Using DHCP Router Configuration"
app.status = "家庭模式 · DHCP 手动地址"
app.speakerStatus = "扬声器保护：在家 · 音量由你控制"
weak var releasedUI: SettingsUI?
autoreleasepool {
    let ui = SettingsUI(app: app)
    precondition(labels(ui).contains("已连接家庭网络"))
    precondition(labels(ui).contains("已绑定 · 当前在家"))
    ui.routerField.stringValue = "Unsaved edit"
    app.observation = .network(mac: "02:11:22:33:44:55", router: "10.0.0.1")
    app.speakerStatus = "扬声器保护：未确认在家 · 已静音"
    ui.update(app)
    precondition(labels(ui).contains("已连接外出网络"))
    precondition(labels(ui).contains("已静音"))
    precondition(ui.routerField.stringValue == "Unsaved edit")
    app.observation = .unresolved(router: "10.0.0.1")
    ui.update(app)
    precondition(labels(ui).contains("暂时无法识别当前网络"))
    app.observation = .disconnected
    ui.update(app)
    precondition(labels(ui).contains("未连接 Wi-Fi"))
    app.settings = HomeSettings(router: "", ip: "")
    ui.update(app)
    precondition(labels(ui).contains("先设置你的家庭网络"))
    let window = NSWindow(contentRect: ui.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.delegate = app
    window.contentView = ui
    app.window = window; app.settingsUI = ui
    app.routerField = ui.routerField; app.ipField = ui.ipField
    releasedUI = ui
    window.close()
    precondition(app.window == nil && app.settingsUI == nil && app.routerField == nil && app.ipField == nil)
}
precondition(releasedUI == nil)
print("UI checks passed: home/away/unresolved/disconnected/setup states, unsaved edits, closed-window release")
