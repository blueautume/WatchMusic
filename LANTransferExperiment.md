# 局域网传输实验

分支：`experiment/lan-transfer`，从 `main` 的 `3fd5c71` 派生。

## 使用

1. 用此分支构建并安装 iPhone 与 Apple Watch 两端实验 App。
2. 两台设备连接能互相访问的同一 Wi-Fi 局域网，在两端打开 App。
3. 从手机歌曲菜单或目录发送音乐，也可在音乐库或目录内多选、全选后批量发送、移动或删除手机副本；移动不覆盖同名目标，部分失败汇总提示。所有新发送和重试均使用局域网，无需选择传输方式。
4. 手机“传输”页通过“进行中”和“已传输”两个标签展示记录，支持多选和全选；传输时显示接收进度、估算速度和剩余时间。手表自动进入专用全屏接收页，显示百分比、歌曲、批次及取消按钮。
5. 等待“已保存到手表”，记录才会进入“已传输”。接收完成或取消后，手表自动退出接收页并返回音乐库。失败记录可直接“重试”，仍使用局域网。

歌曲按队列逐首串行传输：整批先持久保存为等待队列，同一时间只运行一首原生下载；当前歌曲完成下载、校验和保存后，再开始下一首。当前项失败或取消后继续后续任务，避免一首异常阻塞整批。

局域网传输期间手机 App 需保持前台，应用会暂时保持手机屏幕常亮，结束后恢复原设置；手机进入后台会停止源服务。手表在打开 App 并开始接收后可自然息屏或返回表盘，应用不会因此取消系统下载。系统可能延迟交付进度和保存结果，唤醒手表后才更新界面也属于后台调度范围；不保证息屏期间实时显示速度和预计时间。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，但当前界面不再提供普通传输入口或切换选项。

“进行中”按以下顺序派生显示，不修改持久化历史数组：正在传输或部分接收的任务（进度暂时停滞仍保留位置）、校验或等待确认、按加入顺序排队的任务、已暂停任务、失败及本地已更新的待处理记录。“已传输”只显示手表确认保存成功的记录，按发起时间从新到旧排列；到达 100% 但仍等待校验或保存回执的任务留在“进行中”。已取消记录从两个标签及其数量中排除，不会被当作已传输。重试入口不再区分传输方式。

“暂停 / 开始”共用一个按钮，多选时作用于所选任务，否则作用于全部可操作任务；校验保存阶段不暂停。更多菜单中的“清除所选”“清除全部任务”会先取消相关任务再移除记录，“已传输”可清除成功记录。清除不删除两端已保存的音乐，也不撤销已完成的保存。两个标签的布局截图为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)，验证结果单独记录在 `Verification.md`。

## 暂停与继续

运行中的暂停、继续需手表实时可达并返回确认；手机收到确认后才改变暂停状态，不可达或超时不会伪装成已经暂停。手表挂起对应系统下载任务，持久保存暂停状态；暂停时保留字节数与百分比，隐藏速度及预计时间。准备阶段暂停的项目通过清单以初始暂停状态提交，开始后才运行；已进入校验保存的文件不暂停。

暂停当前歌曲会让出下载位置，队列可继续未暂停项；全部暂停时不启动等待项。恢复单项会重新加入可运行队列，当前正在下载或保存的歌曲保持优先，不被抢占。保存结束、失败或取消后再选择下一项；恢复时优先处理已经完整下载的暂存文件和已有部分下载，再处理尚未开始的等待项。

手机源服务仍需保持前台，本轮有效期最长 1 小时。暂停不会无限延长会话；过期或源会话结束后，“开始”会在停止旧会话后重新发送，不保证跨会话断点续传。升级前遗留的普通 WatchConnectivity 任务不能使用此暂停能力，可取消后从音乐库重新发送，界面不显示虚假的暂停状态。

## 双向播放遥控

任一端有播放项目且两端 WatchConnectivity 实时可达时，另一端提供上一首、下一首、播放和暂停。只交换播放状态及指令，不交换歌名、路径、时长、进度或音频；播放所在地不变，本地播放器保持独立。不可达时禁用遥控，不把指令排队到重新连接后执行；重连会重新确认状态，重复或过期指令被隔离。

## 接收页与显示方向

充电或满电仍接电时，接收页在自动模式下通过 CoreMotion 读取重力，识别竖屏、左右横屏和倒置四个方向；左侧表冠设置会先做坐标修正。平放时重力无法确定屏幕内的旋转方向，页面会保留上一个稳定方向；斜角和短暂抖动也不会立即触发旋转，需连续三个明确同向样本才切换。

方向按钮提供“自动”和“旋转 90°”。手动旋转后保持所选方向，重新选择“自动”可恢复重力判断；平放时自动模式仍保留当前方向。检测到拔电后自动回到竖屏及自动模式。退出接收页时停止 CoreMotion，并恢复进入页面前的电量监控设置；进入后台也停止方向采样。

