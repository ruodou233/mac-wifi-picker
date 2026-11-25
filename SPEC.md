# Mac WiFi Picker 设计说明

## 1. One-Sentence Concept

菜单栏里一个 `NSPopover`：列表、密码、连接和错误状态都在同一个 Popover 内完成，网络严格按原始 RSSI（信号强度，dBm）从强到弱排序。

## 2. 为什么是单个 Popover

早期版本用一个高层级窗口做主面板，密码另弹 `NSAlert`：

- 主面板是 `NSWindow.Level.statusBar`；
- 加密网络密码使用独立 `NSAlert.runModal()`；
- 主面板手算坐标、强制置顶、跨 Space；
- 代码还会识别、隐藏或结束 `WiFiAgent` / `mbuseragent`。

实测的窗口层级：

| 窗口 | WindowServer layer | bounds |
|---|---:|---|
| 自定义 Wi‑Fi 主面板 | 25 | `650 × 526` |
| 密码 `NSAlert` | 8 | `372 × 259` |

macOS 窗口层级优先于同层前后顺序，所以 layer 25 的主面板必然遮挡 layer 8 的密码框。继续增加 `activate`、`makeKey`、`orderFront` 或更高层级，只会延续窗口补丁链。所以改成一个 Popover，所有页面都在里面。

## 3. Target User And Core Scenario

### 用户

在 SSID 密集的环境里用 Mac、想直接连上信号最强的网络的人。

### 场景

- 在酒店、会议场地、办公楼等 SSID 密集环境中从菜单栏打开 Wi‑Fi 列表；
- 网络严格按实际信号强弱排列；
- 选择个人加密网络，在同一界面输入密码并连接；
- 断网时只出现本工具的一份可操作面板；
- 不出现 Dock 图标、被遮挡的密码框、两个竞争窗口或系统进程治理副作用。

### 核心路径

1. 用户点击菜单栏 Wi‑Fi 图标，或当前 Wi‑Fi 稳定断开。
2. 系统锚定的同一个 `NSPopover` 显示扫描列表。
3. 用户单击网络（键盘：上下选、回车）。
4. 开放网络和已保存的个人网络直接开始加入；未保存的个人网络切换到同一 Popover 内的密码页；已保存网络加入失败时也进这个密码页，不写原因。
5. 加入过程在被点的那一行（或表单上）原地转圈，不切页。
6. 成功后 Popover 关闭；失败时原因写在出问题的那一行下方或密码框下方，可以重试。
7. Escape / 返回按状态逐级返回，不退出后台进程。

## 4. External Reference And Decision

### Apple 官方

- Popover 应锚定触发控件、同时只显示一份，并由系统负责位置：
  - https://developer.apple.com/design/human-interface-guidelines/popovers/
  - https://developer.apple.com/documentation/appkit/nspopover
- `NSStatusItem` 是公开的菜单栏入口：
  - https://developer.apple.com/documentation/appkit/nsstatusitem
- Apple 允许 Alert 出现在 Popover 上方，但没有承诺所有 Space / 多屏组合下永不发生宿主关闭或层级异常：
  - https://developer.apple.com/design/human-interface-guidelines/alerts
- Apple 明确说明窗口 level 的堆叠优先级：
  - https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct

### NetFluss

NetFluss 使用 `NSStatusItem + NSPopover`，新加密网络使用 `NSAlert + NSSecureTextField`。这说明该组合可用，但不能把第三方实测提升为“所有桌面与显示器永远不遮挡”的系统保证。

- https://github.com/rana-gmbh/netfluss
- https://github.com/rana-gmbh/NetFluss/blob/main/Sources/Netfluss/WifiManager.swift
- https://github.com/rana-gmbh/netfluss/releases

NetFluss 是 GPL‑3.0；本项目只参考行为与 Apple API 组合，不复制其源码。见 `THIRD_PARTY_NOTICES.md`。

### 本项目的决定

- 宿主采用 `NSStatusItem + NSPopover`；
- 密码采用同一 Popover 内联页，不创建 `NSAlert`；
- 不使用自建高层级主窗口；
- 不管理 Apple 系统进程；
- “只有一份面板”依赖关闭系统的“询问加入网络”，这是使用者自己的设置，不伪装成 App 自身能力。

