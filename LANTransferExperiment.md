# 局域网传输实验

当前开发分支：`experiment/iphone-background-transfer`。本轮以已合并局域网实验的 `main`（`54c6da9`）为基线，恢复双端前台传输，保留移除跨设备播放状态同步和互控的改动。手机持续后台任务、手表显示活动请求、固定分段断点及源发送进度实验均已撤回；此前验证只作为历史记录。

## 使用

1. 用此分支构建并安装 iPhone 与 Apple Watch 两端实验 App。
2. 两台设备连接能互相访问的同一 Wi-Fi 局域网，在两端打开 App，并保持两端 active。
3. 从手机歌曲菜单或目录发送音乐，也可在音乐库或目录内多选、全选后批量发送、移动或删除手机副本；移动不覆盖同名目标，部分失败汇总提示。所有新发送和重试均使用局域网，无需选择传输方式。
4. 手机“传输”页通过“进行中”和“已传输”两个标签展示记录，支持多选和全选；传输时显示接收进度、估算速度和剩余时间。手表自动进入专用全屏接收页，显示百分比、歌曲、批次及取消按钮。
5. 等待“已保存到手表”，记录才会进入“已传输”。接收完成或取消后，手表自动退出接收页并返回音乐库。失败记录可直接“重试”，仍使用局域网。

发送前先查询手表实际库存，以目录、文件名、大小和 SHA-256 判断目标内容是否相同；相同文件和同路径已有未结束任务均跳过，不重复加入队列，并用简短摘要反馈新增及跳过数量。手表指纹缓存独立于手机传输记录，清空手机历史仍可去重；旧文件首次查询时懒计算摘要，文件版本变化会使缓存失效，手表已删除或同名内容不同的文件可重新发送。

传输进行中可以继续从其他列表或目录添加歌曲。手机维护全局 FIFO 等待队列，一次选择超过 100 首时自动拆为每批最多 100 首；追加任务排在已有任务后，当前批全部得到终态确认后，下一批才与手表握手启动。追加时当前批继续运行。每批内仍逐首下载、校验和保存，当前项失败或取消后继续批内后续任务。

只有手机与手表两端 App 都 active 时才运行网络传输。手机前台发送时会暂时保持屏幕常亮，结束后恢复原设置；任一端进入 inactive 或 background，包括控制中心、锁屏或返回表盘，会自动暂停并保留队列。重新回到两端 App 的 active 状态后自动检查连接并继续，已保存歌曲由库存查询跳过，手动暂停项保持原暂停意图。短暂断连采用有节制的重试，不同时启动多份发送流程。

手机或手表进程重新启动后恢复持久队列和 FIFO，重新核对源文件版本及手表库存；不恢复旧手机服务凭据，未完成的单曲可能重新传输。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，当前界面不再提供普通传输入口或切换选项。

“进行中”按以下顺序派生显示，不修改持久化历史数组：正在传输或部分接收的任务（进度暂时停滞仍保留位置）、校验或等待确认、按加入顺序排队的任务、已暂停任务、失败及本地已更新的待处理记录。“已传输”只显示手表确认保存成功的记录，按发起时间从新到旧排列；到达 100% 但仍等待校验或保存回执的任务留在“进行中”。已取消记录从两个标签及其数量中排除，不会被当作已传输。重试入口不再区分传输方式。

“暂停 / 开始”共用一个按钮，多选时作用于所选任务，否则作用于全部可操作任务，包含手机本地等待项；校验保存阶段不暂停。全局暂停后，新追加项也以暂停状态入队。更多菜单中的“清除所选”“清除全部任务”会先取消相关任务再移除记录，“已传输”可清除成功记录。清除不删除两端已保存的音乐，也不撤销已完成的保存。两个标签的布局截图为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)，验证结果单独记录在 `Verification.md`。

## 暂停与继续

已提交到手表的暂停、继续需实时可达并返回确认；手机收到确认后才改变暂停状态，不可达或超时不会伪装成已经暂停。手表挂起对应系统下载任务，持久保存暂停状态；暂停时保留字节数与百分比，隐藏速度及预计时间。手机本地等待项可直接暂停、开始或清除；已进入校验保存的文件不暂停。

暂停当前歌曲会让出批内下载位置，手表可继续该批未暂停项；全部暂停时不启动等待项。恢复单项不抢占当前正在下载或保存的歌曲。当前批只要仍有暂停项未结束，手机后批便继续等待，不承诺跨批跳过所有已暂停项。批内保存结束、失败或取消后再选择下一项；恢复时优先处理已经完整下载的暂存文件和已有部分下载，再处理尚未开始的等待项。

自动暂停与手动暂停分别记录。生命周期或连接变化导致的暂停可在条件恢复后自动继续；用户明确暂停的歌曲及全局暂停不因回前台、重连或进程重建而自行开始。清除会使旧预检和迟到消息失效，不会重新建立已移除的任务。

