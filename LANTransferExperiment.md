# 局域网传输实验

分支：`experiment/lan-transfer`，从 `main` 的 `3fd5c71` 派生。

## 使用

1. 用此分支构建并安装 iPhone 与 Apple Watch 两端实验 App。
2. 两台设备连接能互相访问的同一 Wi-Fi 局域网，在两端打开 App。
3. 手机进入“传输”，选择“局域网”，然后从歌曲菜单或目录发送音乐。
4. 手机显示接收进度、估算速度和剩余时间，手表音乐库显示正在接收的歌曲并提供取消。
5. 等待“已保存到手表”。失败记录可以“重试局域网”或“改用普通传输”。

局域网传输期间手机会暂时保持屏幕常亮，结束后恢复原设置。任一端进入后台会结束本轮局域网传输；普通模式继续使用原来的系统后台传输。手表因腕放下进入 inactive 状态不会主动取消。

## 实现与范围

- 手机使用 Network.framework 临时开启 HTTP 文件服务，仅选择 Wi-Fi 接口，使用随机端口。
- 地址限定私有 IPv4（当前枚举 iPhone 的 `en0`）；IPv6-only、非私有地址和蜂窝网络不在本轮范围内。
- 双方通过配对设备的 WatchConnectivity 交换短期清单与接收进度，手表用 `URLSessionDownloadTask` 主动下载。
- 每批最多 100 首，清单还有 55 KB 上限；会话最多 15 分钟，结束即关闭监听并清除令牌。单个请求无响应时有超时处理。
- 服务仅允许凭会话令牌读取清单内 UUID 对应的音频；拒绝目录浏览、任意路径、重定向和无效请求。音频按 64 KB 分块发送，不整体载入内存。
- 手表验证完整字节数、SHA-256、系统音频解码和可用空间，原子写入成功后才回传保存成功。
- 进度来自手表实际接收字节。100% 后仍需等待校验和保存回执；速度与剩余时间为近期采样估计。
- 取消与原子保存有明确顺序：保存已完成时，随后到达的取消请求不能撤销保存；手机以严格绑定该文件/会话的成功回执修正最终状态。
- 令牌不写进正式日志或传输记录。实验使用本地 HTTP，未提供 TLS 加密，应在可信局域网使用。

“局域网”表示传输端点与协议，**不代表已经强制手表直接使用 Wi-Fi 无线电**。watchOS 仍可能通过配对手机代理请求，实际链路由系统管理。本实验验证可用性，不预设提速倍数。

## 自动验证

```sh
Tests/run-lan-protocol-tests.sh
Tests/run-lan-http-server-probe.sh
Tests/run-lan-receipt-tests.sh
Tests/run-transfer-tests.sh
```

先构建 Debug 并启动一个 watchOS 模拟器，再运行真实 HTTP 下载探针：

```sh
python3 Tests/run-watch-lan-probe.py WATCH_SIMULATOR_UDID \
  --app /absolute/path/to/Debug-watchsimulator/OfflineWatchPlayerLabWatch.app
```

探针启动本机 HTTP 服务，通过仅 Debug 可用的 `-lan-offer-file` 启动参数传入真实清单，检查 MP3/FLAC 下载保存、同大小损坏、HTTP 失败、超出大小及取消后不落盘。它不模拟网络进度，也不替代配对真机的 WatchConnectivity 握手验证。仅测试模式接受 loopback，正式接收清单拒绝 loopback。

仅 Debug 版本支持 `-lan-probe-folder LANProbe-<UUID>`：在手机前台等待配对手表可达后，将该已存在的非空测试目录通过真实局域网流程发送。普通启动不会触发；切入后台会取消等待。

## 真机对照测试

- 先用小 MP3 验证连接，再用较大 FLAC 观察实际吞吐量；分别用普通模式和局域网模式发送同一文件比较。
- 检查路由器是否开启访客网络或客户端隔离；连上相同名称的 Wi-Fi 不一定能互访。
- 检查切后台、断网、单首取消、停止整批、失败后重试及手表空间不足。
- 普通模式与局域网模式不要同时发送相同目标路径；应用也会阻止冲突。
- 模拟器可以验证 HTTP 收发与文件落盘，无法据此判断手表真实无线链路和速度。

## 官方接口依据

- [watchOS 低层网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)：本实现使用允许的 HTTP/HTTPS URLSession，不在手表上使用普通 TCP 或 Bonjour。
- [watchOS 网络路由](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)：请求可能经过 iPhone 代理、Wi-Fi 或蜂窝网络。
- [URLSession 下载进度](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didwritedata:totalbyteswritten:totalbytesexpectedtowrite:))：进度使用真实接收字节。