## 5. Platform And Constraints

- macOS 13+。
- AppKit、CoreWLAN、CoreLocation、ServiceManagement、SwiftPM。
- `LSUIElement`，不显示 Dock 图标。
- SSID/BSSID 可见性依赖定位权限。
- 密码不写文件、不写日志、不持久化。
- 企业 802.1X / 证书网络不在面板里加入，点了打开系统设置。
- ad-hoc（临时）签名，不依赖专用钥匙串、签名密码或固定证书。

## 6. Architecture

```text
WiFiPickerHost（菜单栏宿主）
             │
     WiFiPickerViewController       可替换的 AppKit 界面
             │
       WiFiPickerController         权限、刷新、连接、隐藏/重现状态机
             │
        WiFiServicing 协议          可测试、可替换
             │
     CoreWLANWiFiService            操作与链路观察使用隔离的串行队列
             │
     WiFiScanSnapshot（纯值）       UI 永远不持有 CoreWLAN 对象
```

扫描、排序、权限和连接都在库 `MacWiFiPicker` 里；`WiFiPickerHost` 只负责菜单栏状态项、单个 `NSPopover` 和登录启动。其他 App 可以只依赖库产品 `MacWiFiPicker`：

```swift
let controller = WiFiPickerController()
let pickerViewController = WiFiPickerViewController(controller: controller)

controller.onVisibilityRequest = { request in
    // 宿主决定在哪里显示面板。
}
controller.start(manuallyLaunched: true)
```

### 6.1 Popover 宿主

`AppDelegate` 只拥有：

- 一个 `NSStatusItem`；
- 一个 `NSPopover`；
- 一个复用的 `WiFiPickerViewController`。

实现：

- `popover.contentViewController = pickerViewController`；
- `popover.behavior = .applicationDefined`；
- `show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)`；
- 点击状态项、Escape（面板接管键盘后：列表页和加入中直接关闭，密码页先返回列表）、打开系统设置或连接成功时显式关闭；
- 点击其他应用时保持打开，面板要持续可用；
- “极少情况下 AppKit 仍可能关闭 applicationDefined Popover”算实机行为，不写成平台绝对保证。

不做：

- `NSWindow.Level.statusBar`；
- `orderFrontRegardless()`；
- 手算屏幕坐标；
- 透明标题栏、隐藏交通灯和 Window delegate 关闭链路；
- `canJoinAllSpaces / fullScreenAuxiliary` 窗口补丁；
- `CGWindowList`、`WiFiAgent`、`mbuseragent` 查询、隐藏和结束逻辑。

### 6.2 单 Popover 页面状态

只维护一个轻量页面状态：

```text
page: list | credentials(target) | hiddenCredentials | permission
join: nil | row(network) | password(network) | hidden
```

规则：

- 这两个值都在 `WiFiPanelFlow`（不依赖 AppKit，模型测试直接覆盖）；
- 加入不是一个页面：列表或表单留在屏幕上，`join` 不为空时不接受第二次加入；
- `credentials` 和 `join` 持有不可变目标值，不依赖刷新后的行号；
- 原因在下一次加入或关闭 Popover 时清除，不增加独立关闭按钮；
- 连接成功后这一行显示为当前网络，0.6 秒后关闭 Popover。

### 6.3 内联密码页

从列表进入 `credentials` 后，同一 Popover 切换内容：

- 标题“加入 SSID”；
- `NSSecureTextField`，占位“密码”；
- 取消（回列表）与加入按钮；
- 进入页面后密码字段成为首焦点；
- Enter 加入，Escape 返回列表；
- 加入按钮仅在密码非空时可用；
- 不增加“显示密码”、强度提示或密码保存选项。

密码生命周期：

- 页面创建时为空；
- 取消、Escape、连接成功后立即把字段置空；密码错了留在框里并全选，方便重输；
- 控制器接收密码后不写日志，错误对象不得包含密码；
- Popover 关闭时无条件清空。

这条路径没有第二窗口，因此不存在跨 layer、跨 Space 或父窗口遮挡问题。

### 6.4 连接与刷新