手机源服务仍仅供双端前台传输，本轮有效期最长 1 小时。暂停不会无限延长会话；过期或源会话结束后重新握手，不保证跨新会话恢复未完成单曲的字节断点。升级前遗留的普通 WatchConnectivity 任务不能使用此暂停能力，可取消后从音乐库重新发送，界面不显示虚假的暂停状态。

手机与手表各自保留本地播放器、后台音频及系统锁屏/耳机控制，不再交换播放状态或向另一台设备发送播放控制指令。WatchConnectivity 继续用于传输清单、库存、暂停/恢复确认及保存回执。

## 手表显示方向与电量

充电或满电仍接电时，整个手表 App 默认通过 CoreMotion 读取重力，识别竖屏、左右横屏和倒置四个方向，音乐库、播放器及接收页共用同一显示方向；左侧表冠设置会先做坐标修正。平放时重力无法确定屏幕内的旋转方向，运动数据不可用时也不推测方向，均保留上一个稳定方向。斜角和短暂抖动不会立即触发旋转，需连续三个明确同向样本才切换。

旋转完全自动，不提供旋转设置按钮。检测到拔电后固定回到佩戴时的竖屏并停止 CoreMotion；进入后台也停止方向采样，回到前台时重新读取充电状态。方向与电量监控由 App 统一管理，切换音乐库、播放器或接收页不会重置方向。

普通使用和传输时，App 左上角都在系统时间同一顶部区域显示手表电量百分比，充电时同时显示充电状态；无法读取电量时显示未知状态，不用 0% 代替。电量和系统时间所在的顶部区域保留屏幕坐标，内容旋转时不会遮挡这一区域。

返回和关闭操作位于内容页头，与顶部电量区域分开；系统键盘和系统确认弹窗沿用 watchOS 原生呈现。

自动旋转和电量显示不改变系统屏幕策略，本轮不请求额外显示活动。[Always On](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state) 由设备能力和用户设置决定，系统仍会降低亮度和界面更新频率，并可能返回表盘。生命周期转为 inactive 或 background 时自动暂停传输，回到 active 后再继续。

## 实现与范围

- 手机使用 Network.framework 临时开启 HTTP 文件服务，仅选择 Wi-Fi 接口，使用随机端口。
- 地址限定私有 IPv4（当前枚举 iPhone 的 `en0`）；IPv6-only、非私有地址和蜂窝网络不在本轮范围内。
- 双方通过配对设备的 WatchConnectivity 交换短期清单、前台状态与接收进度，手表持久保存整批等待队列，用无固定标识的 `URLSessionConfiguration.ephemeral` 逐首创建和运行下载任务，当前文件校验保存后才启动下一首。任一端非 active 时暂停网络调度；新会话不会跨进程关联旧下载。
- 手机自动拆为每批最多 100 首，批次清单仍有 55 KB 上限；手机源服务和清单有效期最长 1 小时，完成、停止或过期时关闭监听并清除手机内存中的令牌。单个请求无响应时有超时处理。
- 服务仅允许凭会话令牌读取清单内 UUID 对应的音频；拒绝目录浏览、任意路径和无效请求。音频按 64 KB 分块发送，不整体载入内存。
- 普通会话在 HTTP 重定向委托中返回 `nil` 拒绝跳转。接收器保存前仍严格验证最终响应 URL：协议、主机、端口和文件 UUID 路径必须匹配清单端点，且无查询、片段或用户信息；不符即拒绝保存。
- 手表验证完整字节数、SHA-256、系统音频解码和可用空间，原子写入成功后才回传保存成功。
- 进度来自手表实际接收字节。100% 后仍需等待校验和保存回执；速度与剩余时间为近期采样估计，连接或消息交付延迟可能使采样与回执延后。
- 取消与原子保存有明确顺序：保存已完成时，随后到达的取消请求不能撤销保存；手机以严格绑定该文件/会话的成功回执修正最终状态。
- 为恢复队列身份和重新握手，清单及令牌保存在手表 `Application Support/LANBackground-v2/transfer.json`，目录排除备份，并使用 `completeUntilFirstUserAuthentication` 文件保护；这不代表恢复旧网络任务，新下载等待手机提供新清单。令牌不写进正式日志或用户传输记录。实验使用本地 HTTP，未提供 TLS 加密；最终 URL 和 SHA-256 校验用于拒绝错误保存，不提供令牌传输保密性，应在可信局域网使用。

“局域网”表示传输端点与协议，**不代表已经强制手表直接使用 Wi-Fi 无线电**。watchOS 仍可能通过配对手机代理请求，实际链路由系统管理。本实验验证可用性，不预设提速倍数。

