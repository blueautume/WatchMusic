# 局域网传输实验

分支：`experiment/lan-transfer`，从 `main` 的 `3fd5c71` 派生。

## 使用

1. 用此分支构建并安装 iPhone 与 Apple Watch 两端实验 App。
2. 两台设备连接能互相访问的同一 Wi-Fi 局域网，在两端打开 App。
3. 手机启动后默认选择“局域网”，从歌曲菜单或目录发送音乐；如需普通 WatchConnectivity 传输，可在“传输”页手动切换“普通”。
4. 手机显示接收进度、估算速度和剩余时间，手表自动进入专用全屏接收页，显示百分比、歌曲、批次及取消按钮。
5. 等待“已保存到手表”。接收完成或取消后，手表自动退出接收页并返回音乐库。失败记录可以“重试局域网”或“改用普通传输”。

局域网传输期间手机 App 需保持前台，应用会暂时保持手机屏幕常亮，结束后恢复原设置；手机进入后台会停止源服务。手表在打开 App 并开始接收后可自然息屏或返回表盘，应用不会因此取消系统下载。系统可能延迟交付进度和保存结果，唤醒手表后才更新界面也属于后台调度范围；不保证息屏期间实时显示速度和预计时间。普通模式继续使用原来的 WatchConnectivity 系统传输。

## 接收页与显示方向

充电或满电仍接电时，接收页在自动模式下通过 CoreMotion 读取重力，识别竖屏、左右横屏和倒置四个方向；左侧表冠设置会先做坐标修正。平放时重力无法确定屏幕内的旋转方向，页面会保留上一个稳定方向；斜角和短暂抖动也不会立即触发旋转，需连续三个明确同向样本才切换。

方向按钮提供“自动”和“旋转 90°”。手动旋转后保持所选方向，重新选择“自动”可恢复重力判断；平放时自动模式仍保留当前方向。检测到拔电后自动回到竖屏及自动模式。退出接收页时停止 CoreMotion，并恢复进入页面前的电量监控设置；进入后台也停止方向采样。

本页不实现“传输期间始终全亮”。watchOS 公共接口不能保证屏幕持续全亮到传输结束，充电也没有通用的保持全亮 API。[Always On](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state) 由设备能力和用户设置决定，系统仍会降低亮度和界面更新频率，并可能返回表盘。接收页适配低亮度状态，底层继续保留此前的系统后台下载及进程恢复，屏幕状态不会主动取消网络任务。

## 实现与范围

- 手机使用 Network.framework 临时开启 HTTP 文件服务，仅选择 Wi-Fi 接口，使用随机端口。
- 地址限定私有 IPv4（当前枚举 iPhone 的 `en0`）；IPv6-only、非私有地址和蜂窝网络不在本轮范围内。
- 双方通过配对设备的 WatchConnectivity 交换短期清单与接收进度，手表用固定标识的后台 `URLSessionDownloadTask` 主动下载，一次在前台提交整批任务。
- 每批最多 100 首，清单还有 55 KB 上限；手机源服务和清单有效期最长 1 小时，完成、停止或过期时关闭监听并清除手机内存中的令牌。单个请求无响应时有超时处理。
- 服务仅允许凭会话令牌读取清单内 UUID 对应的音频；拒绝目录浏览、任意路径和无效请求。音频按 64 KB 分块发送，不整体载入内存。
- 系统后台会话会自动跟随 HTTP 重定向，不能依赖重定向 delegate 阻止。接收器保存前严格验证最终响应 URL：协议、主机、端口和文件 UUID 路径必须匹配清单端点，且无查询、片段或用户信息；不符即拒绝保存。这只验证最终端点，不保证中间跳转未发生。
- 手表验证完整字节数、SHA-256、系统音频解码和可用空间，原子写入成功后才回传保存成功。
- 进度来自手表实际接收字节。100% 后仍需等待校验和保存回执；速度与剩余时间为近期采样估计，系统后台调度可能让这些采样和回执延后。
- 取消与原子保存有明确顺序：保存已完成时，随后到达的取消请求不能撤销保存；手机以严格绑定该文件/会话的成功回执修正最终状态。
- 为跨进程恢复下载，清单及令牌保存在手表 `Application Support/LANBackground-v2/transfer.json`，恢复目录排除备份，并使用 `completeUntilFirstUserAuthentication` 文件保护。令牌不写进正式日志或用户传输记录。实验使用本地 HTTP，未提供 TLS 加密；最终 URL 和 SHA-256 校验用于拒绝错误保存，不提供令牌传输保密性，应在可信局域网使用。

“局域网”表示传输端点与协议，**不代表已经强制手表直接使用 Wi-Fi 无线电**。watchOS 仍可能通过配对手机代理请求，实际链路由系统管理。本实验验证可用性，不预设提速倍数。

## 后台与恢复

手表网络下载由系统独立进程执行。应用启动时先恢复清单，再以同一会话标识重新关联系统任务；已完整下载的文件先保存在受保护的暂存目录中，随后进行完整性校验与原子保存。清单过期后不再发起新请求，已经下载完整的文件仍可继续校验保存。