- Popover 打开时先显示系统缓存的扫描结果（`cachedScanResults`，快照超过 30 秒才用），同时开始新扫描，完成后替换；
- 仅 `list` 页面每 8–10 秒刷新，失败按 8–60 秒退避；面板失去键盘焦点 60 秒后暂停，重新点进面板立即刷新；
- `credentials` / `connecting` 页面不更新可见列表；后台若有扫描回调，只更新缓存，不改变当前目标；
- 返回 `list` 时使用最新缓存并触发一次刷新；
- 扫描中保留旧快照，避免几十个 SSID 场景下列表闪空；
- 加入中禁用取消和重复加入，Esc 仍可关闭面板；失败后留在原处写原因；
- 连接前按目标 SSID bytes 重新扫描，再逐项核对 SSID bytes 与安全类型；BSSID 缺失时仍可连接；
- 普通扫描 12 秒超时；可见网络的 CoreWLAN 关联最多等 25 秒；隐藏网络在同一个 30 秒端到端 deadline 内预留“目标解析最多 10 秒 + 关联最多 15 秒 + 晚到链路确认至少约 5 秒”。Apple 没有提供取消阻塞 CoreWLAN 调用的 API，所以超时后拒绝叠加新操作，同时用独立观察队列继续读取真实链路；
- “目标 SSID bytes + 安全类型连续 4 次稳定确认”是连接成功判据，不要求互联网可达，Captive Portal（网页认证）不算失败；
- 成功判据满足后，宿主在 1 秒内幂等关闭 Popover，状态项和后台观察进程继续运行；
- CoreWLAN 超时后若目标链路在总 deadline 内晚到并稳定出现，同样按成功关闭；
- Popover 关闭后，已关联状态的链路回调只能更新缓存，不能重新触发自动显示。

### 6.5 断网观察

- 后台每 5 秒做一次低成本链路检查，Wi‑Fi 专用 `NWPathMonitor` 只作为即时复查的触发器，不把“互联网路径正常”当作“已连上目标 Wi‑Fi”；
- 单次状态读取最多等 2 秒，读取不可用不冒充真实断网，连续不可用时才以“宁可显示入口”的方式兜底；
- 真实断线稳定 1.5 秒才算，过滤漫游瞬态；
- 用户手动关闭面板后 30 秒内不自动弹出；启动和唤醒后 10 秒宽限。

### 6.6 排序总序

每行代表“SSID bytes + 安全类型”分组中最强 AP，而不是每个 BSSID 一行；同名的 2.4/5/6 GHz 与多个 BSSID 保留在 `accessPoints` 中。

排序键依次为：

1. 分组最强 AP 的 raw RSSI 降序；
2. SSID `localizedStandardCompare`；
3. `security.rawValue`；
4. `ssidDataHex`；
5. 稳定 `id`。

当前网络只显示标记，不置顶。信号图标只表达强弱，不参与排序。dBm 不显示（第 12 节）。选发射点时偏向 5/6 GHz（第 11 节）只影响连接，不进这个排序键。BSSID 可缺失：有 BSSID 时作为 AP 身份，没有时用 SSID bytes、安全类型、频段与信道形成聚合身份，不伪造地址。SSID 不可读的观测不生成可点击的假行。打印机直连热点（SSID 以 `DIRECT-` 开头）不进列表，除非当前就连着它。

### 6.7 单面板的前提

在“系统设置 → Wi‑Fi”把“询问加入网络”设为“关闭”。

Apple 设置说明：https://support.apple.com/guide/mac-help/use-wi-fi-settings-on-mac-mchl339ee00e/26/mac/26

- App 不读取或写入这项设置的内部值，不把它当公共 API；
- App 不自动关闭 Apple 面板，不结束 `WiFiAgent`；
- 这是全局系统设置，由使用者自己决定；不关闭时，断网时系统自己的提示可能和本工具同时出现。

## 7. Scope

### 包含

- `NSPopover` 宿主；
- 同 Popover 的列表、内联密码、连接和错误页；
- 显式焦点、Enter、Escape 和返回流程；
- 严格排序总序；
- UI、模型、静态和实机场景验证。

### 不包含

