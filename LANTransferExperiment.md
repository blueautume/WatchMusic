# 局域网传输实验

分支：`experiment/iphone-background-transfer`，从已合并局域网实验的 `main`（`54c6da9`）派生。原 `experiment/lan-transfer` 为上一轮实验记录；本分支增加手机后台任务和跨源会话断点恢复，并移除两端之间的播放状态同步与控制。

## 使用

1. 用此分支构建并安装 iPhone 与 Apple Watch 两端实验 App。
2. 两台设备连接能互相访问的同一 Wi-Fi 局域网，在两端打开 App。
3. 从手机歌曲菜单或目录发送音乐，也可在音乐库或目录内多选、全选后批量发送、移动或删除手机副本；移动不覆盖同名目标，部分失败汇总提示。所有新发送和重试均使用局域网，无需选择传输方式。
4. 手机“传输”页通过“进行中”和“已传输”两个标签展示记录，支持多选和全选；传输时显示接收进度、估算速度和剩余时间。手表自动进入专用全屏接收页，显示百分比、歌曲、批次及取消按钮。
5. 等待“已保存到手表”，记录才会进入“已传输”。接收完成或取消后，手表自动退出接收页并返回音乐库。失败记录可直接“重试”，仍使用局域网。

发送前先查询手表实际库存，以目录、文件名、大小和 SHA-256 判断目标内容是否相同；相同文件和同路径已有未结束任务均跳过，不重复加入队列，并用简短摘要反馈新增及跳过数量。手表指纹缓存独立于手机传输记录，清空手机历史仍可去重；旧文件首次查询时懒计算摘要，文件版本变化会使缓存失效，手表已删除或同名内容不同的文件可重新发送。

传输进行中可以继续从其他列表或目录添加歌曲。手机维护全局 FIFO 等待队列，一次选择超过 100 首时自动拆为每批最多 100 首；追加任务排在已有任务后，当前批全部得到终态确认后，下一批才与手表握手启动。追加时当前批继续运行。每批内仍逐首下载、校验和保存，当前项失败或取消后继续批内后续任务。

iOS 26 及以上在手机前台点“发送”或“开始”时，为整个队列申请一个 `BGContinuedProcessingTask`；使用 `.fail` 策略，没有立即运行条件时不把任务留给系统择机排程。提交请求不等于获得资格，必须收到系统实际启动回调后，手机源服务才能在后台继续执行并接续后续批次。前台传输会暂时保持手机屏幕常亮，结束后恢复原设置。系统原生进度以真实接收字节和手表最终保存回执推进，不会在仅收到全部字节时提前完成。

未获得后台资格或旧版 iOS 进入后台时，手机持久保存队列并显示“等待恢复”，回到前台可继续前台传输；重新点“开始”才能申请新后台任务。系统取消或任务资格过期会保留等待队列，但不自动重启，需用户明确点“开始”。全新进程启动后恢复 FIFO 和源文件版本校验，建立新的手机服务；不保存或恢复旧手机端口、源令牌。

手表在打开 App 并开始接收后可自然息屏或返回表盘，应用不会因此取消系统下载。系统可能延迟交付进度和保存结果，不保证息屏期间实时显示速度和预计时间。手机与手表后台均受资源、网络、电量和用户操作限制，不能保证无限运行；手动强退需单独测试并重新打开恢复。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，当前界面不再提供普通传输入口或切换选项。

“进行中”按以下顺序派生显示，不修改持久化历史数组：正在传输或部分接收的任务（进度暂时停滞仍保留位置）、校验或等待确认、按加入顺序排队的任务、已暂停任务、失败及本地已更新的待处理记录。“已传输”只显示手表确认保存成功的记录，按发起时间从新到旧排列；到达 100% 但仍等待校验或保存回执的任务留在“进行中”。已取消记录从两个标签及其数量中排除，不会被当作已传输。重试入口不再区分传输方式。

“暂停 / 开始”共用一个按钮，多选时作用于所选任务，否则作用于全部可操作任务，包含手机本地等待项；校验保存阶段不暂停。全局暂停后，新追加项也以暂停状态入队。更多菜单中的“清除所选”“清除全部任务”会先取消相关任务再移除记录，“已传输”可清除成功记录。清除不删除两端已保存的音乐，也不撤销已完成的保存。两个标签的布局截图为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)，验证结果单独记录在 `Verification.md`。

## 暂停与继续