系统通过 `WKURLSessionRefreshBackgroundTask` 交付后台事件。应用等待本轮 URLSession 事件处理和已完成文件的校验保存结束，再完成该次后台唤醒任务，不用整批仍在下载的任务阻塞这一轮唤醒。普通 WatchConnectivity 后台任务分别处理。保存、失败和取消的终态先持久写入回执队列，待 WatchConnectivity 激活后交给系统发送，再清除队列条目；进程重建或回执延迟不会直接丢失终态。

系统是否立即运行下载、何时唤醒应用和交付进度/结果仍受网络、电量和资源调度影响。手动从系统界面强退 App 可能使系统取消后台传输，不能等同于正常息屏或系统回收进程；这种情况需要重新打开 App 并从手机重试。

## 自动验证

```sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-lan-background-tests.sh
Tests/run-transfer-tests.sh
Tests/run-watch-orientation-tests.sh
```

先以 Xcode 默认模拟器签名构建 Debug 并启动一个 watchOS 模拟器，再运行真实 HTTP 下载探针。不要禁用 `CODE_SIGNING_ALLOWED`：后台下载守护进程需要构建时生成的应用标识 entitlement，单独补一个无 entitlement 的临时签名不足以运行：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app
```

探针启动本机 HTTP 服务，通过仅 Debug 可用的 `-lan-offer-file` 启动参数传入真实清单，检查 MP3/FLAC 下载保存、同大小损坏、HTTP 失败、重定向后最终 URL 不符、超出大小及取消后不落盘。它不模拟网络进度，也不替代配对真机的 WatchConnectivity 握手验证。仅测试模式接受 loopback，正式接收清单拒绝 loopback。

仅运行后台和进程恢复场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --background-only
```

这两个场景分别通过 `-lan-background-after` 调用真实的业务层前后台切换方法，验证它不会取消真实 HTTP 下载；以及在下载开始后用 `SIGKILL` 结束模拟器 App 进程，再以 `-lan-restore-events` 启动，验证系统下载任务恢复和日志保留。模拟切换单独写入带有 `simulated: true` 的 `Documents/lan-test-background.json`；它不改变真实 SwiftUI scene phase，也不能作为硬件息屏已经通过的证据。

仅 Debug 版本支持 `-lan-probe-folder LANProbe-<UUID>`：在手机前台等待配对手表可达后，将该已存在的非空测试目录通过真实局域网流程发送。普通启动不会触发；切入后台会取消等待。

真机验收可为手表 Debug 启动添加 `-lan-record-lifecycle`。该参数仅被动观察，不模拟前后台状态或网络：`Documents/lan-lifecycle-events.json` 记录真实 scene phase、接收终态、后台唤醒及完成时间，使用时间戳和会话/文件 ID 关联事件，不记录令牌；`Documents/lan-test-events.json` 同时记录真实接收事件。生命周期日志在重启时保留，接收事件日志在接受新一批歌曲时重置；普通启动不启用这些诊断写入。应结合真实息屏操作和日志时序验收，模拟器探针本身不作硬件结论。

## 真机对照测试

- 先用小 MP3 验证连接，再用较大 FLAC 观察实际吞吐量；分别用普通模式和局域网模式发送同一文件比较。
- 检查路由器是否开启访客网络或客户端隔离；连上相同名称的 Wi-Fi 不一定能互访。
- 在传输开始后让手表自然息屏、返回表盘并再次打开，检查最终落盘和保存回执；用真实生命周期日志核对后台状态与终态先后。
- 充电及满电接电时测试四个重力方向、左侧表冠、平放保留和方向按钮，拔电后检查恢复竖屏；完成或取消后检查自动退出接收页。
- 分别检查设备支持且开启 Always On、用户关闭 Always On 时的界面；低亮度和低更新频率属于系统行为，不能以接收页出现作为全程常亮的证据。
- 检查手机切后台、断网、单首取消、停止整批、失败后重试及手表空间不足；手动强退单独测试。
- 普通模式与局域网模式不要同时发送相同目标路径；应用也会阻止冲突。
- 模拟器可以验证 HTTP 收发与文件落盘，无法据此判断手表真实无线链路和速度。

## 官方接口依据

- [watchOS 低层网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：本实现使用允许的 HTTP/HTTPS URLSession，不在手表上使用普通 TCP 或 Bonjour。
- [watchOS 网络路由](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)：请求可能经过 iPhone 代理、Wi-Fi 或蜂窝网络。
- [URLSession 下载进度](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didwritedata:totalbyteswritten:totalbytesexpectedtowrite:))：进度使用真实接收字节。
- [watchOS 后台请求](https://developer.apple.com/documentation/watchos-apps/making-background-requests)：后台会话可跨 App 进程结束继续，结果交付可能延后。
- [WatchKit URLSession 后台任务](https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask)：用相同会话标识重新关联，在委托事件处理完成后结束后台任务。
- [后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)：系统独立进程下载、相同标识恢复及整批提交任务。
- [后台配置与手动强退](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))：用户强退与系统正常结束进程的后台行为有区别。
- [重定向回调范围](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))：后台会话自动跟随重定向。
- [Always On 界面](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)：设备与用户设置影响显示，系统会降低亮度和更新频率。