- `NSAlert` 密码窗；
- root / privileged helper；
- 自动修改系统“询问加入网络”；
- 读写钥匙串里的 Wi‑Fi 密码；
- Pin、可拖动浮窗、自动切最强网络；
- 企业网络连接；
- Apple 私有 UI 或 Accessibility 自动操作。

## 8. Event Priority And Reentrancy

| 当前页面 | 事件 | 行为 |
|---|---|---|
| hidden | 用户点击状态项 | 打开 `list` 并扫描 |
| hidden | 稳定断网 | 打开 `list`（不抢键盘） |
| list | 再次断网/路径更新 | 不重复 show，只刷新缓存 |
| list | 用户关闭 | 关闭 Popover，30 秒内不自动弹出 |
| credentials | 扫描/断网回调 | 只更新缓存，不切页、不清密码 |
| credentials | Escape/返回 | 清空密码，回 `list` |
| credentials | 用户关闭 Popover | 清空密码并关闭 |
| 加入中 | 扫描/断网回调 | 忽略 UI 跳转，等待连接任务收口 |
| 加入中 | 重复加入 | 忽略 |
| 加入中 | 成功或 deadline 内晚到成功 | 1 秒内幂等关闭 Popover；后台进程继续；已关联回调不得重开 |
| 加入中 | 失败 | 行内加入在该行下方写原因；密码页留在原页，写原因并全选密码 |

同一时刻最多一个 Popover、一个连接任务、一个选中目标。

## 9. Scenario Acceptance Tests

### Scenario 1：菜单栏 Popover

- Given：App 后台运行且当前 Wi‑Fi 正常。
- When：点击自定义菜单栏 Wi‑Fi 图标。
- Then：Popover 锚定图标显示；无 Dock 图标、无独立 `statusBar` 主窗；再次点击或 Escape 关闭。

### Scenario 2：严格排序

- Given：扫描包含不同 RSSI、同 RSSI、同名不同安全类型。
- When：显示快照并连续刷新。
- Then：完整排序键稳定生效；输入顺序改变不会让等价行抖动；当前网络不置顶。

### Scenario 3：密码输入不遮挡

- Given：选择未保存个人加密网络。
- When：单击这一行。
- Then：同一 Popover 切换到密码页；字段完整可见且是首焦点；进程没有创建第二个可见窗口。

### Scenario 4：密码取消与清理

- Given：密码页已输入测试字符。
- When：按 Escape、取消或关闭 Popover。
- Then：回到列表或关闭；原选择保留；密码字符串和字段立即清空；不发起连接。

### Scenario 5：成功与失败

- Given：密码页已输入密码。
- When：连接成功或失败。
- Then：目标 SSID bytes 与安全类型稳定确认后，Popover 在 1 秒内关闭且不会因已关联回调重新打开；Captive Portal 或无互联网不阻止关闭；deadline 内晚到的稳定关联也关闭。失败时留在原处写原因并恢复操作；密码错了留在框里全选，其余路径都清空密码。

### Scenario 6：断网只出现一份

- Given：系统“询问加入网络”已关闭，App 后台运行。
- When：当前 Wi‑Fi 稳定断开且没有首选网络可用。
- Then：只出现本工具 Popover；代码不查询、不隐藏、不结束 Apple 进程。

### Scenario 7：有限显示矩阵

在以下组合里验收，不写“所有环境绝对保证”：

- 菜单栏位于主屏：普通桌面；
- 菜单栏位于副屏：普通桌面；
- 当前 App 激活与未激活；
- 一个全屏 Space；
- 密码页在每个组合中可见、可聚焦、可取消。

### Scenario 8：定位权限不可用

- Given：定位关闭或拒绝。
- When：打开 Popover。
- Then：不显示假 SSID；同一 Popover 内一行说明和一个按钮；不打开系统 Wi‑Fi 面板。

## 10. 设计取舍

