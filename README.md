# 随身音乐 Lab

基于原项目 `OfflineWatchPlayer` 建立的独立实验工程，用于开发简化版音乐播放器。本仓库包含运行所需的源码、工程、资源和测试，无需原项目目录。工程、scheme、应用沙盒和播放偏好均独立，可与原应用同时安装。

```sh
git clone git@github.com:blueautume/WatchMusic.git
cd WatchMusic
git switch experiment/iphone-background-transfer
open OfflineWatchPlayerLab.xcodeproj
```

当前实验分支为 `experiment/iphone-background-transfer`，从已合并局域网版本的 `main`（`54c6da9`）建立；主分支保留此次后台实验前的局域网版本。

## 打开与运行

打开 `OfflineWatchPlayerLab.xcodeproj`：

- iPhone scheme：`OfflineWatchPlayerLab`
- Apple Watch scheme：`OfflineWatchPlayerLabWatch`
- iPhone Bundle ID：`com.lihao.OfflineWatchPlayerLab`
- Watch Bundle ID：`com.lihao.OfflineWatchPlayerLab.watchkitapp`
- 桌面名称：`随身音乐 Lab`；版本 `0.1.0 (1)`

两个 target 继续使用原工程的开发团队与自动签名配置。真机运行时由 Xcode 为新 ID 创建相应描述文件。最低 iOS 17 / watchOS 10；手表双指互点下一首需要 watchOS 11 和支持该手势的设备。

## 实验范围

- 手机：音乐库和传输两个入口，导入 MP3 / FLAC，管理目录、本地播放和发送到手表。音乐库与目录内歌曲支持多选、全选及批量发送、移动、删除手机副本；同名目标不覆盖，部分失败会汇总提示。
- 手表：单页播放器，集中排列上一首、播放/暂停、下一首；队列和播放设置使用独立弹层。移除播放进度条和拖动手势。
- 移除歌词解析、显示、校准与传输，以及外部歌词/封面资源管理。歌曲内嵌标题、艺术家和封面继续显示。
- 两端独立本地播放，保留离线播放、后台音频、系统锁屏/耳机控制、播放恢复、模式、倍速、音量和睡眠定时；不再交换播放状态或控制另一台设备。
- 文件管理只修改所在设备的副本。

## 传输进度

所有新发送和重试均使用局域网传输：手机临时提供文件下载服务，手表通过 HTTP 接收并校验后保存。手机“传输”页分为“进行中”和“已传输”两个标签，无需选择传输方式。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，重试时统一走局域网。[实验说明与测试步骤](LANTransferExperiment.md)

发送前按目录、文件名、大小和 SHA-256 查询手表实际库存，内容相同的歌曲自动跳过，同路径已有未结束任务也不重复加入。指纹缓存独立于手机传输历史，清空记录后仍可去重；旧文件首次查询时计算摘要，文件版本变化会使缓存失效，手表已删除或内容不同的同名文件可重新发送。操作结果用简短摘要提示新增及跳过数量。

传输时可以继续从其他目录或列表添加歌曲，手机按加入顺序维护全局等待队列；一次选择超过 100 首时，App 自动拆为每批最多 100 首。追加任务排在已有任务之后，当前批收到终态确认后才启动下一批；每批内部由手表逐首下载，校验并保存完成后才开始下一首。当前项失败或取消后继续批内后续任务，追加时当前批继续运行。

“进行中”先显示正在传输或部分接收的任务，进度暂时停滞时保留优先位置；之后依次是校验或等待确认、按加入顺序排队、已暂停任务，以及可重试的失败和本地已更新记录。“已传输”仅包含手表确认保存成功的记录，按发起时间从新到旧排列。已取消记录不显示在两个标签中，也不计入标签数量。列表排序不改变持久化历史及每首歌曲的最新记录判断。

传输列表支持多选、全选。“暂停 / 开始”是同一个按钮：多选时作用于所选任务，否则作用于全部可操作任务，也覆盖手机本地等待项；校验保存阶段不暂停。全局暂停时，随后追加的任务也以暂停状态等待。更多菜单提供清除所选、清除全部任务或已传输记录。清除会先取消相关传输再移除记录，不删除两端已经保存的音乐，也不撤销已经完成的保存。

