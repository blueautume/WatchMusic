# 实验版验证记录

日期：2026-10-28。

## 已完成

- Xcode 27.1：iPhone + 内嵌 Watch app Debug 模拟器完整构建通过，最终增量构建通过。
- Watch target 独立 Debug 模拟器构建通过。
- 产物中的两个 Bundle ID、`WKCompanionAppBundleIdentifier`、`随身音乐 Lab` 名称和 `0.1.0 (1)` 版本一致。
- 原工程源码与配置哈希比对：无变化。
- 播放队列：46,760 个断言通过。
- 音频格式：186 个断言通过。
- 有界元数据读取：277 个断言通过，包含真实 MP3 / FLAC 夹具。
- 封面解码：40 个断言通过。
- 传输采样：排队、进展、停滞、恢复、计数回退、文件大小变化、后台间隔、完成和取消测试通过。
- iOS 与 watchOS 播放器原生集成：分别 31 个断言通过，覆盖静默恢复、进度边界、队列修改、异步元数据取消与两种格式内嵌封面。
- 应用源码与配置中已无歌词入口、解析、资源传输及文件类型声明。

## 界面检查

- [iPhone 播放页](Artifacts/Previews/phone-player.png)：已检查；主要播放按钮居中，歌词入口已移除，保留手机播放进度控制。

- [40mm 手表播放页](Artifacts/Previews/watch-player-40mm.png)：watchOS 26.5 已检查；主按钮 44pt，12pt 水平内边距及底部留白，无播放进度条和歌词入口。

- [49mm 手表播放页](Artifacts/Previews/watch-player-49mm.png)：watchOS 26.5 已检查；按钮与文字保持在安全区域内，左右及底部留白正常。

## 真机待验收

- 两端实验版同时安装，与原应用并存，数据分别保存。
- 发送 MP3 / FLAC，核对进度、估算速度/剩余时间；排队、断连和停滞时隐藏无效估计。
- 发送 100% 后等待成功保存回执，手表存储不足或解码失败时显示失败。
- 多文件排队、取消、重试以及两端重启后的回执处理。
- 手表离开手机后的播放、锁屏后台音频、蓝牙断连暂停与耳机控制。
- 手表最小与最大尺寸的实际触控、较长歌名及大字体。
- 支持设备上的双指互点下一首。

编译出现的 AppIntents 元数据提取跳过提示来自未使用 AppIntents 框架，不影响构建。模拟器无法代表真实蓝牙吞吐量和后台系统调度。

## 局域网分支验证（2026-10-28）

分支：`experiment/lan-transfer`。使用方式与范围见 [局域网传输实验](LANTransferExperiment.md)。

- 两端 Debug / Release 模拟器完整构建通过，真机自动签名构建通过。
- LAN 清单、端点与摘要验证：54 个断言通过。
- HTTP 解析与真实 Network/URLSession 服务探针：45 个断言通过。
- 取消/保存竞态、握手及历史回执隔离：32 个断言通过。
- watchOS 26.5 的真实 HTTP 接收探针通过五个场景：MP3/FLAC 正常下载保存、同大小内容损坏拒绝、HTTP 失败拒绝、超出清单大小拒绝、取消后无落盘。
- 界面已检查：[手机模式选择](Artifacts/Previews/phone-lan-transfer.png)、[40mm 手表接收状态](Artifacts/Previews/watch-lan-transfer-40mm.png)。
- 配对真机 iPhone 15 Plus → Apple Watch Series 9：通过真实 WatchConnectivity 握手与手机临时 HTTP 服务，成功传送 3,973,284 字节 FLAC 和 286,919 字节 MP3。手机收到保存成功回执后，从手表读回两份文件，与源文件逐字节及 SHA-256 比较一致。
- [真机验证记录](Artifacts/Verification/lan-physical-result.json) 仅包含测试音频摘要和设备型号，不含会话令牌、局域网地址或设备标识。自主生成测试音频未播放；手机测试音频已清理。手表清理命令已执行，随后开发连接中断，未复核清理结果。如曲库仍显示 `LANProbe-` 开头的测试目录，可直接删除。

本次证明局域网 HTTP 传输可用；没有通过无线链路抓包证明手表绕过了 iPhone 代理，也未完成同条件普通模式/局域网模式的速度基准对比。