- 单面板写成有前提的保证（第 6.7 节），不自动检测系统内部设置；
- 密码页内联在 Popover 里；
- 写明事件优先级、完整排序键、密码清理点和有限多屏矩阵；
- 不管理系统 Agent；
- 错误随下一动作自动清除，不增加关闭按钮；
- 为什么不只扫描一次：核心场景是拥挤环境中的实时强度排序，快照陈旧会直接损害目标，所以面板可见时每 8–10 秒刷新；
- 为什么扫描时不清空列表：常见几十个 SSID，扫描期间闪空会显著降低可用性，所以保留旧快照；
- 为什么不只做一次 UI 验收：窗口层级与焦点问题需要模型、静态和有限实机场景三类验证，但不制造额外门禁。

## 11. 交互、连接与工程细节

### 交互

- **自动弹出不抢键盘**：断网自动弹出时不激活应用、不 `makeKey`，`presentWithoutKeyboard` 让回车不加入任何网络。否则用户在别的 App 打字时按回车，可能直接加入上次选中的开放网络。关闭面板清空选中。
- **单击即连，且第一下点击生效**：自动弹出的面板在非激活状态，所以所有控件都接受 first mouse（非激活状态下的第一次点击），而不是只把窗口激活后要求再点一次。行视图和单元格不参与点击判定（`hitTest` 返回 nil），否则点击会落在不接受 first mouse 的子视图上。
- **按下和松开解析到同一个网络身份**：两次之间列表可能重排，不用行号判断。
- **操作过就不自动收起**：鼠标点进自动弹出的面板后，按手动打开处理，连上网络也不收起。
- **扫描中点网络先等扫描返回**：CoreWLAN 的扫描取消不了，扫描占着接口时加入会报“仍在处理上一次请求”。缓存先显示、单击即连、点回面板恢复扫描叠在一起后这很常见，所以加入前先等被取消的扫描返回，30 秒加入期限从那之后算。
- **焦点和 Esc**：重绘只隐藏非目标页，否则表格会丢键盘焦点；回到列表时把焦点还给表格。Esc 由面板的本地按键监听处理，不依赖当前焦点。
- **操作过的判定只在弹出时重置**：断网期间每 5 秒的链路检查不会把面板改回“自动弹出”。
- **启动和唤醒 10 秒宽限**：链路还没起来不算断网。宽限内的断开由下一次 5 秒链路检查接手。

### 连接

- **已保存网络先试空密码（实验性，尚未在真机上验证）**：`associate(to:password:)` 传 nil，由 macOS 决定能否用它保存的凭据。任何失败都进密码页，不分错误码，因为 CoreWLAN 的错误码分不清“密码错”和“系统没有可用凭据”。页上不写原因：用户没做错什么，原因写日志。不读钥匙串（会弹框，密码过期时还会循环失败）。Apple 文档写的是个人网络要提供密码，没有保证这种用法；NetFluss 这样用，Status Trio 试过后放弃。不可用时，把 `WiFiJoinPolicy` 里已保存个人网络的分支改回 `.askForPassword`，并去掉 `CoreWLANWiFiService.associate` 里的 `!choice.isSaved` 条件，就回到一律要密码。
- **选发射点**：同一网络内 5/6 GHz 不低于 −70 dBm 就优先，否则取最强。门限判定比加分法直白，和系统选网方向一致。列表排序仍用最强发射点，否则排序看起来会错。
- **OWE 归入开放**：OWE（增强型开放网络）不要密码、连接流程和开放网络一样，不新增安全类型。扫描分类时先判“开放”，再判企业和个人，最后才判 OWE，所以个人网络顺带回答 OWE 时不会被归错。WEP 不支持，点了打开系统设置。

### 界面

- **信号图标分档**：`wifi` 符号的亮灭门限是 0、1/3、2/3，按 −58、−68 dBm 分档，让强中弱看起来不同；可见网络至少一格。
- **不做滞回、不置顶、不做前 N 个**：都和“严格按信号排序”冲突。

### 权限与扫描

- **定位状态只读缓存**：`locationManagerDidChangeAuthorization` 里更新，`locationServicesEnabled` 放到后台线程。Apple 文档说明创建 `CLLocationManager` 时就会回调一次，所以初始值 `notDetermined` 只持续很短时间。主线程不同步查询 `locationd`。
- **授权框出不来时**：请求授权时同时 `startUpdatingLocation()`，授权状态一确定就 `stopUpdatingLocation()`。只调 `requestWhenInUseAuthorization` 时，菜单栏应用可能不弹框，也不出现在定位服务列表里。被拒时给“打开定位设置…”按钮，不自动打开设置页。
- **不做后台扫描和自动漫游**：会造成延迟尖峰。菜单栏图标只用现有 5 秒链路检查。