已提交到手表的暂停和继续需要实时可达并确认，不可达或未确认时不会假报暂停；手机本地等待项可直接暂停、开始和清除。暂停保留已接收大小及百分比，隐藏速度和剩余时间；恢复单项不抢占当前下载或保存。当前批仍有暂停项未结束时，后批继续等待，不承诺跨批越过这些暂停项。旧版普通传输任务不支持此暂停，可取消后从音乐库重新发送。

LAN 接收开始后，手表自动进入专用全屏接收页，显示进度、歌曲和批次，完成或取消后自动返回音乐库。充电或满电仍接电时，整个手表 App 默认通过 CoreMotion 重力识别四个显示方向，音乐库、播放器和接收页使用同一方向，并修正左侧表冠的坐标，无需旋转设置按钮。平放或运动数据不可用时保留最近稳定方向；检测到拔电后固定为佩戴时的竖屏，停止方向采样。进入后台也停止采样，回到前台时重新读取充电状态。

手表 App 左上角在系统时间同一顶部区域显示本机电量百分比，充电时显示充电状态，普通使用和传输期间均可查看；电量尚不可读时显示未知状态，不把它当成 0%。顶部信息保留屏幕坐标，不随内容旋转。

手表 App 仍显示时，正在接收音乐或正在充电（含满电接电）会持有 Foundation 的 `idleDisplaySleepDisabled` 活动请求；离开 App、拔电且没有接收任务时释放。该公开请求是系统提示，返回 token 不代表手表已经保持亮屏，实际显示行为仍需真机确认。Always On、亮度和刷新频率也受设备与用户设置影响；底层继续保留后台接收与恢复。

两台设备需连接能互相访问的同一 Wi-Fi。iOS 26 及以上在前台点“发送”或“开始”时申请 `BGContinuedProcessingTask`，整个传输队列共用一个后台任务，追加列表不另开任务。请求采用 `.fail` 策略，不等待系统择机排程；只有收到实际任务启动回调后，手机源服务才获得后台运行资格。前台传输时会暂时保持手机屏幕常亮，结束后恢复原设置；系统后台任务提供原生进度界面。

未取得后台资格或旧版 iOS 切入后台时，手机持久保存队列并进入“等待恢复”，回到前台可继续前台传输；重新点“开始”才会申请新的后台任务。系统取消或后台资格过期时同样保留队列，但需明确点“开始”，不会在返回 App 后自动重启已被用户取消的工作。全新进程启动后按原 FIFO 恢复等待项，并检查源文件版本；旧手机服务、端口和令牌不恢复，建立新源会话后再与手表核对库存。

手表使用系统后台下载会话，一次仅运行一个最长 4 MiB 的 HTTP 分段请求，完整分段验证后才提交为断点，再继续下一段；整首文件完成校验保存后才发送下一首。同一路径、大小及 SHA-256 的文件可跨新的会话 ID、文件 ID 和令牌复用已提交前缀；当前未完成分段可能重传。失败及为恢复而保留的停止会保留前缀，用户普通取消或停止会清理对应本批断点，已经保存的音乐不受影响。匿名断点缓存按 7 天及容量预算清理旧项。

手机源服务和清单每轮有效期最长 1 小时，暂停不会无限延长会话；结束或过期后需建立新会话。手机队列不持久保存源服务凭据；手表恢复清单中的令牌保存在受文件保护、排除备份的 Application Support 文件中，不进入正式日志或用户传输记录。后台会话可能跟随重定向，接收器在提交分段和保存整首前校验最终端点与内容。

手表在打开 App 并开始接收后可息屏；进程重启会重新关联系统任务、恢复等待队列和回执。系统可能延迟分段、下一首、进度和结果的交付，不保证后台实时速度或预计时间。网络、电量、资源与用户操作均可能结束后台运行；这套机制不保证无限后台，主动强退也不等同于普通切后台，需要重新打开 App 恢复。

局域网进度使用手表实际接收字节；已有普通传输任务仍通过 WatchConnectivity 原生 `WCSessionFileTransfer.progress` 读取进度，并用进度比例与源音频大小换算已传大小。速度与剩余时间由近期采样估算，界面以“约”标注。系统尚未开始发送、进度停滞或等待保存回执时不显示虚假的速度与时间。

