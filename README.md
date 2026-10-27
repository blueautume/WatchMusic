# 随身音乐 Lab

基于原项目 `OfflineWatchPlayer` 建立的独立实验工程，用于开发简化版音乐播放器。本仓库包含运行所需的源码、工程、资源和测试，无需原项目目录。工程、scheme、应用沙盒和播放偏好均独立，可与原应用同时安装。

```sh
git clone git@github.com:blueautume/WatchMusic.git
cd WatchMusic
open OfflineWatchPlayerLab.xcodeproj
```

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
- 保留本地离线播放、后台音频、锁屏/耳机控制、播放恢复、模式、倍速、音量和睡眠定时。
- 文件管理只修改所在设备的副本。

## 传输进度

`experiment/lan-transfer` 分支的所有新发送和重试均使用局域网传输：手机临时提供文件下载服务，手表通过 HTTP 接收并校验后保存。手机“传输”页分为“进行中”和“已传输”两个标签，无需选择传输方式。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，重试时统一走局域网。[实验说明与测试步骤](LANTransferExperiment.md)

局域网逐首串行传输：整批先持久保存为等待队列，同一时间只运行当前一首的原生下载，校验并保存完成后才开始下一首。当前项失败或取消后继续后续任务。暂停项会让出位置；全部暂停时不启动等待项，恢复单项也不会抢占当前正在下载或保存的歌曲。

“进行中”先显示正在传输或部分接收的任务，进度暂时停滞时保留优先位置；之后依次是校验或等待确认、按加入顺序排队、已暂停任务，以及可重试的失败和本地已更新记录。“已传输”仅包含手表确认保存成功的记录，按发起时间从新到旧排列。已取消记录不显示在两个标签中，也不计入标签数量。列表排序不改变持久化历史及每首歌曲的最新记录判断。

传输列表支持多选、全选。“暂停 / 开始”是同一个按钮：多选时作用于所选任务，否则作用于全部可操作任务；校验保存阶段不暂停。更多菜单提供清除所选、清除全部任务或已传输记录。清除会先取消相关传输再移除记录，不删除两端已经保存的音乐，也不撤销已经完成的保存。

运行中的暂停和继续需要手表实时可达并确认，不可达或未确认时不会假报暂停。暂停保留已接收大小及百分比，隐藏速度和剩余时间；准备文件时暂停的项目会以初始暂停状态提交。旧版普通传输任务不支持此暂停，可取消后从音乐库重新发送。

LAN 接收开始后，手表自动进入专用全屏接收页，显示进度、歌曲和批次，完成或取消后自动返回音乐库。充电或满电仍接电时，整个手表 App 默认通过 CoreMotion 重力识别四个显示方向，音乐库、播放器和接收页使用同一方向，并修正左侧表冠的坐标，无需旋转设置按钮。平放或运动数据不可用时保留最近稳定方向；检测到拔电后固定为佩戴时的竖屏，停止方向采样。进入后台也停止采样，回到前台时重新读取充电状态。

手表 App 左上角在系统时间同一顶部区域显示本机电量百分比，充电时显示充电状态，普通使用和传输期间均可查看；电量尚不可读时显示未知状态，不把它当成 0%。顶部信息保留屏幕坐标，不随内容旋转。

watchOS 公共接口不能保证屏幕持续全亮到传输结束，充电也没有通用的保持全亮 API。Always On 取决于设备和用户设置，系统仍会降低亮度和更新频率；本次实现不承诺全程常亮，底层继续保留系统后台接收与恢复作为息屏后的保障。

两台设备需连接能互相访问的同一 Wi-Fi，手机 App 保持前台，发送期间会暂时保持手机屏幕常亮；手表在打开 App 并开始接收后可息屏。手表使用系统后台下载会话，并持久保存等待队列、恢复清单、已下载文件和待发送回执，进程重新启动时重新关联系统当前任务，随后继续串行队列。系统可能延迟进度、结果回调及下一首的启动，因此不保证息屏期间实时更新速度或预计时间；手动强退 App 可能使系统取消后台传输。

手机源服务有效期最长 1 小时，暂停也需手机保持前台；会话结束或过期后“开始”会建立新会话重新发送，不保证跨会话断点续传。恢复所需令牌保存在手表受文件保护、排除备份的 Application Support 文件中，不进入正式日志或用户传输记录。系统后台会话可能跟随重定向，接收器在保存前严格校验最终端点和文件内容。

局域网进度使用手表实际接收字节；已有普通传输任务仍通过 WatchConnectivity 原生 `WCSessionFileTransfer.progress` 读取进度，并用进度比例与源音频大小换算已传大小。速度与剩余时间由近期采样估算，界面以“约”标注。系统尚未开始发送、进度停滞或等待保存回执时不显示虚假的速度与时间。

传输达到 100% 只表示发送阶段完成；只有手表完成文件校验、写入并返回成功回执后，手机才显示“已保存到手表”。系统负责后台调度，排队等待时间和手表保存时间不包含在发送剩余时间估算内。

## 播放遥控

手机与手表实时可达且对端有播放项目时，可用简洁控制条操作对端的上一首、下一首、播放和暂停。声音仍由原设备播放，两端本地播放器保持独立；同步内容仅为播放状态和控制指令，不包含歌名、文件路径、时长、播放进度或音频。

“可达”指 WatchConnectivity 实时连接，并非只要配对即可。不可达时禁用遥控，不积压操作供以后执行；重新连接会刷新状态，重复或过期指令不会再次触发播放操作。

## 验证

```sh
xcodebuild -project OfflineWatchPlayerLab.xcodeproj -scheme OfflineWatchPlayerLab \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
Tests/run-playback-tests.sh
Tests/run-playback-control-tests.sh
Tests/run-audio-format-tests.sh
Tests/run-audio-metadata-tests.sh
Tests/run-artwork-tests.sh
Tests/run-transfer-tests.sh
Tests/run-transfer-list-tests.sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-watch-orientation-tests.sh
```

播放器集成探针可在已启动的模拟器运行，不会播放声音：

```sh
Tests/run-player-integration-probe.sh ios SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.flac" \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3" "$PWD/Tests/Fixtures/EmbeddedResources.flac"
Tests/run-phone-bulk-probe.sh IPHONE_SIMULATOR_UDID
Tests/run-playback-control-integration-probe.sh ios IPHONE_SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3"
Tests/run-playback-control-integration-probe.sh watchos WATCH_SIMULATOR_UDID \
  "$PWD/Tests/Fixtures/EmbeddedResources.mp3"
```

批量文件探针使用唯一测试目录执行真实移动和删除，并还原传输索引；遥控探针通过真实暂停状态的播放器检查路由，不播放声音。这些探针不替代配对真机的实时遥控验收。

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

同一下载探针的 `--range-only` 验证 HTTP 206 完整文件及分段响应校验；`--disconnect-resume-only` 验证暂停中断开 TCP 后，系统发起 Range 请求并恢复完整文件。

逐首传输与队列推进使用 `--serial-only`，检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app \
  --serial-only
```

该探针模拟业务层前后台状态，并用 `SIGKILL` 检查进程重建后的系统任务恢复；它不能证明硬件息屏场景已经通过。Debug 的 `-lan-record-lifecycle` 仅被动记录真实 scene phase、终态及后台唤醒，可用于配对真机验收。旧版 WatchConnectivity 任务兼容、手表自然息屏接收、真实吞吐量/剩余时间、锁屏后台播放、耳机和双指互点操作需要配对真机验收。模拟器布局截图和本次验证记录见 `Verification.md`；传输页两个标签的截图分别为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)。