## 前台暂停与恢复

手机把已接受歌曲的 FIFO、当前批尾部、后续等待项和暂停意图持久保存。进入 inactive/background 时自动暂停并关闭不再适用的临时源，回 active 后重新检查对端状态及库存；进程重建时也重新验证源文件身份，内容已经变化时要求重新发送，仅元数据变化而摘要相同则更新版本并继续。旧端口和令牌不会从手机队列中恢复，已保存的歌曲不会重复排队。

手表恢复持久清单后，在 active 状态发送 ready，手机检查库存并提供新清单，再用普通临时会话重新下载未完成歌曲；不会跨进程关联旧下载。完整暂存文件也仅在 active 时校验和原子提交，非 active 时不启动保存；暂停前已经完成的原子提交及 stored 事实保留。当前文件保存后才考虑下一首，不并行恢复多首。不再建立固定 4 MiB 请求和跨源会话的应用级分段缓存，未完成单曲可能重传。

旧后台会话仅用于升级迁移：`makeLegacySession` 使用历史标识枚举并取消遗留下载，随后使会话失效，不接续新下载，也不触发非 active 时的校验提交。遗留后台事件完成处理后结束相应后台任务；普通 WatchConnectivity 后台任务分别处理。保存、失败和取消的终态先持久写入回执队列，待 WatchConnectivity 激活后交给系统发送，再清除队列条目；进程重建或回执延迟不会直接丢失终态。

自动暂停不把未完成项改成失败，也不删除源音乐；手动暂停的任务不会被自动恢复覆盖。连接短暂不可达时保留队列并有节制地重试，重试不打断已经恢复的会话，也不新建并行源。手动强退后由用户重新打开两端 App，才重新核对和恢复；不承诺任一端不 active 时继续传输。

## 自动验证

```sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-memory-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-lan-background-tests.sh
Tests/run-lan-inventory-tests.sh
Tests/run-transfer-source-version-tests.sh
Tests/run-transfer-tests.sh
Tests/run-transfer-list-tests.sh
Tests/run-watch-orientation-tests.sh
```

库存与指纹缓存测试可在 iPhone 模拟器使用真实文件系统运行：

```sh
Tests/run-lan-inventory-tests.sh IPHONE_SIMULATOR_UDID
```

文件版本测试使用真实临时文件，覆盖文件内容变化、同大小写入并恢复 mtime、原子替换、删除与符号链接拒绝；这些测试不播放音乐。具体运行结果见 `Verification.md`。

先以 Xcode 默认模拟器签名构建 Debug 并启动一个 watchOS 模拟器，再运行真实 HTTP 下载探针：

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

仅运行前台暂停、恢复和进程重建场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --foreground-only
```

生命周期场景按当前“非 active 自动暂停、回 active 自动恢复”的规则检查。`--background-only` 和 `--disconnect-resume-only` 均兼容映射到 `--foreground-only`，不证明后台继续下载或系统 Range 自动续传。模拟切换不改变真实 SwiftUI scene phase，不能作为硬件锁屏操作的证据。

仅运行真实 HTTP 暂停、继续及暂停后取消场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --pause-only
```

将最后一项参数改为 `--range-only` 可检查合法 HTTP 206、畸形 Content-Range 和不完整尾片段。206 仅在范围总大小与清单一致、终点为文件末尾时准入，最终仍须通过完整文件大小、SHA-256 和授权地址校验；该组仅验证完整性规则，不表示跨进程或后台断点恢复。