### 工程

- **登录启动两条路**：App 第一次启动时自己注册 `SMAppService.mainApp` 登录项，需要批准时在面板里给“打开登录项设置…”。用源码里的 `Scripts/install.sh` 安装时改用 LaunchAgent `io.github.ruodou233.MacWiFiPicker`：`KeepAlive` 只在崩溃时拉起，右键退出是干净退出，要能真正退出。以 `--login-launch` 启动、或 LaunchAgent plist 存在时，App 会注销自己的登录项，登录时不会起两份；进程锁和 `LSMultipleInstancesProhibited` 是最后一道防线。
- **日志**：`Logger`，subsystem `io.github.ruodou233.MacWiFiPicker`，只记显示原因、扫描耗时和网络数、连接结果码，不记密码：

  ```sh
  /usr/bin/log show --last 10m --predicate 'subsystem == "io.github.ruodou233.MacWiFiPicker"' --style compact
  ```

- **静态检查只留 plist、签名、产物和“不能有第二个窗口”**：不做“源码里必须出现某字符串”的检查，它们只会在重构时误报。

## 12. 界面原则

判断标准：界面上每个可见元素都要回答“用户靠它做判断或操作吗”，答不上来就删。信号强度的具体数值、频段、信道、BSSID、“已保存”都不需要让用户看到，足够简单、方便判断就行。读屏标签用户看不见，不受此限。

- **行**：圆底信号图标、网络名、有密码时一个锁。dBm 只用于排序和选发射点，任何地方都不显示。企业网和 WEP 也是锁，点了打开系统设置，用户不需要提前知道它是哪一种。
- **尺寸**：面板宽 340pt，内容距边 14pt，只用 13pt 和 11pt 两种字号，只用语义色；每行 30pt；名字太长从中间截断，只有被截断时悬停才显示全名。
- **不分“已知网络 / 其他网络”**：会推翻全局按信号排序，这是工具的卖点。
- **不加 Wi‑Fi 开关**：新增“关闭 Wi‑Fi”的能力，容易误关。
- **Wi‑Fi 关闭时“加入其他网络…”变灰**：点进去提交必然失败。
- **没有刷新按钮和状态行**：列表自己扫描。失败时有旧列表就继续用，用户不需要知道这次刷新没成功；没有列表才显示“无法扫描”和“重试”。
- **错误不带错误码**：用户拿它做不了什么，原始错误写日志。
- **行内转圈放在锁的位置**：加入是这一行的事，所以不切页，列表也不动。成功不提示，状态自己变。
- **密码错了留在原页并全选**：密码框等结果时禁用，内容保留，这是唯一一处在失败后保留密码的地方，关闭面板仍清空。
- **打开系统设置后收起面板**：和系统菜单选中一项后的行为一致，“Wi‑Fi设置…”、企业网和 WEP 的行、“打开登录项设置…”都是这样。权限页的“打开定位设置…”例外，授权后列表要在原面板里出来。
- **缺定位权限时菜单栏照常显示信号格**：感叹号在系统里表示“连着但没有互联网”，会被看成断网；权限只在打开面板时用得到，面板会直接显示权限页。
- **菜单栏图标**：已连接按信号显示格数且至少一格，已开未连是空扇形，关闭是斜杠；没有悬停提示。右键（或 Control‑点按）图标可以退出。
- **面板空状态和权限页不放大图标**：用户不靠它做判断。
- **隐藏箭头用私有键**：`shouldHideAnchor`，每次显示前设，`responds(to:)` 判断；失效时箭头回来，不崩溃。不自绘 `NSPanel`：定位、多屏、全屏空间都要自己处理。
- **隐藏网络页保留一条“需要在“Wi‑Fi设置”中加入”**：行上的企业网和 WEP 已经不走这里，但手输名称正好是这类网络时，这是唯一能告诉用户的地方。
