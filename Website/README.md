# 网站与协议网页

以下为“随身音乐”可直接部署的静态网页，同时也是 iPhone 应用离线显示的协议来源：

| 用途 | 源文件 | 部署后的路径示例 |
| --- | --- | --- |
| 隐私协议 | `PhoneApp/Legal/privacy.html` | `/privacy.html` |
| 用户协议 | `PhoneApp/Legal/terms.html` | `/terms.html` |
| 技术支持 | `PhoneApp/Legal/support.html` | `/support.html` |

三个文件均为 UTF-8 HTML，CSS 内联，无 JavaScript、外部字体、统计、广告、Cookie 或运行时依赖，跟随系统深浅色模式；可以放在域名根目录或同一个子目录下。保留文件名及相对位置，页面之间的链接即可正常工作。应用内读取随安装包附带的相同文件，无需先填入线上域名。

## 营销首页与四页部署（推荐）

营销站点源文件在 `Website/marketing/`，完整说明见该目录 README。运行：

```sh
bash Website/package-marketing.sh
```

输出 `Artifacts/Deployment/watchmusic-marketing-1.0.0.zip`，严格包含四个自包含 HTML：营销 `index.html`、`privacy.html`、`terms.html`、`support.html`。首页图片已内嵌，无需额外图片目录。四个文件一起上传到同一网站目录；营销网址填首页 HTTPS 地址，技术支持与隐私网址继续使用对应页面地址。

App Store 文案、手机/手表统一尺寸截图、标题及搜索结果创意在 `AppStore/1.0.0/`，打开该目录 `index.html` 可预览与复制字段。

## 仅协议与支持页打包

在项目根目录运行：

```sh
bash Website/package.sh
```

输出：`Artifacts/Deployment/watchmusic-web-2026-10-29.zip`。压缩包包含三个 HTML 文件，并以技术支持页的副本作为 `index.html`，不包含源码、音频、日志或任何设备数据。将压缩包内容解压到你的静态网站目录即可，无需执行构建命令。

也可直接复制 `PhoneApp/Legal/` 下的三个 HTML 文件到现有网站。服务器应使用 `text/html; charset=utf-8` 提供这些文件，建议使用 HTTPS。若部署在子目录中，示例链接为 `https://你的域名/子目录/privacy.html` 和 `https://你的域名/子目录/support.html`。

在 App Store Connect 中，将“隐私政策网址”设置为你实际部署的 `privacy.html` 地址，将“技术支持网址”设置为 `support.html` 地址。本仓库不会自动发布这些网页。

## 维护

- 当前协议版本和生效日期为 **2026-10-29**。应用同意流程与 HTML 的 `document-version` 使用同一版本。
- 开发者为 **李浩（个人开发者）**，技术支持与隐私联系邮箱为 **2114581274@qq.com**。网页首选通过 `mailto:` 唤起邮件客户端；[GitHub Issues](https://github.com/blueautume/WatchMusic/issues) 保留为一般功能问题的公开入口。若需更换开发者名称或联系渠道，应同步修改三份 HTML 和应用“关于”信息。
- 修改 HTML 后重新打包并重新构建应用，保证网页和离线副本一致；涉及数据处理或协议的重要变更应同步更新应用的协议版本。
- 网站本身没有数据提交或跟踪代码；实际托管商可能记录网站访问日志，请根据最终托管配置核对协议中关于网站日志的描述。

运行 `python3 Tests/check-legal-pages.py` 检查协议版本、离线资源约束、页面链接/锚点及部署包与源文件一致性；可增加 `--bundle /绝对路径/WatchMusic.app` 同时核对编译后的应用内文档。

## 本地预览

在项目根目录运行：

```sh
python3 -m http.server 8096 --bind 127.0.0.1 --directory PhoneApp/Legal
```

在浏览器打开 `http://127.0.0.1:8096/support.html`，可检查三个页面的互链、窄屏布局、深浅色与打印样式。按 `Ctrl+C` 停止预览。