已提交到手表的暂停、继续需实时可达并返回确认；手机收到确认后才改变暂停状态，不可达或超时不会伪装成已经暂停。手表挂起对应系统下载任务，持久保存暂停状态；暂停时保留字节数与百分比，隐藏速度及预计时间。手机本地等待项可直接暂停、开始或清除；已进入校验保存的文件不暂停。

暂停当前歌曲会让出批内下载位置，手表可继续该批未暂停项；全部暂停时不启动等待项。恢复单项不抢占当前正在下载或保存的歌曲。当前批只要仍有暂停项未结束，手机后批便继续等待，不承诺跨批跳过所有已暂停项。批内保存结束、失败或取消后再选择下一项；恢复时优先处理已经完整下载的暂存文件和已有部分下载，再处理尚未开始的等待项。

手机源服务可在持有实际后台资格时继续运行，本轮有效期仍最长 1 小时。暂停不会无限延长会话；过期或源会话结束后，“开始”会停止旧服务并建立新会话，相同路径、大小和 SHA-256 的文件可复用手表已提交的分段前缀。升级前遗留的普通 WatchConnectivity 任务不能使用此暂停能力，可取消后从音乐库重新发送，界面不显示虚假的暂停状态。

手机与手表各自保留本地播放器、后台音频和系统锁屏/耳机控制；不再交换播放状态或向另一台设备发送播放控制指令。WatchConnectivity 继续用于传输清单、库存查询、控制确认和保存回执。

## 手表显示方向与电量

充电或满电仍接电时，整个手表 App 默认通过 CoreMotion 读取重力，识别竖屏、左右横屏和倒置四个方向，音乐库、播放器及接收页共用同一显示方向；左侧表冠设置会先做坐标修正。平放时重力无法确定屏幕内的旋转方向，运动数据不可用时也不推测方向，均保留上一个稳定方向。斜角和短暂抖动不会立即触发旋转，需连续三个明确同向样本才切换。

旋转完全自动，不提供旋转设置按钮。检测到拔电后固定回到佩戴时的竖屏并停止 CoreMotion；进入后台也停止方向采样，回到前台时重新读取充电状态。方向与电量监控由 App 统一管理，切换音乐库、播放器或接收页不会重置方向。

普通使用和传输时，App 左上角都在系统时间同一顶部区域显示手表电量百分比，充电时同时显示充电状态；无法读取电量时显示未知状态，不用 0% 代替。电量和系统时间所在的顶部区域保留屏幕坐标，内容旋转时不会遮挡这一区域。

返回和关闭操作位于内容页头，与顶部电量区域分开；系统键盘和系统确认弹窗沿用 watchOS 原生呈现。

App 仍显示时，正在接收或正在充电（含满电接电）会通过公开 `ProcessInfo.beginActivity` 持有 `.idleDisplaySleepDisabled` 请求；条件不再满足即结束，离开 App 会释放。该接口只向系统提出活动提示，Debug 的 `lan-display-activity.json` 仅能证明请求始末，不能证明实际屏幕保持亮。自动旋转和电量显示本身不改变系统屏幕策略。watchOS 公共接口不能保证屏幕持续全亮到传输结束，充电也没有通用的保持全亮 API。[Always On](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state) 由设备能力和用户设置决定，系统仍会降低亮度和界面更新频率，并可能返回表盘。接收页适配低亮度状态，底层继续保留此前的系统后台下载及进程恢复，屏幕状态不会主动取消网络任务。

## 实现与范围

