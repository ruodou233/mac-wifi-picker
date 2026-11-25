# Third-Party Notices

Mac WiFi Picker contains no third-party code. It is written against Apple's public frameworks (AppKit, CoreWLAN, CoreLocation, Network, ServiceManagement).

While designing it, the author read the following open-source projects for behavior and API choices. No files, code, resources or dependencies from them are included. No code was copied; they were used only as references.

| Project | License | What was studied |
|---|---|---|
| [NetFluss](https://github.com/rana-gmbh/NetFluss) | GPL-3.0 | Scanning, refresh, SSID grouping, password join and permission flow |
| [wifiscan](https://github.com/lucasdaddiego/wifiscan) | MIT | Whether CoreWLAN still reports RSSI and channel on current macOS |
| [WiFi Lens](https://github.com/ShiinaLabs/wifi-lens) | Apache-2.0 | Serial scanning, throttling and backoff |
| [WifiWand](https://github.com/keithrbennett/wifiwand) | Apache-2.0 | CoreWLAN error classification |

The implementers had read the upstream source, so this is not a strict clean-room implementation. Details: [docs/THIRD-PARTY-RESEARCH.md](docs/THIRD-PARTY-RESEARCH.md).

---

Mac WiFi Picker 不含第三方代码，只用 Apple 的公共框架。设计时参考过上表几个开源项目的行为和 API 用法，没有导入它们的文件、代码、资源或依赖。只参考，没有复制代码。实现者读过上游源码，所以不算严格的 clean-room（净室）实现。
