import AppKit

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

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
    precondition(labels(ui).contains("当前版本 开发版"))
    app.updateState = .available(ReleaseInfo(version: "9.0.0", page: ReleaseInfo.releasesPage + "/latest"))
    ui.update(app)
    precondition(labels(ui).contains("发现新版本，下载后替换安装"))
    app.updateState = .failed("网络不可用")
    ui.update(app)
    precondition(labels(ui).contains("检查失败：网络不可用"))
    app.updateState = .upToDate
    ui.update(app)
    precondition(labels(ui).contains("已是最新版本"))
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
// Closing the window hands freed pages back; the idle app must stay small.
_ = malloc_zone_pressure_relief(nil, 0)
let afterClose = footprintMB()
precondition(afterClose < 50, "footprint after closing window: \(afterClose) MB")
print(String(format: "Footprint after closing settings window: %.1f MB", afterClose))
print("UI checks passed: home/away/unresolved/disconnected/setup states, update states, unsaved edits, closed-window release")
