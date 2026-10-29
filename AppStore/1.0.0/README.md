# WatchMusic 1.0.0 上架交付

打开 `index.html`：浏览标题图、搜索图、手机和手表截图，直接复制中英文名称、副标题、推广文本、描述和关键词。详细填写步骤在 `submission-guide.md`。

## 交付目录

- `screenshots/zh-Hans/iphone`：4张中文短文案截图，1320×2868。
- `screenshots/en-US/iphone`：4张英文短文案截图，1320×2868；实际App界面仍为简中。
- `screenshots/watch`：4张原生Watch界面，422×514，两种商店语言共用。
- `creative/header-*.png`：中英文标题图，3840×1646。
- `creative/search-*.png`：中英文搜索结果图，1920×1280。
- `screenshots/raw`、`capture-notes.md`：真实UI来源及原创演示内容说明。
- `metadata-*.md`、`metadata.json`：商店字段；`keyword-bank.md` 为相关备用词，不能全部塞入关键词栏。
- `manifest.json`：正式16张上传图片的尺寸、SHA-256与用途。
- `qa`：网页响应式检查截图与验证记录，不用于App Store上传。

## 网站与素材分开使用

网站部署只用 `Artifacts/Deployment/watchmusic-marketing-1.0.0.zip`，内含四个自包含HTML。上架素材使用 `Artifacts/Deployment/watchmusic-appstore-1.0.0.zip`，不需要把素材包部署到网站。

## 维护

- 原创封面/音频：`tools/capture-cover.swift`、`tools/capture-fixtures.py`，见来源说明。
- 手表PNG格式导出：`swift AppStore/1.0.0/tools/export-watch-rgb.swift`。
- 手机与创意排版源：`creative/exports.html`，参数 `type=header|search|screen`、`lang=zh|en`、`n=1…4`；以表中目标尺寸用浏览器导出，不额外缩放源截图。
- 预览页/结构化字段：`python3 AppStore/1.0.0/tools/generate-gallery.py`。
- 检查并生成清单：`python3 AppStore/1.0.0/tools/validate-package.py`。
- 打包：`bash AppStore/1.0.0/package.sh`。

当前交付只创建网页与宣传资料，未修改App行为，未发布网站或提交App Store。请在App Store Connect预览标题/搜索位的最终裁切，使用真实域名、下载链接和审核联系人电话。
