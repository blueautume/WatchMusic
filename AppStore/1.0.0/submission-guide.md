# WatchMusic 1.0.0 上架素材使用说明

核对日期：2026-10-29。此交付包提供网页、截图和可粘贴文案，由你自行部署和上传；不修改 App Store Connect 已填写的内容。

## 尺寸只保留一组

| 交付 | 统一尺寸（宽 × 高） | 上传位置 |
| --- | --- | --- |
| iPhone 截图 | **1320 × 2868**，竖屏 | 6.9 英寸 iPhone 组／对应最大显示屏组 |
| Apple Watch 截图 | **422 × 514**，竖屏 | Apple Watch 组 |
| 标题视觉素材 | **3840 × 1646** | 标题和搜索结果 → 标题 |
| 搜索结果视觉素材 | **1920 × 1280** | 标题和搜索结果 → 搜索结果 |

正式上传文件（`screenshots/zh-Hans/iphone`、`screenshots/en-US/iphone`、`screenshots/watch`、`creative` 的标题/搜索图）使用 RGB PNG，无 Alpha 通道。`screenshots/raw` 保留未经修改的来源，不是默认上传目录。每个平台所有截图统一该平台尺寸，按文件名前缀顺序上传。标题与搜索结果是独立的横版创意素材，不放进竖版截图栏。

你给的截图当前选中了中等 iPhone 显示屏，只在那里上传 1206 × 2622 并不能代替必需的大屏组。iPhone 最大组截图可自动缩放供较小尺寸使用；Apple Watch 所有本地化统一使用同一尺寸。因此只交付上述两种设备截图尺寸，不额外制作各机型版本。[Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)、[只提交最高分辨率的规则](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/)。

当前工程面向 iPhone 与 Apple Watch，不以 iPad 为目标；不提供虚构的 iPad 版本截图。App 预览视频可选，本次交付静态截图。每个平台至少一张、最多十张。[上传说明](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/)。

## 标题与搜索结果素材

两种横版创意素材展示同一品牌和离线聆听主题，按不同画幅分别构图。将主体保留在画幅中部，在 App Store Connect 的预览中检查深浅色和裁切；不要用应用图标代替整张创意素材。这类素材用于 iOS 27 / iPadOS 27 及之后的相关展示位。它们补充实际 UI 截图，不替代截图。[创意素材规格](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/)、[Apple 创意素材介绍](https://developer.apple.com/news/?id=ljpl7kyn)。

## 文案与搜索

1. 简体中文使用 [metadata-zh-Hans.md](metadata-zh-Hans.md)。
2. 添加 English (U.S.) 本地化后使用 [metadata-en-US.md](metadata-en-US.md)。
3. 关键词按该语言的代码块原样填写，保留英文逗号，不再追加词库。中文 98 bytes，英文 99 bytes。
4. 名称、副标题、推广文本和描述分别填写；不要把说明、字数或 Markdown 标记贴进字段。

名称、副标题各最多 30 字符，推广文本最多 170 字符，描述最多 4000 字符；关键词按 100 UTF-8 bytes 控制。主类别建议“音乐”，版权填 `2026 李浩`，版本填 `1.0.0`。首版没有“此版本的新增内容”字段。[App 信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)、[版本字段规范](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

当前应用界面为简体中文。英文商店文案明确说明这一点，避免被误解为应用已有完整英文界面；可以让英文商店复用真实的中文界面截图。

本次手机推荐顺序：01 离线聆听、02 目录整理、03 长按多选、04 目录内歌曲。中文和英文短文案各一套，真实应用 UI 保持简体中文。`screenshots/raw/phone-transfer.png` 另提供含失败重试状态的真实传输界面，不在默认推荐序列中。手表提供四张原生 UI 截图，不添加设备边框。标题和搜索结果素材分别提供中文和英文版本。

商店元数据添加英文不等于二进制已经实现英文界面；不要据此把应用支持语言填写为已完整支持英文，也不要把商店文本本地化当成 UI 翻译。

## 营销网页部署

部署包严格只有四个自包含 HTML：`index.html`、`privacy.html`、`terms.html`、`support.html`。首页图片全部内嵌，不需要额外资源目录、Node、数据库或后台服务。四个文件放在同一网站目录，营销网页中的隐私、用户协议和支持链接使用随包页面。你已填写的支持网址继续保留。营销网址请填写部署后的完整 HTTPS 页面地址；隐私政策网址指向公开的 `privacy.html`。

公开 App Store 下载链接尚未提供，网页不设置虚假的商店下载入口。拿到实际商店 URL 后按营销站点 README 配置即可。

## 提交前仍需由你填写的信息

| 项目 | 应填写的实际内容 |
| --- | --- |
| 审核联系信息 | 李浩、2114581274@qq.com、本人有效的国际格式电话号码 |
| 营销 URL | 你实际部署的 HTTPS 营销网页地址 |
| 隐私政策 URL | 公开可访问的 HTTPS 隐私页面地址 |
| 价格与地区 | 按你的实际发行计划设置；素材不预设免费或付费 |
| 年龄分级、内容权利及适用地区问卷 | 按实际功能和你拥有的权利填写 |
| 构建版本 | 选择与素材一致的 1.0.0 构建，包含 Watch companion app |

应用无需账号，审核“需要登录”不勾选；测试步骤已提供在中文文案的审核备注中。系统可能要求本地网络权限；手表传输需要配对设备、可互访 Wi-Fi 和两端前台运行。审核附件可提供自有或授权的短音频，避免使用未经许可的商业歌曲。

## 隐私信息建议

当前源码、隐私清单及协议显示：没有开发者音频/播放数据服务器、广告或统计 SDK，无账号和追踪；音频在用户所选设备间传递。依当前实现，可在 App Privacy 中核对“不收集数据”的选项。最终以实际提交构建及网站托管配置为准；用户主动发来的支持邮件、托管日志和未来新增 SDK 需要按 Apple 的定义重新判断。[Apple 数据收集定义](https://developer.apple.com/app-store/app-privacy-details/)、[填写隐私信息](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)。

不要为此次上架宣称后台传输、跨设备遥控、端到端加密、在线曲库或无限格式支持。前台传输、手表存储后离线独立播放，是本版本的实际能力。

## 打开与打包

本地双击 `index.html` 可预览全部素材与复制字段；点击图片打开对应上传原图。`metadata.json` 提供同样字段的结构化文本，`manifest.json` 记录16张正式上传图片的尺寸、类型和SHA-256。

完整素材压缩包：`Artifacts/Deployment/watchmusic-appstore-1.0.0.zip`。网站部署压缩包：`Artifacts/Deployment/watchmusic-marketing-1.0.0.zip`。部署包严格四个HTML，素材包不用于网站部署。
