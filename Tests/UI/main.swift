import AppKit

func labels(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let app = AppDelegate()
app.settings = HomeSettings(ssid: "Example-Home", ip: "192.168.50.42")
app.currentSSID = "Example-Home"
app.currentIP = "192.168.50.42"
app.config = "Manually Using DHCP Router Configuration"
app.status = "家庭模式 · DHCP 手动地址"
app.speakerStatus = "扬声器保护：在家 · 音量由你控制"
weak var releasedUI: SettingsUI?
autoreleasepool {
    let ui = SettingsUI(app: app)
    precondition(labels(ui).contains("已连接家庭网络"))
    ui.ssidField.stringValue = "Unsaved edit"
    app.currentSSID = "Office"
    app.speakerStatus = "扬声器保护：未确认在家 · 已静音"
    ui.update(app)
    precondition(labels(ui).contains("已连接外出网络"))
    precondition(labels(ui).contains("已静音"))
    precondition(ui.ssidField.stringValue == "Unsaved edit")
    app.currentSSID = "未连接或尚未允许识别"
    ui.update(app)
    precondition(labels(ui).contains("暂时无法识别当前网络"))
    app.settings = HomeSettings(ssid: "", ip: "")
    ui.update(app)
    precondition(labels(ui).contains("先设置你的家庭网络"))
    let window = NSWindow(contentRect: ui.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.delegate = app
    window.contentView = ui
    app.window = window; app.settingsUI = ui
    app.ssidField = ui.ssidField; app.ipField = ui.ipField
    releasedUI = ui
    window.close()
    precondition(app.window == nil && app.settingsUI == nil && app.ssidField == nil && app.ipField == nil)
}
precondition(releasedUI == nil)
print("UI checks passed: home/away/unknown/setup states, unsaved edits, closed-window release")