- 手机使用 Network.framework 临时开启 HTTP 文件服务，仅选择 Wi-Fi 接口，使用随机端口。
- 地址限定私有 IPv4（当前枚举 iPhone 的 `en0`）；IPv6-only、非私有地址和蜂窝网络不在本轮范围内。
- 双方通过配对设备的 WatchConnectivity 交换短期清单与接收进度，手表持久保存整批等待队列，用固定标识的后台会话串行创建和运行 `URLSessionDownloadTask`。每个 HTTP 请求最长 4 MiB，同一首各段顺序提交，整首文件校验保存后才启动下一首。
- 手机自动拆为每批最多 100 首，批次清单仍有 55 KB 上限；手机源服务和清单有效期最长 1 小时，完成、停止或过期时关闭监听并清除手机内存中的令牌。单个请求无响应时有超时处理。
- 服务仅允许凭会话令牌读取清单内 UUID 对应的音频；拒绝目录浏览、任意路径和无效请求。音频按 64 KB 分块发送，不整体载入内存。
- 系统后台会话会自动跟随 HTTP 重定向，不能依赖重定向 delegate 阻止。接收器保存前严格验证最终响应 URL：协议、主机、端口和文件 UUID 路径必须匹配清单端点，且无查询、片段或用户信息；不符即拒绝保存。这只验证最终端点，不保证中间跳转未发生。
- 手表验证完整字节数、SHA-256、系统音频解码和可用空间，原子写入成功后才回传保存成功。
- 歌曲行进度来自手表实际接收字节；手机系统任务另外参考 HTTP 源成功处理的发送偏移，以便手表暂不可达时仍报告真实源端工作，重复 Range 只取最大偏移、不累计，字节 100% 后仍需等待校验和保存回执；系统后台任务进度另外包含最终保存阶段，收到回执前不达到 100%。速度与剩余时间为近期采样估计，系统后台调度可能让这些采样和回执延后。
- 取消与原子保存有明确顺序：保存已完成时，随后到达的取消请求不能撤销保存；手机以严格绑定该文件/会话的成功回执修正最终状态。
- 为跨进程恢复下载，清单及令牌保存在手表 `Application Support/LANBackground-v2/transfer.json`，恢复目录排除备份，并使用 `completeUntilFirstUserAuthentication` 文件保护。令牌不写进正式日志或用户传输记录。实验使用本地 HTTP，未提供 TLS 加密；最终 URL 和 SHA-256 校验用于拒绝错误保存，不提供令牌传输保密性，应在可信局域网使用。

“局域网”表示传输端点与协议，**不代表已经强制手表直接使用 Wi-Fi 无线电**。watchOS 仍可能通过配对手机代理请求，实际链路由系统管理。本实验验证可用性，不预设提速倍数。

## 后台与恢复

手机把已接受的歌曲、当前批次和后续等待项的 FIFO 顺序以及全局暂停意图持久保存；源服务凭据不写入该队列。新进程恢复时检查实际源文件版本，已变化的文件要求重新发送，相同文件用新源会话继续，并重新查询手表库存以跳过已保存歌曲。系统取消或过期任务不会通过返回前台或重新连接自动申请新的后台任务。

手表当前分段的网络下载由系统独立进程执行，其余歌曲作为持久化等待队列保存。应用启动时先恢复清单，再以同一后台会话标识重新关联系统任务。每段验证范围、长度与最终端点后，才原子推进持久断点边界；中断中的未完整分段可能重新下载。全部分段拼成整首后，在受保护暂存目录完成完整大小、SHA-256 和音频校验，原子保存后再推进下一首。升级前遗留的并发任务恢复时收敛为一个运行项，其余下载挂起等待；不会为恢复队列同时启动多首。清单过期后不再发起新请求，已经下载完整的文件仍可继续校验保存。

断点以标准化的目标目录/文件名、完整大小和 SHA-256 绑定，不绑定会变化的源会话、文件 UUID、端口或令牌，因此新清单仍可复用相同内容的已提交前缀。失败及为恢复而保留的停止会保留断点；用户普通取消或停止清理对应本批断点，已经保存的音乐不受影响。缓存使用匿名 UUID 文件名，并排除备份和启用文件保护；旧项按 7 天、16 项及 8 GiB 预算淘汰，当前活动前缀不会为淘汰其他项而丢弃。

系统通过 `WKURLSessionRefreshBackgroundTask` 交付后台事件。应用等待本轮 URLSession 事件处理和已完成文件的校验保存结束，再完成该次后台唤醒任务，不用尚未完成的整批队列阻塞这一轮唤醒。普通 WatchConnectivity 后台任务分别处理。保存、失败和取消的终态先持久写入回执队列，待 WatchConnectivity 激活后交给系统发送，再清除队列条目；进程重建或回执延迟不会直接丢失终态。

系统是否立即运行下载、何时唤醒应用和交付进度/结果仍受网络、电量和资源调度影响，后台下一段及下一首也可能等待系统交付结果。手机只有实际获得持续任务资格时才能维持后台 HTTP 源，源服务有效期仍最长一小时；短暂的前后台交接时间不等于持续资格。手动从系统界面强退可能取消后台工作，不能等同于正常息屏或系统回收进程，需要重新打开 App 恢复；不承诺无限后台。

## 自动验证

```sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-memory-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-lan-background-tests.sh
Tests/run-lan-continued-processing-tests.sh
Tests/run-lan-partial-tests.sh
Tests/run-lan-inventory-tests.sh
Tests/run-transfer-source-version-tests.sh
Tests/run-transfer-tests.sh
Tests/run-transfer-list-tests.sh
Tests/run-watch-orientation-tests.sh
Tests/run-watch-display-activity-tests.sh
```

库存与指纹缓存测试可在 iPhone 模拟器使用真实文件系统运行：

