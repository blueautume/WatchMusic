# WatchMusic 营销网站

可直接部署的静态网站，无构建工具、外部字体、远程图片或第三方脚本。默认简体中文，右上角可切换英文；跟随系统深浅色模式。英文切换只作用于营销首页，现有隐私、用户协议与技术支持页面为中文。

## 文件

- `index.html`：营销首页，内联 CSS 与少量语言切换 JavaScript；禁用 JavaScript 时仍能完整浏览中文内容。
- `assets/app-icon.png`：项目现有正式蓝色图标。
- `assets/phone-player.png`、`assets/watch-player.png`：当前版本模拟器真实界面，使用原创演示音乐。
- 这些图片只用于维护源码；打包时自动将图标、favicon 和两端截图转成 Base64 内嵌到首页，无需部署 `assets` 目录。
- 打包时从 `PhoneApp/Legal` 原样复制 `privacy.html`、`terms.html`、`support.html`，保证页内链接在部署包内有效。

## 打包与部署

在项目根目录运行：

```sh
bash Website/package-marketing.sh
```

打包需要 Python 3 标准库与系统 `zip`，不需要安装第三方依赖。

输出 `Artifacts/Deployment/watchmusic-marketing-1.0.0.zip`，压缩包内**只有四个自包含 HTML 文件**：

- `index.html`：营销首页，所有图片、CSS 与 JavaScript 已内嵌。
- `privacy.html`：隐私政策。
- `terms.html`：用户协议。
- `support.html`：技术支持。

解压后将四个 HTML 一起上传到同一个网站目录即可，无需图片文件夹、构建或 Node 服务。每一页自身没有外部图片、字体、样式表或脚本请求；页面间通过相对链接跳转。

App Store Connect 的“营销网址”填写部署后的首页 HTTPS 地址，例如你实际网站的根地址或营销子目录地址。项目没有预设域名；不要把示例、本地预览地址或 ZIP 下载地址填写为营销网址。

四页可以部署在已使用的同一个网站。已有技术支持、隐私与协议页面地址相同时可直接沿用，营销网址填写首页地址。上传前如需保留服务器上的修改，请先备份原页面；打包文件使用仓库中的当前法律与支持内容。

## 正式上架后的下载入口

当前没有提供可验证的 App Store 公开链接，因此主按钮为“了解使用方式”，跳转页内使用指南。这样不会出现失效的下载按钮。

取得应用真实链接（`https://apps.apple.com/.../id真实数字ID`）后，可把 `.hero-actions` 内主链接的 `href="#start"` 替换为该链接，同时将按钮中文改为“在 App Store 获取”、英文改为“Get it on the App Store”。若使用官方 App Store 徽章，请采用 Apple 提供的原始徽章并遵守其营销规范，不要自行绘制近似徽章。

## 内容边界

网站描述 1.0.0 已实现的功能：MP3/FLAC 导入、目录管理、前台局域网排队传输、手表独立离线播放、睡眠定时、播放速度、播放模式和系统音量控制。明确传输需要两端保持 App 打开，未宣称后台持续传输、跨设备播放控制、在线曲库、音乐下载或网络加密。

页面截图里的音乐为原创演示素材，不代表应用内置曲库。实际 App 由用户自行导入音频。

本次只交付静态文件，没有发布网站，也没有修改 App Store Connect 已填写的信息。