本页不实现“传输期间始终全亮”。watchOS 公共接口不能保证屏幕持续全亮到传输结束，充电也没有通用的保持全亮 API。[Always On](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state) 由设备能力和用户设置决定，系统仍会降低亮度和界面更新频率，并可能返回表盘。接收页适配低亮度状态，底层继续保留此前的系统后台下载及进程恢复，屏幕状态不会主动取消网络任务。

## 实现与范围

- 手机使用 Network.framework 临时开启 HTTP 文件服务，仅选择 Wi-Fi 接口，使用随机端口。
- 地址限定私有 IPv4（当前枚举 iPhone 的 `en0`）；IPv6-only、非私有地址和蜂窝网络不在本轮范围内。
- 双方通过配对设备的 WatchConnectivity 交换短期清单与接收进度，手表持久保存整批等待队列，用固定标识的后台会话逐首创建和运行 `URLSessionDownloadTask`，当前文件校验保存后才启动下一首。
- 每批最多 100 首，清单还有 55 KB 上限；手机源服务和清单有效期最长 1 小时，完成、停止或过期时关闭监听并清除手机内存中的令牌。单个请求无响应时有超时处理。
- 服务仅允许凭会话令牌读取清单内 UUID 对应的音频；拒绝目录浏览、任意路径和无效请求。音频按 64 KB 分块发送，不整体载入内存。
- 系统后台会话会自动跟随 HTTP 重定向，不能依赖重定向 delegate 阻止。接收器保存前严格验证最终响应 URL：协议、主机、端口和文件 UUID 路径必须匹配清单端点，且无查询、片段或用户信息；不符即拒绝保存。这只验证最终端点，不保证中间跳转未发生。
- 手表验证完整字节数、SHA-256、系统音频解码和可用空间，原子写入成功后才回传保存成功。
- 进度来自手表实际接收字节。100% 后仍需等待校验和保存回执；速度与剩余时间为近期采样估计，系统后台调度可能让这些采样和回执延后。
- 取消与原子保存有明确顺序：保存已完成时，随后到达的取消请求不能撤销保存；手机以严格绑定该文件/会话的成功回执修正最终状态。
- 为跨进程恢复下载，清单及令牌保存在手表 `Application Support/LANBackground-v2/transfer.json`，恢复目录排除备份，并使用 `completeUntilFirstUserAuthentication` 文件保护。令牌不写进正式日志或用户传输记录。实验使用本地 HTTP，未提供 TLS 加密；最终 URL 和 SHA-256 校验用于拒绝错误保存，不提供令牌传输保密性，应在可信局域网使用。

“局域网”表示传输端点与协议，**不代表已经强制手表直接使用 Wi-Fi 无线电**。watchOS 仍可能通过配对手机代理请求，实际链路由系统管理。本实验验证可用性，不预设提速倍数。

## 后台与恢复

手表当前歌曲的网络下载由系统独立进程执行，其余歌曲作为持久化等待队列保存。应用启动时先恢复清单，再以同一会话标识重新关联系统任务；已完整下载的文件先保存在受保护的暂存目录中，随后进行完整性校验与原子保存，再推进下一首。升级前遗留的并发任务恢复时会收敛为一个运行项，其余下载挂起等待；不会为恢复队列同时启动多首。清单过期后不再发起新请求，已经下载完整的文件仍可继续校验保存。

系统通过 `WKURLSessionRefreshBackgroundTask` 交付后台事件。应用等待本轮 URLSession 事件处理和已完成文件的校验保存结束，再完成该次后台唤醒任务，不用尚未完成的整批队列阻塞这一轮唤醒。普通 WatchConnectivity 后台任务分别处理。保存、失败和取消的终态先持久写入回执队列，待 WatchConnectivity 激活后交给系统发送，再清除队列条目；进程重建或回执延迟不会直接丢失终态。

系统是否立即运行下载、何时唤醒应用和交付进度/结果仍受网络、电量和资源调度影响，后台下一首的启动也可能等待系统交付上一首结果。手机源 App 仍需保持前台，源服务有效期最长一小时。手动从系统界面强退 App 可能使系统取消后台传输，不能等同于正常息屏或系统回收进程；这种情况需要重新打开 App 并从手机重试。

## 自动验证

```sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-lan-background-tests.sh
Tests/run-transfer-tests.sh
Tests/run-playback-control-tests.sh
Tests/run-transfer-list-tests.sh
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

仅运行真实 HTTP 暂停、继续及暂停后取消场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --pause-only
```

将最后一项参数改为 `--range-only` 可检查合法 HTTP 206、畸形 Content-Range 和不完整尾片段；`--disconnect-resume-only` 检查暂停期间 TCP 断开后系统重新发起 Range 请求的恢复流程。206 仅在范围总大小与清单一致、终点为文件末尾时准入，最终仍须通过完整文件大小、SHA-256 和授权地址校验。

