# 交付检查 · 2026-10-29

- 浏览器检查的是最终部署ZIP解压出的四页（本地HTTP），不是只看源HTML。
- 营销首页：320、390、768、1440 px视口未出现横向溢出；3张本地图均加载成功。
- 系统深浅色模拟均通过；桌面深色、手机浅色截图附本目录。
- 中英文切换后lang/title/可见文案更新；英文FAQ可展开，含前台传输要求。
- 首页至privacy/terms/support导航均打开对应页面；相对链接在同目录部署生效。
- 浏览器console无warning/error；网站不加载外部图片、脚本或字体，不含分析请求。
- 部署zip严格只有4个HTML，图片与favicon内嵌；legal三页与PhoneApp/Legal原件一致。
- 素材总览：图片均加载，10个可复制文本字段均存在。
- 16张正式上传PNG核对尺寸、8bit RGB、无Alpha；手表与原始UI按sRGB逐像素一致。
- 关键词zh-Hans为98 UTF-8 bytes，en-US为99；其他字段均符合长度上限。
- 当前任务没有修改App运行逻辑，没有安装或操作真机，没有部署网站或提交App Store。

运行复核：`python3 AppStore/1.0.0/tools/validate-package.py`。
