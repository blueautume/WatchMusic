# App Store 文案 · 简体中文 · 1.0.0

以下代码块可直接粘贴到对应字段。商店主名称保留 WatchMusic，并补充“随身音乐”，让英文品牌与应用内名称一致。副标题说明手表离线播放和传输用途。名称是否可用，以 App Store Connect 保存结果为准。

## 名称

```text
WatchMusic 随身音乐
```

15 / 30 个字符。

## 副标题

```text
手表离线播放与 Wi-Fi 传输
```

16 / 30 个字符。

## 推广文本

```text
把喜欢的 MP3、FLAC 整理进目录，通过 Wi-Fi 传到 Apple Watch。保存后即可在手表独立离线听歌；播放模式、倍速和睡眠定时，让每次聆听都顺手。
```

81 / 170 个字符。推广文本用于介绍功能，不承担关键词堆叠。

## 描述

```text
把音乐带在手腕上。

WatchMusic 随身音乐是一款为 iPhone 和 Apple Watch 设计的本地音乐播放器。导入自己的 MP3、FLAC 文件，按目录整理，再把想听的歌曲传到手表。保存完成后，Apple Watch 可以独立离线播放，无需手机持续连接。

从自己的音乐开始
• 通过系统“文件”选择器导入 MP3、FLAC。
• 显示歌曲内嵌的封面、歌名和艺术家。
• 用目录整理音乐，长按歌曲即可批量发送、移动或删除。

传到手表，逐首排队
• 默认通过局域网 Wi-Fi 传输，显示进度、速度与大概剩余时间。
• 传输中可以继续加入其他目录的歌曲，所有任务依次排队。
• 核对手表已有文件，跳过已保存且内容相同的歌曲。
• 支持暂停、继续和清理任务；离开应用自动暂停，返回后检查连接并尝试恢复。

在手表独立聆听
• 上一首、播放或暂停、下一首，操作简洁。
• 提供顺序、随机和循环模式，以及播放速度与睡眠定时。
• 支持系统音频输出与音量控制。
• 显示手表电量，充电时可根据放置方向调整应用布局。

在手机也能听
iPhone 保留独立本地播放、锁屏和系统播放控制。音乐库中的紧凑播放条让整理音乐与切歌更方便。手机界面跟随系统深浅色模式。

音乐属于你
无需注册账号。当前版本没有广告或行为追踪，也不向开发者服务器上传音乐和播放记录。

使用条件
传输需要配对的 iPhone 与 Apple Watch 连接可互相访问的同一 Wi-Fi，并保持两端应用打开。未完成单曲在恢复时可能需要重新传输。传输完成后的手表本地播放不需要保持网络连接。两端独立播放。

本应用播放你自行导入且有权使用的音频，不提供在线曲库或音乐内容下载。

兼容 iOS 17 及以上、watchOS 10 及以上。实际音频输出与部分系统能力取决于设备及系统支持。

技术支持：2114581274@qq.com
开发者：李浩（个人开发者）
```

819 / 4000 个字符（纯文本，含换行）。

## 关键词

```text
mp3,flac,无损音频,文件管理,睡眠定时,倍速播放,跑步听歌,local,audio,player,timer
```

58 个字符，**98 / 100 UTF-8 字节**（含英文逗号），按较严格的字节限制制作。名称、副标题已覆盖随身音乐、手表、离线播放、Wi-Fi、传输；这里补充格式、管理、播放功能与英文通用词。无需再把备用词库全部粘入。

## 其他字段

| 字段 | 内容 |
| --- | --- |
| 版本 | `1.0.0` |
| 版权 | `2026 李浩`（系统自动添加 ©） |
| 主要类别 | 音乐 |
| 技术支持网址 | 保留你已填写并可公开访问的完整 HTTPS 地址 |
| 营销网址 | 部署营销 HTML 后，填写营销页面的完整 HTTPS 地址 |
| 隐私政策网址 | 已部署 `privacy.html` 的完整 HTTPS 地址 |

首个版本无需填写“此版本的新增内容”。如需要其他发布渠道的首发说明，可用：

```text
首个正式版本。支持本地 MP3、FLAC 导入与目录管理、向 Apple Watch 的 Wi-Fi 排队传输，以及手机和手表各自独立播放。
```

## 给 App Review 的备注

```text
This app does not require an account or sign-in.

To test: accept the privacy agreement on iPhone; create a folder in Library; enter that folder and import an MP3 or FLAC file with the system Files picker. The app plays user-provided audio and does not include a streaming catalog or content-download service.

For transfer testing, install the companion app on a paired Apple Watch, connect both devices to the same reachable Wi-Fi, allow Local Network access, and keep both apps open. Send a track or folder from iPhone. Transfers run sequentially; progress, speed and remaining time are estimates. Leaving either app pauses transfer. Reopening both apps checks connectivity and attempts to resume; an incomplete track may restart.

After the Watch confirms a track is saved, it can play the track offline without a continuing iPhone connection. The iPhone and Watch players operate independently. The current app interface is in Simplified Chinese.

Contact: Li Hao, 2114581274@qq.com
```

正式审核联系人的电话号码需在 App Store Connect 中补充本人有效号码，不能用邮箱或虚构号码替代。若附审核音频，请使用自有或已获授权的文件。

字段规则核对日期：2026-10-29。[名称与副标题](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)、[版本字段与关键词](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。