仅运行逐首传输和队列推进场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --serial-only
```

该组检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度；整批清单仍持久保存，但不预先并行启动系统下载。手机发送队列探针另检查真实 PhoneLibrary 的去重、追加、100 首及清单字节预算分批、等待项控制与迟到响应隔离；其中 Watch 消息由测试端注入，不替代无线链路验收。

批量文件、发送队列和前台恢复探针在已启动的模拟器运行，不播放声音：

```sh
Tests/run-phone-bulk-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-send-queue-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-foreground-queue-probe.sh IPHONE_SIMULATOR_UDID
```

批量探针对唯一测试目录执行文件变更，并还原传输索引及本次初始化的空目录。前台恢复探针使用真实文件和 PhoneLibrary 持久化，注入对端消息检查 inactive/background 暂停、恢复顺序、手动暂停及迟到消息隔离；它不代表真实设备生命周期或无线连接验收。

仅 Debug 版本支持 `-lan-probe-folder LANProbe-<UUID>`：在手机前台等待配对手表可达后，将该已存在的非空测试目录通过真实局域网流程发送。普通启动不会触发；切入后台会取消等待。

真机验收可为手表 Debug 启动添加 `-lan-record-lifecycle`。该参数仅被动观察，不模拟前后台状态或网络：`Documents/lan-lifecycle-events.json` 记录真实 scene phase、接收终态、后台唤醒及完成时间，使用时间戳和会话/文件 ID 关联事件，不记录令牌；`Documents/lan-test-events.json` 同时记录真实接收事件。生命周期日志在重启时保留，接收事件日志在接受新一批歌曲时重置；普通启动不启用这些诊断写入。应结合真实息屏操作和日志时序验收，模拟器探针本身不作硬件结论。

## 真机对照测试

- 先用小 MP3 验证连接，再用较大 FLAC 观察实际吞吐量。当前所有新任务统一使用局域网；既有普通传输对照结果属于历史版本记录。如需开发对照，可检出仍有普通传输入口的旧提交单独测试，当前界面不能切换。
- 检查路由器是否开启访客网络或客户端隔离；连上相同名称的 Wi-Fi 不一定能互访。
- 开始传输后分别打开手机控制中心、锁屏或退后台，检查队列自动暂停；返回手机 App 后在手表也 active 时自动继续，已保存歌曲不重复发送。
- 让手表自然息屏或返回表盘，检查传输自动暂停；重新打开手表 App 后继续。两端重启后检查 FIFO 和库存恢复，未完成单曲允许重传。
- 在音乐库、播放器和接收页分别测试充电及满电接电时的四个重力方向、左侧表冠、平放保留；确认没有旋转设置按钮，拔电后固定恢复佩戴竖屏，完成或取消后自动退出接收页。
- 检查普通使用、传输和弹出 App 页面时左上角的电量与充电状态，核对与系统时间同高且不遮挡内容；覆盖未知电量、低电量及充电状态变化。
- 分别检查设备支持且开启 Always On、用户关闭 Always On 时的界面；低亮度和低更新频率属于系统行为，不能以接收页出现作为全程常亮的证据。
- 检查短暂断网、单首取消、停止整批、重试及手表空间不足；重连不能多开传输，清除后的迟到消息不能复活。手动强退单独测试，重新打开后才恢复。
- 检查音乐库与目录内多选、全选、移动冲突和删除手机副本，未成功的文件应保留并汇总错误。
- 检查“进行中”的下载、校验、排队、暂停和待处理顺序，以及“已传输”只收录成功保存记录；取消记录不显示在两个标签或计数中。多选控制只影响所选项，无选择时控制全部可操作项；清除前先停止对应任务，保存的音乐仍保留。
- 在真实可达和不可达状态分别测试暂停、开始与更多菜单清除；校验中的任务不应假报暂停，暂停不显示过期速度或预计时间。源会话过期后开始按新会话重发验收。
- 多选发送数首歌曲，检查始终逐首下载并在保存完成后推进；暂停全部时等待项不启动，恢复单项不抢占当前项，当前项失败或取消后可继续后续歌曲。
- 重复发送相同目录、清空手机已传输历史后再次发送，检查相同文件不重新入队；替换同名文件内容或删除手表副本后再次发送，检查该项可以重新传输。
- 当前目录仍在传输时追加另一目录，检查当前批不中断，追加项按全局顺序等待，超过 100 首自动分批；全局暂停时新增项也暂停，清除所选或全部会覆盖手机等待项。
- 两端分别检查本地播放、暂停、切歌及系统锁屏/耳机控制；另一端的播放状态不应改变，界面不再出现对端控制条。
- 升级前遗留的普通 WatchConnectivity 任务可能继续完成；检查其取消和保存回执兼容。遗留任务与新局域网任务的相同目标路径冲突仍会被阻止。
- 模拟器可以验证 HTTP 收发与文件落盘，无法据此判断手表真实无线链路和速度。

安装与真机测试继续由用户手动进行，不自动部署、启动或发送测试文件。可用 Release 构建，不为测试改写共享 Scheme；用户已有 Scheme 修改保持原样。真实操作和最终构建结果记录在 `Verification.md`，历史实验结果不视为本轮已通过。

## 官方接口依据

- [watchOS 低层网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：本实现使用允许的 HTTP/HTTPS URLSession，不在手表上使用普通 TCP 或 Bonjour。
- [watchOS 网络路由](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)：请求可能经过 iPhone 代理、Wi-Fi 或蜂窝网络。
- [URLSession 下载进度](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didwritedata:totalbyteswritten:totalbytesexpectedtowrite:))：进度使用真实接收字节。
- [普通临时会话](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)：新下载使用临时配置，不使用后台会话标识。
- [WatchKit URLSession 后台任务](https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask)：本轮仅处理升级遗留后台会话的取消与完成，不用其恢复新下载。
- [重定向委托](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))：普通会话可通过返回 `nil` 拒绝重定向，最终端点仍独立校验。
- [Always On 界面](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)：设备与用户设置影响显示，系统会降低亮度和更新频率。
