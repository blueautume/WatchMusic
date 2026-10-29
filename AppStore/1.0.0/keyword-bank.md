# 关键词词库与覆盖策略

本文件是相关词库，用于描述、网站自然文案和未来测试；**不要把全部词库粘贴到关键词字段**。关键词字段的直接可用值见两个 metadata 文件。没有词量、排名或转化数据，本方案按功能相关性选词，不声称实测搜索效果。

## 当前推荐字段

| 本地化 | 名称 | 副标题 | 关键词 UTF-8 字节 |
| --- | --- | --- | --- |
| 简体中文 | WatchMusic 随身音乐 | 手表离线播放与 Wi-Fi 传输 | 98 / 100 |
| English (U.S.) | WatchMusic | Offline music for your watch | 99 / 100 |

中文字段也保留 MP3、FLAC、local、audio、player、timer，英文字段覆盖传输、目录、无损和播放控制；分别在 App Store Connect 对应语言中填写。不要把两种语言字段简单拼接。

## 可覆盖的相关表达

| 意图 | 中文表达 | English expressions | 位置 |
| --- | --- | --- | --- |
| 品牌 | 随身音乐、WatchMusic | WatchMusic | 名称；无需在关键词字段重复 |
| 手表播放 | 手表音乐、手腕听歌、Apple Watch 音乐、手表离线播放器 | watch music, offline watch player, wrist audio | 副标题、描述、网站；Apple Watch 用于说明兼容性 |
| 本地音频 | 本地音乐、本地播放、本地音频、音频播放器 | local music, local audio, audio player, offline playback | 描述与关键词 |
| 音频格式 | MP3 播放器、FLAC 播放器、无损音频、无损音乐 | MP3 player, FLAC player, lossless audio | 关键词与描述；不承诺所有编码配置 |
| 文件整理 | 目录管理、文件夹播放、文件管理、音乐分类、批量管理 | folders, library, file management, organize tracks | 关键词、描述、网站 |
| 导入 | 导入音乐、导入音频、文件导入 | import audio, import files, Files picker | 描述与网站；不表示在线下载 |
| 传输 | Wi-Fi 传输、局域网传输、发送到手表、排队传输 | Wi-Fi transfer, local network, send to watch, transfer queue | 副标题、关键词与描述 |
| 队列操作 | 逐首传输、暂停继续、跳过已有、追加队列 | sequential transfer, pause, continue, skip duplicates, queue | 描述与网站 |
| 播放方式 | 顺序播放、随机播放、单曲循环、列表循环 | sequential playback, shuffle, repeat, loop | 关键词与描述 |
| 聆听控制 | 倍速播放、播放速度、睡眠定时、定时停止 | playback speed, sleep timer, timed stop | 关键词与描述 |
| 使用场景 | 跑步听歌、散步听歌、通勤听歌、睡前听歌 | music for running, walking, commuting, bedtime listening | 自然文案；不表示运动或健康追踪 |
| 系统适配 | 锁屏播控、系统音频输出、深浅色模式 | lock screen controls, audio output, light and dark mode | 描述与网站 |

## 替换候选

以后可按真实 App Store Connect 表现选择替换词，一次只改少量词，并重新计算字节。可测试 `offline`、`import`、`queue`、`loop`、`文件夹播放`、`本地音频`、`导入音乐`。这些是候选，不代表已验证高流量。

中文优先考虑“手表离线播放”这类明确意图，英文优先补充 `local`、`transfer`、`folders`；名称和副标题已经表达的相同词，不再占用关键词预算。英文单复数不重复堆叠。

未纳入的词包括：在线音乐、免费下载歌曲、云同步、后台传输、远程控制、歌词、流媒体、竞品名称、歌手姓名、无依据的“最好/第一”。它们与当前功能不符，或不适合作为关键词。

Apple 的字段参考以 **100 bytes** 限制关键词；产品页指导用 100 characters 概括。这里同时统计字符和 UTF-8 字节，满足两者。关键词间用英文逗号，不在逗号后加空格。[字段规范](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)、[搜索发现指导](https://developer.apple.com/app-store/search/)。