歌曲行的接收进度达到 100% 只表示字节已接收；手表完成校验、原子写入并返回成功回执后，手机才显示“已保存到手表”。系统后台任务根据 HTTP 源实际成功处理的发送偏移和手表接收字节的较大值计算进度；重复 Range 不重复累计。歌曲行仍使用手表接收进度，系统任务仍包含最终校验保存阶段，收到保存回执前不会达到 100%。排队及保存时间不包含在发送剩余时间估算内。

## 验证

真机安装和操作由使用者手动完成；开发端提供构建结果与测试步骤，不自动安装、启动或发起真机传输。普通启动没有人工速度限制。仅 Debug 在显式设置 `LAN_PROBE_THROTTLE_BYTES_PER_SECOND` 环境变量时启用诊断限速；退出该测试进程后从主屏幕正常启动，或使用未设置此变量的 Xcode Run，即恢复无限速的正常流程。Release 不包含诊断限速代码。

```sh
xcodebuild -project OfflineWatchPlayerLab.xcodeproj -scheme OfflineWatchPlayerLab \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
Tests/run-playback-tests.sh
Tests/run-audio-format-tests.sh
Tests/run-audio-metadata-tests.sh
Tests/run-artwork-tests.sh
Tests/run-transfer-tests.sh
Tests/run-transfer-list-tests.sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-memory-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-lan-background-tests.sh
Tests/run-lan-continued-processing-tests.sh
Tests/run-lan-partial-tests.sh
Tests/run-lan-inventory-tests.sh
Tests/run-transfer-source-version-tests.sh
Tests/run-watch-orientation-tests.sh
Tests/run-watch-display-activity-tests.sh
```

库存去重测试检查实际文件查询及指纹缓存失效，文件版本测试覆盖同大小修改、保留 mtime 的写入、原子替换和删除。库存测试也可在已启动的 iPhone 模拟器运行：

```sh
Tests/run-lan-inventory-tests.sh IPHONE_SIMULATOR_UDID
```

大文件摘要内存探针通过真实生产准备路径读取 3×512 MiB 稀疏文件，并与独立 SHA-256 参考比较，同时采样进程内存与检查活跃读取中的取消。也可在已启动的 iPhone 模拟器运行：

```sh
Tests/run-lan-memory-probe.sh IPHONE_SIMULATOR_UDID
```

探针不会解码或播放这些稀疏文件；内存增长超过 160 MiB 时主动取消，避免测试本身耗尽内存。

播放器集成探针可在已启动的模拟器运行，不会播放声音：

```sh
Tests/run-player-integration-probe.sh ios SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.flac" \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3" "$PWD/Tests/Fixtures/EmbeddedResources.flac"
Tests/run-phone-bulk-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-send-queue-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-phone-background-queue-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-lan-continued-processing-tests.sh IPHONE_SIMULATOR_UDID
```

批量文件探针使用唯一测试目录执行真实移动和删除，并还原传输索引。发送队列探针使用真实文件摘要、PhoneLibrary 和 HTTP 源准备，Watch 消息由测试端注入，覆盖去重、追加、分批及取消隔离。手机后台队列与持续任务探针使用显式注入的授权/中断事件检查业务状态、持久化和恢复，不请求系统后台资格，也不代表锁屏或无线链路验收。分段缓存测试使用真实临时文件检查前缀提交与跨会话复用，具体结果见 `Verification.md`。

手表 LAN 探针的后台与进程恢复场景：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --background-only
```

暂停、继续及暂停后取消场景使用同一探针：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --pause-only
```

同一下载探针的 `--range-only` 验证 HTTP 206 范围响应校验；`--disconnect-resume-only` 验证暂停中断开 TCP 后的 Range 恢复。当前按最长 4 MiB 的请求范围校验各段，再对完整文件进行最终校验，响应范围不必以整首文件末尾为终点。

逐首传输与队列推进使用 `--serial-only`，检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --serial-only
```

该探针模拟业务层前后台状态，并用 `SIGKILL` 检查进程重建后的系统任务恢复；它不能证明硬件息屏场景已经通过。Debug 的 `-lan-record-lifecycle` 仅被动记录真实 scene phase、终态及后台唤醒，可用于配对真机验收。旧版 WatchConnectivity 任务兼容、手表自然息屏接收、真实吞吐量/剩余时间、锁屏后台播放、耳机和双指互点操作需要配对真机验收。模拟器布局截图和本次验证记录见 `Verification.md`；传输页两个标签的截图分别为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)。
