# 操作界面原型

用浏览器打开 `index.html` 即可预览，使用原生 HTML、CSS、JavaScript，无构建依赖。图标引用仓库中的 `assets/app-icon.png`。

包含当前状态、家庭网络、权限与启动三个页面。页面底部可模拟在家、办公室与断网状态；支持自动填入示例 Wi-Fi、IPv4 输入校验、保存提示和开关交互。

所有网络、IP、声音和权限均为模拟，仅保存在本次页面会话中。刷新恢复默认数据，不会读取或改变 macOS 设置。

在仓库根目录执行 `python3 -m http.server 18743 --bind 127.0.0.1`，访问 `http://127.0.0.1:18743/prototype/index.html`。也可直接打开本地 HTML 文件。
