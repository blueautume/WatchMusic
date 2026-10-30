# 随身音乐

随身音乐是一款面向 iPhone 与 Apple Watch 的离线音乐播放器，提供本地音乐管理、独立播放和局域网传输。本仓库包含运行所需的源码、工程、资源和测试，使用正式工程与应用标识，无需原项目目录。

```sh
git clone git@github.com:blueautume/WatchMusic.git
cd WatchMusic
git switch main
open WatchMusic.xcodeproj
```

功能开发从 `main` 新建分支。应用采用双端前台局域网传输，两端播放独立，不同步或互相控制播放。

## 打开与运行

打开 `WatchMusic.xcodeproj`：

- iPhone scheme：`WatchMusic`
- Apple Watch scheme：`WatchMusicWatch`
- iPhone Bundle ID：`com.lihao.WatchMusic`
- Watch Bundle ID：`com.lihao.WatchMusic.watchkitapp`
- 桌面名称：`随身音乐`；版本 `1.0.0 (1)`

两个 target 继续使用原工程的开发团队与自动签名配置。真机运行时由 Xcode 为新 ID 创建相应描述文件。最低 iOS 17 / watchOS 10；手表双指互点下一首需要 watchOS 11 和支持该手势的设备。

正式版使用新的 Bundle ID，因此会作为独立应用安装，不会自动继承旧实验版沙盒中的歌曲、播放偏好或协议同意记录。旧版应用及其原有音乐、数据仍保留；如需继续使用已有音频，请从原始文件重新导入并传到正式版手表应用。

## 隐私协议与技术支持

iPhone 首次启动会全屏展示协议入口，明确同意后才初始化音乐库、播放器与传输服务；本机记录当前协议版本和同意时间，再次启动直接进入。取消保持未进入状态，协议版本更新后重新询问。传输页右上角、清理按钮左侧的设置仅提供“隐私协议”和“关于”，可离线阅读隐私协议、用户协议，以及撤回同意。撤回会停止本机播放和传输、清除同意记录，保留音乐与传输队列；Apple Watch 不添加签署流程。

可部署的 [隐私协议](PhoneApp/Legal/privacy.html)、[用户协议](PhoneApp/Legal/terms.html)、[技术支持](PhoneApp/Legal/support.html) 也是应用内的离线文档，避免分别维护内容。运行 `bash Website/package.sh` 生成 [静态网页压缩包](Artifacts/Deployment/watchmusic-web-2026-10-29.zip)，解压上传即可；详见 [部署说明](Website/README.md)。网页支持深浅色模式，无外部依赖或追踪代码。开发者：李浩（个人开发者），支持邮箱：2114581274@qq.com。

## 功能范围

- 手机：音乐库和传输两个入口，导入 MP3 / FLAC，管理目录、本地播放和发送到手表。音乐库根页仅展示目录和新建入口；先建目录，再在目录内导入。长按歌曲进入多选，右上角“操作”菜单提供批量发送、移动、删除，旁边“完成”退出选择；同名目标不覆盖，部分失败会汇总提示。
- 手表：单页播放器，按歌曲信息、四个图标操作、上一首/播放暂停/下一首纵向排列；模式、速度、睡眠定时和音频输出直接操作，表冠交给系统本地音量控件，页面统一采用自定义返回按钮；系统导航栏隐藏，避免挤占曲面屏幕。移除播放进度条和拖动手势。
- 移除歌词解析、显示、校准与传输，以及外部歌词/封面资源管理。歌曲内嵌标题、艺术家和封面继续显示。
- 两端独立本地播放，保留离线播放、后台音频、系统锁屏/耳机控制、播放恢复、模式、倍速、音量和睡眠定时；不交换播放状态，也不控制另一台设备。
- 系统控制中心和锁屏播控使用上一首、播放/暂停、下一首，关闭前后跳秒命令；系统进度拖动保留。
- 手机播放条固定叠放在标签栏上方，两侧留边距，不参与目录列表的纵向排版；去掉拖动和悬浮球。目录、歌曲及传输列表只在播放条存在时追加可滚动尾部空白，最后一项可滚到条上方。播放页模式、速度、睡眠和输出统一为四个无文字图标；不提供独立应用音量，音量由系统控制，升级时移除旧应用增益偏好。应用配色跟随系统深浅色模式。
- 新图标沿用参考图的手表与音符轮廓，以蓝色作为应用主题；iPhone 提供浅色与深色图标，Watch 使用适配圆形裁切的深色版本。[生成提示词及导出说明](Brand/IconPrompt.txt)。
- 文件管理只修改所在设备的副本。