仅运行逐首传输和队列推进场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --serial-only
```

该组检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度；整批清单仍持久保存，但不预先并行启动系统下载。

批量文件和播放遥控的原生集成探针在已启动的模拟器运行，不播放声音：

```sh
Tests/run-phone-bulk-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-playback-control-integration-probe.sh ios IPHONE_SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3"
Tests/run-playback-control-integration-probe.sh watchos WATCH_SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3"
```

批量探针对唯一测试目录执行文件变更，并还原传输索引及本次初始化的空目录；遥控探针检查真实暂停引擎上的指令路由。上述探针不替代真实配对设备上的连接、声音输出及远程控制验收。

仅 Debug 版本支持 `-lan-probe-folder LANProbe-<UUID>`：在手机前台等待配对手表可达后，将该已存在的非空测试目录通过真实局域网流程发送。普通启动不会触发；切入后台会取消等待。

真机验收可为手表 Debug 启动添加 `-lan-record-lifecycle`。该参数仅被动观察，不模拟前后台状态或网络：`Documents/lan-lifecycle-events.json` 记录真实 scene phase、接收终态、后台唤醒及完成时间，使用时间戳和会话/文件 ID 关联事件，不记录令牌；`Documents/lan-test-events.json` 同时记录真实接收事件。生命周期日志在重启时保留，接收事件日志在接受新一批歌曲时重置；普通启动不启用这些诊断写入。应结合真实息屏操作和日志时序验收，模拟器探针本身不作硬件结论。

## 真机对照测试

- 先用小 MP3 验证连接，再用较大 FLAC 观察实际吞吐量。当前所有新任务统一使用局域网；既有普通传输对照结果属于历史版本记录。如需开发对照，可检出仍有普通传输入口的旧提交单独测试，当前界面不能切换。
- 检查路由器是否开启访客网络或客户端隔离；连上相同名称的 Wi-Fi 不一定能互访。
- 在传输开始后让手表自然息屏、返回表盘并再次打开，检查最终落盘和保存回执；用真实生命周期日志核对后台状态与终态先后。
- 充电及满电接电时测试四个重力方向、左侧表冠、平放保留和方向按钮，拔电后检查恢复竖屏；完成或取消后检查自动退出接收页。
- 分别检查设备支持且开启 Always On、用户关闭 Always On 时的界面；低亮度和低更新频率属于系统行为，不能以接收页出现作为全程常亮的证据。
- 检查手机切后台、断网、单首取消、停止整批、失败后重试及手表空间不足；手动强退单独测试。
- 检查音乐库与目录内多选、全选、移动冲突和删除手机副本，未成功的文件应保留并汇总错误。
- 检查“进行中”的下载、校验、排队、暂停和待处理顺序，以及“已传输”只收录成功保存记录；取消记录不显示在两个标签或计数中。多选控制只影响所选项，无选择时控制全部可操作项；清除前先停止对应任务，保存的音乐仍保留。
- 在真实可达和不可达状态分别测试暂停、开始与更多菜单清除；校验中的任务不应假报暂停，暂停不显示过期速度或预计时间。源会话过期后开始按新会话重发验收。
- 多选发送数首歌曲，检查始终逐首下载并在保存完成后推进；暂停全部时等待项不启动，恢复单项不抢占当前项，当前项失败或取消后可继续后续歌曲。
- 分别由手机和手表本地开始播放，再在另一端操作上一首、下一首、暂停和播放；确认声音仍从原设备输出。断连时遥控禁用，重新连接后不能执行断连期间的旧指令。
- 升级前遗留的普通 WatchConnectivity 任务可能继续完成；检查其取消和保存回执兼容。遗留任务与新局域网任务的相同目标路径冲突仍会被阻止。
- 模拟器可以验证 HTTP 收发与文件落盘，无法据此判断手表真实无线链路和速度。

## 官方接口依据

- [watchOS 低层网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：本实现使用允许的 HTTP/HTTPS URLSession，不在手表上使用普通 TCP 或 Bonjour。
- [watchOS 网络路由](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)：请求可能经过 iPhone 代理、Wi-Fi 或蜂窝网络。
- [URLSession 下载进度](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didwritedata:totalbyteswritten:totalbytesexpectedtowrite:))：进度使用真实接收字节。
- [watchOS 后台请求](https://developer.apple.com/documentation/watchos-apps/making-background-requests)：后台会话可跨 App 进程结束继续，结果交付可能延后。
- [WatchKit URLSession 后台任务](https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask)：用相同会话标识重新关联，在委托事件处理完成后结束后台任务。
- [后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)：系统独立进程下载及相同会话标识恢复；本实现由持久化队列逐首提交任务。
- [后台配置与手动强退](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))：用户强退与系统正常结束进程的后台行为有区别。
- [重定向回调范围](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))：后台会话自动跟随重定向。
- [Always On 界面](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)：设备与用户设置影响显示，系统会降低亮度和更新频率。