```sh
Tests/run-lan-inventory-tests.sh IPHONE_SIMULATOR_UDID
```

文件版本测试使用真实临时文件，覆盖文件内容变化、同大小写入并恢复 mtime、原子替换、删除与符号链接拒绝；这些测试不播放音乐。具体运行结果见 `Verification.md`。

先以 Xcode 默认模拟器签名构建 Debug 并启动一个 watchOS 模拟器，再运行真实 HTTP 下载探针。不要禁用 `CODE_SIGNING_ALLOWED`：后台下载守护进程需要构建时生成的应用标识 entitlement，单独补一个无 entitlement 的临时签名不足以运行：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app
```

探针启动本机 HTTP 服务，通过仅 Debug 可用的 `-lan-offer-file` 启动参数传入真实清单，检查 MP3/FLAC 下载保存、同大小损坏、HTTP 失败、重定向后最终 URL 不符、超出大小及取消后不落盘。它不模拟网络进度，也不替代配对真机的 WatchConnectivity 握手验证。仅测试模式接受 loopback，正式接收清单拒绝 loopback。

大文件准备内存探针也可运行在 iPhone 模拟器：

```sh
Tests/run-lan-memory-probe.sh IPHONE_SIMULATOR_UDID
```

它通过生产 `start → prepare → digest` 处理 3×512 MiB 稀疏文件，检查独立 SHA-256、实际进程内存和活跃读取中的取消。摘要和发送每 64 KiB 及时释放 Foundation 临时读取对象；两端摘要共用同一实现，取消检查仍逐块执行。探针仅验证准备路径，不解码或播放稀疏文件，也不代表完整 App 或真机的总内存。

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

将最后一项参数改为 `--range-only` 可检查合法 HTTP 206、畸形 Content-Range 和不完整响应；`--disconnect-resume-only` 检查暂停期间 TCP 断开后的 Range 恢复流程。当前每个请求范围最长 4 MiB，206 总大小必须与清单一致，范围和临时文件长度必须覆盖当前请求的完整分段；不要求每段终点都是整首文件末尾。最终整首仍须通过大小、SHA-256 和授权端点校验。

仅运行逐首传输和队列推进场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --serial-only
```

该组检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度；整批清单仍持久保存，但不预先并行启动系统下载。手机发送队列探针另检查真实 PhoneLibrary 的去重、追加、100 首及清单字节预算分批、等待项控制与迟到响应隔离；其中 Watch 消息由测试端注入，不替代无线链路验收。

批量文件、发送队列与手机后台状态探针在已启动的模拟器运行，不播放声音：

```sh
Tests/run-phone-bulk-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-send-queue-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-background-queue-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-lan-continued-processing-tests.sh IPHONE_SIMULATOR_UDID
```

批量探针对唯一测试目录执行文件变更，并还原传输索引及本次初始化的空目录。手机后台队列探针通过显式的授权/过期注入，检查业务状态、跨批接续、等待恢复和队列重建；持续任务探针检查申请不等于授权、迟到回调隔离及进度边界，不会请求真实系统后台资格。分段缓存测试使用临时文件覆盖提交、重建、内容身份变化及跨会话复用。上述探针不替代真实设备切后台、锁屏后的执行资格及无线链路验收，实际结果记录于 `Verification.md`。

仅 Debug 版本支持 `-lan-probe-folder LANProbe-<UUID>`：在手机前台等待配对手表可达后，将该已存在的非空测试目录通过真实局域网流程发送。普通启动不会触发；切入后台会取消等待。

真机验收可为两端 Debug 启动添加 `-lan-record-lifecycle`。手机的 `Documents/lan-phone-lifecycle.json` 记录真实 scene phase、系统持续任务资格和传输事件，不包含源服务令牌。该参数仅被动观察，不模拟前后台状态或网络：`Documents/lan-lifecycle-events.json` 记录真实 scene phase、接收终态、后台唤醒及完成时间，使用时间戳和会话/文件 ID 关联事件，不记录令牌；`Documents/lan-test-events.json` 同时记录真实接收事件。生命周期日志在重启时保留，接收事件日志在接受新一批歌曲时重置；普通启动不启用这些诊断写入。应结合真实息屏操作和日志时序验收，模拟器探针本身不作硬件结论。

## 真机对照测试

