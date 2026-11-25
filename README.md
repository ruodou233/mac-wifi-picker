# Mac Wi‑Fi 按信号排序｜Mac WiFi Picker

**A macOS menu bar Wi‑Fi list sorted by signal strength. Click a network to join it.**

> 周围几十个 Wi‑Fi，系统列表又不按信号强弱排，想连个最强的只能一个个去试。

Mac WiFi Picker is a small, local menu bar app. It scans nearby Wi‑Fi networks with Apple's CoreWLAN, sorts them strictly from strongest to weakest signal, and joins the one you click. Everything happens in one panel under the menu bar icon, password page included.

[中文说明](#中文说明)

<img src="assets/screenshot.png" width="340" alt="Mac WiFi Picker panel: networks sorted by signal strength">

## Features

- Sorts networks by raw signal strength (RSSI), strongest first. The current network is marked, not pinned to the top. Ties keep a stable order, so the list does not jump around.
- One row per network name. Signal shows as bars, never as a number.
- Click to join. Open networks join right away; a network with a password asks for it in the same panel. A wrong password stays on the page, selected, ready to retype.
- On a dual-band network it joins 5 or 6 GHz when that signal is good enough (−70 dBm or better), otherwise the strongest access point.
- Opens by itself when Wi‑Fi drops, without taking the keyboard from the app you are typing in. One click on a network still joins it.
- Enterprise (802.1X) and WEP networks open System Settings → Wi‑Fi instead.
- Printer hotspots (`DIRECT-…`) are left out of the list.
- The menu bar icon shows the current signal. Right-click it to quit.
- Runs locally. No account, no analytics. Passwords are never saved or logged.
- The interface is in Chinese.

If you want only this panel to appear when Wi‑Fi drops, turn off **System Settings → Wi‑Fi → Ask to join networks**.

### Experimental, not yet verified on a real Mac

- **Saved networks without retyping the password.** Clicking a network macOS already knows first tries to join without a password, letting macOS use the one it saved. If that fails, the password page opens. Apple does not document this use, so it may not work on every macOS version. The app never reads the keychain.

## Permissions

- **Location Services**: macOS only gives Wi‑Fi network names to apps with location access. Without it, the panel shows one button to allow it. The app does not use your location for anything else.
- **Login item**: the app registers itself to open at login. If macOS asks, approve it in **System Settings → General → Login Items**.

## Download

Download the zip from [Releases](https://github.com/ruodou233/mac-wifi-picker/releases/latest), unzip it, and drag **Mac WiFi Picker** into **Applications**.

The package is an ad-hoc signed Apple Silicon build that Apple has not notarized. If macOS blocks it the first time, go to **System Settings → Privacy & Security** and click **Open Anyway**. Or remove the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Mac WiFi Picker.app"
```

## Build from source

```bash
git clone https://github.com/ruodou233/mac-wifi-picker.git
cd mac-wifi-picker
./Scripts/build.sh
./Scripts/install.sh
```

`build.sh` writes `.build/artifacts/Mac WiFi Picker.app`. `install.sh` copies it to `/Applications`, keeps the previous copy in `~/Library/Application Support/Mac WiFi Picker/`, and starts it from a LaunchAgent (`io.github.ruodou233.MacWiFiPicker`).

The two ways to install start the app differently:

- **Downloaded zip**: the app's own login item opens it at login.
- **`install.sh`**: the LaunchAgent opens it at login and also relaunches it if it crashes. Quitting from the menu stays quit until next login. The app then removes its own login item, so only one copy starts.

Tests: `./Scripts/test.sh` and `./Scripts/test-static.sh`. Design notes are in [SPEC.md](SPEC.md) and the test checklist in [docs/VERIFY.md](docs/VERIFY.md), both in Chinese.

## Requirements

- An Apple Silicon Mac
- macOS 13 or newer
- Swift 6.1 or newer to build from source

## Feedback

Issues and pull requests are welcome.

This project is released under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the projects it learned from.

---

## 中文说明

**菜单栏里的 Wi‑Fi 列表，按信号强弱排序，点一下就加入。**

Mac WiFi Picker 是一个纯本地的 macOS 菜单栏工具。它用 Apple 的 CoreWLAN 扫描附近网络，严格按信号从强到弱排列，点哪个就连哪个。列表、密码页都在菜单栏图标下的同一个面板里。

### 主要功能

- 按原始信号强度（RSSI）从强到弱排序。当前网络只打标记，不置顶。信号一样的网络顺序固定，列表不乱跳。
- 同名网络只占一行。信号用格数表示，不显示数字。
- 点一下就加入。开放网络直接连；要密码的网络在同一个面板里输入。密码错了留在这一页并全选，直接重打。
- 双频网络信号够好（不低于 −70 dBm）时优先连 5 GHz 或 6 GHz，否则连最强的发射点。
- Wi‑Fi 断开时自己弹出来，但不抢你正在打字的那个应用的键盘。鼠标点一下网络照样能连。
- 企业网（802.1X）和 WEP 网络点了打开“系统设置 → Wi‑Fi”。
- 打印机直连热点（`DIRECT-…`）不进列表。
- 菜单栏图标显示当前信号。右键图标可以退出。
- 纯本地运行，没有账号、没有统计。密码不保存、不写日志。
- 界面是中文。

想让断网时只出现这一个面板，可以在“系统设置 → Wi‑Fi”里把“询问加入网络”关掉。

### 实验性，尚未在真机上验证

- **已保存的网络不用再输密码。** 点一个系统已经记住的网络时，先不带密码去连，让 macOS 用它保存的密码；连不上再打开密码页。Apple 文档没有保证这种用法，不一定每个系统版本都行。工具本身不读钥匙串。

### 需要的权限

- **定位服务**：macOS 只把 Wi‑Fi 网络名告诉有定位权限的应用。没有权限时，面板里只有一个“允许定位”按钮。工具不拿你的位置做别的事。
- **登录项**：工具会把自己注册成登录时打开。系统要求批准时，去“系统设置 → 通用 → 登录项”里允许。

### 下载安装

从 [Releases](https://github.com/ruodou233/mac-wifi-picker/releases/latest) 下载 zip，解压后把 **Mac WiFi Picker** 拖进“应用程序”。

安装包是临时签名、没有经过 Apple 公证的 Apple Silicon 版本。第一次打开被拦时，去“系统设置 → 隐私与安全性”点“仍要打开”（Open Anyway）；也可以在终端里去掉隔离属性：

```bash
xattr -dr com.apple.quarantine "/Applications/Mac WiFi Picker.app"
```

### 从源码构建

```bash
git clone https://github.com/ruodou233/mac-wifi-picker.git
cd mac-wifi-picker
./Scripts/build.sh
./Scripts/install.sh
```

`build.sh` 生成 `.build/artifacts/Mac WiFi Picker.app`。`install.sh` 把它复制到 `/Applications`，上一份留在 `~/Library/Application Support/Mac WiFi Picker/`，再用 LaunchAgent（用户级后台启动项）`io.github.ruodou233.MacWiFiPicker` 启动它。

两种装法的区别在开机启动：

- **下载 zip**：靠应用自己注册的登录项，登录时打开。
- **`install.sh`**：靠 LaunchAgent，登录时打开，崩溃后还会自动拉起；从菜单退出就一直退出，到下次登录。这时应用会注销自己的登录项，不会起两份。

测试：`./Scripts/test.sh`、`./Scripts/test-static.sh`。设计说明见 [SPEC.md](SPEC.md)，验收清单见 [docs/VERIFY.md](docs/VERIFY.md)。

### 系统要求

- Apple Silicon 的 Mac
- macOS 13 或更新
- 从源码构建需要 Swift 6.1 或更新

### 反馈

发现问题或有改进方案，欢迎在本仓提交 issue 或 PR。
