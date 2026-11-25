# 第三方参考与许可边界

## 参考过的项目

| 项目 | 固定版本 | 许可证 | 本项目使用范围 |
|---|---|---|---|
| [NetFluss](https://github.com/rana-gmbh/NetFluss) | `2f4a2c1d7d756877bbae5c5b6a3ca2e299d0dcc4` | GPL‑3.0 | 只研究扫描、刷新、SSID 聚合、密码连接与权限交互行为；未导入文件、依赖或文本代码 |
| [wifiscan](https://github.com/lucasdaddiego/wifiscan) | `2367313ec9d46efe20b1c3a7fb33e6b968113106` | MIT | 核验现代 macOS 上 CoreWLAN 的 RSSI/信道扫描可行性；未导入代码 |
| [WiFi Lens](https://github.com/ShiinaLabs/wifi-lens) | `4522c6f4394b958b043dc202d80092e6adacb1e2` | Apache‑2.0 | 研究串行扫描、节流与退避；未导入代码 |
| [WifiWand](https://github.com/keithrbennett/wifiwand) | `61e06e1450b38c3c51c6d26baaa5248d46f67365` | Apache‑2.0 | 研究 CoreWLAN 错误分类；数字错误码仅作为提示，不视为稳定协议；未导入代码 |
| Apple SDK / Developer Documentation | 当前 macOS SDK | Apple 平台文档条款 | 公共 API、头文件契约与可用性依据 |

## 独立实现

- 单进程可嵌入模块，与 NetFluss 的完整应用结构不同；
- 模型使用 SSID bytes + security 分组，并保留所有 AP 明细；
- 排序使用 raw RSSI + 稳定 ID，不采用 NetFluss 的置顶/当前网络优先规则；
- 生命周期、连接确认、登录启动、测试和 AppKit 宿主均在本仓库重新编写；
- 没有添加 NetFluss 的 package dependency、文件、资源、注释或 helper。

## 边界

实现过程看过上游公开源码，所以这不是“两个隔离团队、实现者从未接触源码”的严格 clean-room（净室）实现。能说明的是：仓库没有导入第三方代码，功能通过 Apple 公共 API 独立实现，参考范围记录在上表。