手机播放页按可用高度和文字实际高度布局，优先扩大封面，再分配区块间距，底部操作保留适量边距；小屏、大字或开启定时时可以滚动。手表播放器的原生音量控件常驻在不透明页面背景后，不改变页面布局；进入播放器、开始播放或关闭弹层后请求表冠焦点，离开或进入后台时释放。真实系统音量变化时，当前页面右上角从右侧滑入无文字和图标的竖向细音量条，填充自下向上随音量平滑过渡，最后一次变化约 1.4 秒后向右滑出隐藏；屏幕旋转后仍固定在当前页面右上角，独立于实体表冠位置。打开弹层、选择输出、离开页面或进入后台时清理提示。音量已到上下限后的空转不产生音量变化事件。播放页的双指互点两次绑定下一首，仅在页面前台可见、已选歌曲且未准备播放时启用，弹层和输出选择期间暂停手势。

手表本地播放继续通过系统音频会话、Now Playing 信息和远程命令提供系统播控，歌曲、播放状态与队列调整同步到系统。表盘上划打开的智能叠放由 watchOS 决定是否呈现媒体卡片；如未显示，检查手表“设置 → 智能叠放 → 实时活动”相关开关，详见 [Apple 实时活动说明](https://support.apple.com/zh-hans/guide/watch/bz1vx4mwqbw9/watchos)。App 无公开 API 强制插入或置顶这张系统卡片。单次捏合与辅助触控手势由系统设置管理；本 App 的快捷手势使用 watchOS 11 的双指互点两次。

## 传输进度

所有新发送和重试均使用局域网传输：手机临时提供文件下载服务，手表通过 HTTP 接收并校验后保存。手机“传输”页分为“进行中”和“已传输”两个标签，无需选择传输方式。旧版普通 WatchConnectivity 任务的历史记录、取消和保存回执继续兼容，重试时统一走局域网。[传输说明与测试步骤](LANTransferExperiment.md)

发送前按目录、文件名、大小和 SHA-256 查询手表实际库存，内容相同的歌曲自动跳过，同路径已有未结束任务也不重复加入。指纹缓存独立于手机传输历史，清空记录后仍可去重；旧文件首次查询时计算摘要，文件版本变化会使缓存失效，手表已删除或内容不同的同名文件可重新发送。操作结果用简短摘要提示新增及跳过数量。

传输时可以继续从其他目录或列表添加歌曲，手机按加入顺序维护全局等待队列；一次选择超过 100 首时，App 自动拆为每批最多 100 首。追加任务排在已有任务之后，当前批收到终态确认后才启动下一批；每批内部由手表逐首下载，校验并保存完成后才开始下一首。当前项失败或取消后继续批内后续任务，追加时当前批继续运行。

“进行中”先显示正在传输或部分接收的任务，进度暂时停滞时保留优先位置；之后依次是校验或等待确认、按加入顺序排队、已暂停任务，以及可重试的失败和本地已更新记录。“已传输”仅包含手表确认保存成功的记录，按发起时间从新到旧排列。已取消记录不显示在两个标签中，也不计入标签数量。列表排序不改变持久化历史及每首歌曲的最新记录判断。

传输页不提供多选或更多菜单。“暂停 / 开始”切换全部可操作任务，也覆盖手机本地等待项；单项保留独立暂停、继续和取消，校验保存阶段不暂停。全局暂停时，随后追加的任务也以暂停状态等待。右上角清扫图标清除当前标签的全部任务或已传输记录。清除会先取消相关传输再移除记录，不删除两端已经保存的音乐，也不撤销已经完成的保存。

已提交到手表的暂停和继续需要实时可达并确认，不可达或未确认时不会假报暂停；手机本地等待项可直接暂停、开始和清除。暂停保留已接收大小及百分比，隐藏速度和剩余时间；恢复单项不抢占当前下载或保存。当前批仍有暂停项未结束时，后批继续等待，不承诺跨批越过这些暂停项。旧版普通传输任务不支持此暂停，可取消后从音乐库重新发送。

LAN 接收开始后，手表自动进入专用全屏接收页，显示进度、歌曲和批次，完成或取消后自动返回音乐库。充电或满电仍接电时，整个手表 App 默认通过 CoreMotion 重力识别四个显示方向，音乐库、播放器和接收页使用同一方向，并修正左侧表冠的坐标，无需旋转设置按钮。平放或运动数据不可用时保留最近稳定方向；检测到拔电后固定为佩戴时的竖屏，停止方向采样。进入后台也停止采样，回到前台时重新读取充电状态。

手表音乐库标题“随身音乐”之后显示本机电量百分比，充电时显示充电状态；电量尚不可读时显示未知状态，不把它当成 0%。标题电量随应用充电方向旋转，不再保留独立电量栏。watchOS 26.5 模拟器中公开隐藏请求未能可靠隐藏系统时钟，因此保留一个系统时间，其方向仍由系统控制，应用不绘制第二个时钟。应用使用完整物理画布旋转，不扣除一整条时钟区域；只对文字和点击区域做时钟角落避让，列表卡片可继续显示到曲面边缘，无固定底部黑条。

两台设备需连接能互相访问的同一 Wi-Fi，且两端 App 都处于 active 状态时才运行网络传输。手机前台传输期间会暂时保持屏幕常亮，结束后恢复原设置；任一端进入 inactive 或 background，包括打开控制中心、锁屏或返回表盘，会自动暂停传输并保留队列。回到两端 App 的 active 状态后自动重新检查连接并继续，手动暂停的项目仍保持暂停。

等待队列和暂停意图持久保存，手机或手表重新启动后按原 FIFO 恢复，重新验证源文件版本并向手表核对库存；已经保存的歌曲跳过，未完成的单曲可能重新发送。短暂断连后采用有节制的重试，不同时启动多份发送流程；源内容变化时要求重新发送，仅元数据变化且摘要相同的文件仍可恢复。清除任务会使旧准备工作和迟到消息失效，不会重新创建已清除的队列。

当前不使用手机持续后台任务、手表显示活动请求、固定 4 MiB 分段缓存或手机源发送字节推算进度。watchOS 的实际屏幕策略由设备和系统控制；显示降低亮度不等于允许继续传输，生命周期转 inactive 时按自动暂停处理。手表新下载使用无固定标识的 `URLSessionConfiguration.ephemeral`，不会跨进程关联下载任务；新进程或回 active 后通过持久清单的 ready 通知和手机新清单，重新下载未完成歌曲。旧后台会话只在升级时用于取消遗留任务。

手机源服务和清单有效期最长 1 小时，结束或过期后建立新的临时会话。手机队列不保存旧服务凭据；手表持久清单保存在受文件保护、排除备份的 Application Support 文件中，令牌不进入正式日志或用户传输记录。普通会话在重定向委托中返回 `nil` 拒绝跳转，保存前仍严格校验最终端点和文件内容。非 active 时不对完整暂存文件启动校验或提交，暂停前已经原子保存的事实保留。

局域网进度使用手表实际接收字节；已有普通传输任务仍通过 WatchConnectivity 原生 `WCSessionFileTransfer.progress` 读取进度，并用进度比例与源音频大小换算已传大小。速度与剩余时间由近期采样估算，界面以“约”标注。系统尚未开始发送、进度停滞或等待保存回执时不显示虚假的速度与时间。

传输达到 100% 只表示发送阶段完成；只有手表完成文件校验、写入并返回成功回执后，手机才显示“已保存到手表”。单项时间估算针对该歌曲；“传输”标题旁的总剩余时间聚合当前与排队歌曲，使用平滑速度与粗粒度更新，暂停或速度未知时隐藏。保存开销和无线速度变化会影响实际完成时间。

播放位置从原生播放器时钟读取，仅局部进度视图使用 TimelineView；睡眠定时使用一次性截止任务。传输进度从真实接收事件及旧系统任务 Progress 观察更新，独立于音乐库模型，避免菜单随全页定时发布而闪烁。

暂停后进入后台，或后台播放被暂停、睡眠定时及耳机断开停止时，两端播放器释放已准备的音频硬件并停用音频会话，保留歌曲、进度、队列、倍速和系统播控；继续播放时重新准备输出。前台短暂停保持原有快速续播和表冠音量体验，系统输出选择造成的 inactive 状态不触发后台清理，真实后台播放及有效的播放准备也不会被中断。迟到的音频激活结果按当前播放意图收尾，不重新开始已取消的播放或关闭新的播放。系统播控封面按图片内容复用，避免每次暂停、定位或状态保存都重新创建。

不可见时，手机播放进度与睡眠倒计时停止界面刷新；睡眠截止动作仍由播放器负责。手表后台释放由显示层启用的电量监测并停止方向采样，回前台立即恢复，前台电量与方向刷新频率不变。歌曲库存查重在离开 active 后取消排队查询及正在读取的大文件摘要，回前台通过原有队列重新查询，不丢弃发送任务；已经完成且有效的摘要缓存继续保留。

## 验证

```sh
xcodebuild -project WatchMusic.xcodeproj -scheme WatchMusic \
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
Tests/run-lan-inventory-tests.sh
Tests/run-transfer-source-version-tests.sh
Tests/run-watch-orientation-tests.sh
Tests/run-watch-surface-tests.sh
Tests/run-watch-volume-feedback-probe.sh WATCH_SIMULATOR_UDID
Tests/run-transfer-queue-estimate-tests.sh
Tests/run-privacy-consent-tests.sh
Tests/run-phone-playback-layout-tests.sh
python3 Tests/check-legal-pages.py
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
Tests/run-phone-foreground-queue-probe.sh IPHONE_SIMULATOR_UDID
```

批量文件探针使用唯一测试目录执行真实移动和删除，并还原传输索引。发送队列探针使用真实文件摘要、PhoneLibrary 和 HTTP 源准备，Watch 消息由测试端注入，覆盖去重、追加、分批及取消隔离。前台队列探针检查 inactive/background 自动暂停、回 active 与进程重建后恢复、手动暂停和迟到消息隔离，不代表实际设备生命周期或无线链路验收。

手表 LAN 探针使用本机 HTTP 服务检查前台暂停、恢复和进程重建；这些模型切换不能代表真实设备操作：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/WatchMusicWatch.app \
  --foreground-only
```

暂停、继续及暂停后取消场景使用同一探针：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/WatchMusicWatch.app \
  --pause-only
```

同一下载探针的 `--range-only` 验证 HTTP 206 的范围和完整性校验。`--disconnect-resume-only` 与 `--background-only` 现在均为 `--foreground-only` 的兼容别名，不再证明后台 Range 自动续传。

逐首传输与队列推进使用 `--serial-only`，检查当前文件保存后才开始下一首，以及暂停、继续、失败和取消后的调度：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/WatchMusicWatch.app \
  --serial-only
```

安装和真机操作由用户手动进行，开发端不自动部署、启动或发送真机测试文件。构建可以使用 Release；不为测试改写共享 Scheme，保留用户当前设置。验收时让两端 App 保持 active，分别检查控制中心、锁屏、退后台和返回后的自动恢复，另检查真实速度、手动暂停、系统音频控制及双指互点。历史模拟器截图和分轮验证见 `Verification.md`；传输页两个标签的截图分别为 [进行中](Artifacts/Previews/phone-transfers-in-progress.png) 和 [已传输](Artifacts/Previews/phone-transfers-completed.png)。
