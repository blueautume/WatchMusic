# 原生截图来源与复现说明

拍摄日期：2026-10-29。应用：当前正式标识 WatchMusic / 随身音乐，1.0.0 (1)。所有 `screenshots/raw/*.png` 均由 `xcrun simctl io … screenshot` 直接捕获，没有重绘界面、替换控件、后期修改屏幕内容或拉伸截图。商店排版衍生素材应保留本目录原图作为出处。

## 一个平台一种尺寸

| 平台 | 标准竖屏尺寸 | 模拟器 | 系统 |
| --- | --- | --- | --- |
| iPhone | 1320 × 2868 px | iPhone 17 Pro Max | iOS 26.5 |
| Apple Watch | 422 × 514 px | Apple Watch Ultra 3 (49mm) | watchOS 26.5 |

这里的“一种尺寸”指每个平台的所有截图统一分辨率，而不是只提供一张图。原图为无设备外框 PNG。Watch 商店截图请上传 `screenshots/watch/01.png`—`04.png`，不添加设备边框或营销标语。它们从来源原图无损导出为不含 Alpha 通道的 RGB PNG，像素内容逐张比对一致。`raw` 保留模拟器原始 RGBA 文件作为来源。

## 截图内容

| 文件 | 内容 | 外观/状态 |
| --- | --- | --- |
| `phone-library.png` | 有四个目录的音乐库、底部播放条 | 浅色；真实原创演示文件 |
| `phone-folder.png` | “旅行随听”歌曲列表、导入/发送入口 | 浅色；真实原创演示文件 |
| `phone-player.png` | 封面、歌曲信息、进度、播放与四个功能图标 | 深色；暂停在第 5 秒 |
| `phone-selection.png` | 目录长按后的多选界面 | 深色；前两首选中 |
| `phone-transfer.png` | 排队、速度、预计时间、暂停与失败重试 | 深色；现有 DEBUG 预览状态 |
| `watch-library.png` | 随身音乐、电量、全部歌曲与音乐目录 | 深色；18 首原创演示文件 |
| `watch-folder.png` | 全部歌曲列表、搜索、播放全部 | 深色；真实原创演示文件 |
| `watch-player.png` | 清晨漫步 / 随身音乐、封面和播放器 | 深色；暂停；真实播放引擎加载 |
| `watch-transfer.png` | 接收进度 63% | 深色；现有 DEBUG 预览状态 |

传输截图的进度、速度、剩余时间、任务数量来自项目已有的隔离预览夹具，旨在展示真实控件与交互布局，**不是测速结果或速度承诺**。手机传输预览包含一个失败重试任务，适合说明恢复操作；可按营销需要不选用此图。截图未连接另一台设备进行真实传输。

iPhone 使用系统支持的状态栏覆写，时间 09:41、电量 100%；Watch 不支持 `simctl status_bar override`，保留其系统显示的时间，未后期替换。Watch 电量由现有 DEBUG `-preview-battery 100` 提供。

## 演示内容及版权

未读取或使用用户的歌曲、商业唱片封面、第三方照片或歌手姓名。18 首演示曲目均是本次用标准库生成的三分钟静音 WAV，通过 macOS `afconvert` 编码成 FLAC，再写入原创歌名与“随身音乐”艺术家标签。山海封面由 `tools/capture-cover.swift` 使用 AppKit 绘制原创几何图形。文件只存在本次独立 QA 模拟器与 `/tmp/watchmusic-store-fixtures`，不编译进应用，也不宣称应用自带这些音乐。

原创演示内容可随本项目宣传素材使用。示例文件名只是演示内容，不代表提供在线曲库或歌曲下载服务。

生成素材的命令：

```sh
swift AppStore/1.0.0/tools/capture-cover.swift /tmp/watchmusic-store-cover.png
python3 AppStore/1.0.0/tools/capture-fixtures.py /tmp/watchmusic-store-fixtures /tmp/watchmusic-store-cover.png
```

## 隔离与复现

本次创建两个独立 QA 模拟器，没有写入原有用户模拟器、真机或应用源代码：

- `WatchMusic Store iPhone QA`：`7C3DB18E-D30A-4A01-AA38-0AD5B3D6989C`
- `WatchMusic Store Watch QA`：`17FD4CCF-E136-4793-A886-F061B06FB407`

使用 `/tmp/WatchMusic-Formal-Derived/Build/Products/Debug-iphonesimulator/WatchMusic.app` 与同级 `Debug-watchsimulator/WatchMusicWatch.app`。版本来源为当前正式构建；应用包信息与原生尺寸均已核对。

新建 QA 容器的 `Documents/Music/` 放入生成的四个目录。只在 QA iPhone 容器写入当前版本的隐私同意夹具，以进入主界面。真实发行版依然要求用户明确同意。

启动时附加 `-AppleLanguages '(zh-Hans)' -AppleLocale zh_CN`。手机预览参数分别是 `-preview-pinned-player`、`-preview-folder -preview-pinned-player`、`-preview-player`、`-preview-folder-selection -preview-pinned-player`、`-preview-transfers-in-progress`。手表参数为 `-preview-battery 100 -preview-unplugged`，配合 `-preview-track-list`、`-preview-player`、`-preview-lan-transfer`。

Watch 播放器预览要求临时路径 `Music/UI预览/测试旋律.flac`，其内嵌标题为“清晨漫步”；只在捕获播放器时提供这个文件，其余 Watch 列表截图不含此测试目录。截图后 QA 模拟器已关机，保留以便再次拍摄；可自行删除这两个专用 QA 模拟器，不影响原有模拟器。

## 最终导出

手表上传图由 `tools/export-watch-rgb.swift` 仅转换 PNG 编码，移除原生模拟器文件中不需要的 Alpha 通道。与来源图统一为 sRGB 后逐像素相同，尺寸不变。手机宣传截图与横版创意由 `creative/exports.html` 的 HTML/CSS 确定性排版，在浏览器以目标像素导出不透明 RGB PNG；实际 UI 内容取自本目录原生截图，没有生成或重绘控件。

`tools/validate-package.py` 核查16张上传图片的标准尺寸和无透明通道、10个元数据字段限制及部署包严格四个自包含HTML。