- 先用小 MP3 验证连接，再用较大 FLAC 观察实际吞吐量。当前所有新任务统一使用局域网；既有普通传输对照结果属于历史版本记录。如需开发对照，可检出仍有普通传输入口的旧提交单独测试，当前界面不能切换。
- 检查路由器是否开启访客网络或客户端隔离；连上相同名称的 Wi-Fi 不一定能互访。
- 在传输开始后让手表自然息屏、返回表盘并再次打开，检查最终落盘和保存回执；用真实生命周期日志核对后台状态与终态先后。
- 在音乐库、播放器和接收页分别测试充电及满电接电时的四个重力方向、左侧表冠、平放保留；确认没有旋转设置按钮，拔电后固定恢复佩戴竖屏，完成或取消后自动退出接收页。
- 检查普通使用、传输和弹出 App 页面时左上角的电量与充电状态，核对与系统时间同高且不遮挡内容；覆盖未知电量、低电量及充电状态变化。
- 分别检查设备支持且开启 Always On、用户关闭 Always On 时的界面；低亮度和低更新频率属于系统行为，不能以接收页出现作为全程常亮的证据。
- 从主屏幕正常启动手机 App，脱离 Xcode 调试器发起传输；确认系统任务真正启动后切换 App、锁屏，检查进度、分段和跨批接续。未获后台资格及旧 iOS 应进入“等待恢复”，回前台继续前台传输。
- 在系统任务进度界面取消，确认队列保留且回前台不自动重启，明确点“开始”后才恢复。分别覆盖资格过期、断网、单首取消、停止整批、空间不足与全新进程重建；手动强退单独测试。
- 大文件至少接收一个完整分段后中断，用新会话重发，核对复用相同路径、大小和 SHA-256 的前缀；替换同名内容不应复用旧前缀。用户普通取消后该文件的断点应被清理。
- 检查音乐库与目录内多选、全选、移动冲突和删除手机副本，未成功的文件应保留并汇总错误。
- 检查“进行中”的下载、校验、排队、暂停和待处理顺序，以及“已传输”只收录成功保存记录；取消记录不显示在两个标签或计数中。多选控制只影响所选项，无选择时控制全部可操作项；清除前先停止对应任务，保存的音乐仍保留。
- 在真实可达和不可达状态分别测试暂停、开始与更多菜单清除；校验中的任务不应假报暂停，暂停不显示过期速度或预计时间。源会话过期后开始按新会话重发验收。
- 多选发送数首歌曲，检查始终逐首下载并在保存完成后推进；暂停全部时等待项不启动，恢复单项不抢占当前项，当前项失败或取消后可继续后续歌曲。
- 重复发送相同目录、清空手机已传输历史后再次发送，检查相同文件不重新入队；替换同名文件内容或删除手表副本后再次发送，检查该项可以重新传输。
- 当前目录仍在传输时追加另一目录，检查当前批不中断，追加项按全局顺序等待，超过 100 首自动分批；全局暂停时新增项也暂停，清除所选或全部会覆盖手机等待项。
- 分别检查手机与手表本地播放、暂停、切歌和系统锁屏/耳机控制；另一台设备的播放状态不应改变，界面不再出现对端控制条。
- 升级前遗留的普通 WatchConnectivity 任务可能继续完成；检查其取消和保存回执兼容。遗留任务与新局域网任务的相同目标路径冲突仍会被阻止。
- 模拟器可以验证 HTTP 收发与文件落盘，无法据此判断手表真实无线链路和速度。

## 官方接口依据

- [iOS 持续后台任务](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)：前台用户操作发起，可继续后台 CPU 和网络工作。
- [持续任务进度与终止](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)：必须上报真实进度，系统显示原生进度界面，用户或系统可以终止任务。
- [watchOS 低层网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：本实现使用允许的 HTTP/HTTPS URLSession，不在手表上使用普通 TCP 或 Bonjour。
- [watchOS 网络路由](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)：请求可能经过 iPhone 代理、Wi-Fi 或蜂窝网络。
- [URLSession 下载进度](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didwritedata:totalbyteswritten:totalbytesexpectedtowrite:))：进度使用真实接收字节。
- [watchOS 后台请求](https://developer.apple.com/documentation/watchos-apps/making-background-requests)：后台会话可跨 App 进程结束继续，结果交付可能延后。
- [WatchKit URLSession 后台任务](https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask)：用相同会话标识重新关联，在委托事件处理完成后结束后台任务。
- [后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)：系统独立进程下载及相同会话标识恢复；本实现由持久化队列逐首提交任务。
- [后台配置与手动强退](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))：用户强退与系统正常结束进程的后台行为有区别。
- [重定向回调范围](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))：后台会话自动跟随重定向。
- [Always On 界面](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)：设备与用户设置影响显示，系统会降低亮度和更新频率。
