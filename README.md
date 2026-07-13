# Qi Day Flow

Qi Day Flow 是一个 Windows 本地优先的屏幕活动时间流。它以低帧率录制当前活动窗口所在的显示器，再调用用户配置的 OpenAI Chat Completions 兼容视觉接口，把零散的屏幕活动整理为可搜索、可编辑的时间轴。

项目仍处于早期阶段。目前只支持 Windows，界面和文档以中文为主。

本项目源于：https://github.com/JerryZLiu/Dayflow.git 和 https://github.com/SeiShonagon520/Dayflow.git

之所以取名 QiDayflow 是为了搜索引擎区分

**如果你喜欢，请不要忘记去原作者仓库Start**

## 它能做什么

- 每秒采集一帧当前活动窗口所在显示器，按约 60 秒生成 H.264 MP4 切片。
- 从每个切片内存抽取最多 8 张 JPEG 关键帧，不创建临时截图文件。
- 使用兼容 OpenAI Chat Completions 的视觉模型生成观察记录和活动卡片。
- 在本地 SQLite 中保存队列、分析结果、时间轴、日报和设置。
- 把连续、同类且主应用一致的活动合并，避免一分钟一条的碎片化记录。
- 展示正在分析、等待和失败的任务，并支持手动重试。
- 分析请求遇到可重试故障时默认自动重试 3 次，并可在设置中调整为 0–5 次。
- 统计活动时长、效率、应用使用和 CPU/内存指标。
- 在系统托盘开始或停止录制；关闭主窗口后应用继续驻留托盘。
- 启动后以 5 秒超时静默检查 GitHub Release；发现新版本时在设置入口提示，并由用户决定是否打开下载页。

## 隐私说明

这个应用会录制屏幕。使用前请确认你有权采集画面中出现的内容，并遵守所在地法律、组织政策和软件服务条款。

Qi Day Flow 的边界如下：

- 不记录键盘内容、鼠标轨迹、点击或音频。
- MP4 保存在本机，不会直接上传。
- 模型请求包含最多 8 张关键帧，以及前台应用、进程和窗口标题。
- API 密钥使用当前 Windows 用户的 DPAPI 加密后写入本地 SQLite。
- 日志不接受 API Key、Authorization、JPEG/base64 或窗口标题字段。
- 默认 INFO 日志不会逐帧记录；DEBUG 模式只记录经过白名单限制的帧元数据。
- 已完成的视频和 JSON 只有在用户确认清理或缓存达到上限时才会删除。等待、处理中和失败任务的证据会保留。
- 启动时会向 GitHub Releases API 发送一次不含屏幕内容、窗口信息、API Key 或用户数据的版本检查请求；失败不会影响录制和分析。

不要在包含密码、聊天记录、医疗或财务信息的屏幕上进行测试，除非你明确接受这些关键帧会被发送到所配置的模型服务。

## 系统要求

- Windows 10 或更高版本
- Flutter 3.44.6
- Dart 3.12.2
- Visual Studio 2026，安装“使用 C++ 的桌面开发”工作负载
- Windows SDK
- 支持视觉输入的 OpenAI Chat Completions 兼容接口

项目不包含 Android、iOS、Linux、macOS 或 Web 平台工程。

## 开始开发

```powershell
git clone <your-fork-or-repository-url>
cd qi_day_flow
flutter pub get
flutter run -d windows
```

首次启动后，在设置页填写：

1. API URL
2. API Key
3. 模型名称
4. AI 分析失败后的自动重试次数（默认 3）
5. 用户数据目录（可选）

未设置模型时默认使用 `gpt-5.4-mini`。这只是默认配置，模型是否存在以及是否支持图像输入取决于你的服务提供方。

## 构建和测试

```powershell
dart format .
flutter analyze --no-pub
flutter test
flutter build windows --release
```

Release 产物位于：

```text
build\windows\x64\runner\Release\
```

原生回归测试是 CMake 的显式目标，不会随默认 Flutter 构建自动运行：

```powershell
cmake --build build\windows\x64 --config Debug --target `
  qi_day_flow_capture_pixel_buffer_test `
  qi_day_flow_capture_runtime_test `
  qi_day_flow_frame_similarity_test `
  qi_day_flow_native_frame_logger_test `
  qi_day_flow_tray_menu_state_test `
  qi_day_flow_startup_behavior_test
```

然后运行 `build\windows\x64\runner\Debug\` 下对应的测试程序。

## 自动发布

推送任意 Git tag 会触发 `.github/workflows/release.yml`。流水线在
`windows-2022` runner 上完成格式检查、静态分析、Flutter 测试、六组原生回归测试和
Windows x64 Release 构建，然后：

- 打包完整运行目录为 `QiDayFlow-<tag>-windows-x64.zip`；
- 生成对应的 `.zip.sha256` 校验文件；
- 将二者保存为 GitHub Actions artifact；
- 创建同名 GitHub Release，并自动生成发布说明；
- tag 名包含 `-` 时，将 Release 标记为 prerelease。

例如：

```powershell
git tag v0.1.0
git push origin v0.1.0
```

发布工作流只使用 GitHub 自动提供的 `GITHUB_TOKEN`，不需要额外配置仓库密钥。

## 数据目录

默认数据目录：

```text
%LOCALAPPDATA%\QiDayFlow\
├── qi_day_flow.db
├── qi_day_flow.db-wal
├── qi_day_flow.db-shm
├── logs\
│   ├── qi_day_flow.log(.1-.3)
│   └── native-capture.log(.1-.3)
└── captures\
    ├── chunk_<session>_<time>_<sequence>.mp4
    └── chunk_<session>_<time>_<sequence>.json
```

设置页配置的是用户数据目录，采集路径始终派生为 `<用户数据目录>\captures`。更改数据目录后，数据库会在下次启动时迁移。目标位置已有其他数据库时，应用会拒绝覆盖。

## 工作原理

1. 原生 C++ 使用 `GetForegroundWindow` 和 `MonitorFromWindow` 找到活动窗口所在显示器。
2. DXGI Desktop Duplication 采集该显示器，并通过 WIC 等比缩放到 1920×1080 BGRA 画布。
3. Windows Media Foundation 将画面编码为 1 FPS H.264 MP4。
4. Dart 把切片写入 SQLite 分析队列。
5. Media Foundation Source Reader 解码关键帧，WIC 在内存中压缩 JPEG，再通过 MethodChannel 传给 Dart。
6. 模型先生成 observations，再生成 timeline cards。两阶段响应都经过严格字段、区间、枚举和评分校验。
7. 合法结果在单个 SQLite 事务中提交；连续且相同的活动在持久化层合并。

屏幕像素和视频解码只在 C++ 中处理。完整 MP4 不进入 Dart。

## 架构

```text
lib/
├── core/                     # 领域模型、仓储契约、平台路径
├── data/                     # SQLite schema、迁移和仓储实现
├── services/
│   ├── logging/              # Dart 日志、大小统计和安全清理
│   ├── native/               # MethodChannel、DPAPI、图标和 MP4 抽帧
│   ├── openai/               # 视觉 API、传输和严格 JSON 校验
│   ├── processing/           # 分析队列、失败恢复和缓存轮转
│   ├── reports/              # 日报
│   ├── statistics/           # 统计口径
│   └── update/               # GitHub Release 版本检查
└── features/presentation/    # Flutter Windows 界面

windows/runner/
├── capture_service.*         # DXGI、Media Foundation、WIC 和窗口追踪
├── native_bridge.*           # Flutter 通道、路径校验和 DPAPI
├── native_frame_logger.*     # 低开销逐帧 DEBUG 日志
└── tray_menu_state.*         # 托盘录制状态映射
```

原生 worker 不直接调用 Flutter EventSink。事件先进入线程安全队列，再通过 `PostMessage` 回到 Windows 平台线程。

## 关键设计约束

- 新切片固定使用 `active-window-display` 采集范围、1920×1080 输出、1 FPS 和约 60 秒时长。
- 显示器切换、拓扑变化、暂停、空闲、错误和停止会先提交已有帧的部分切片。
- MP4 使用 `.partial.mp4` 临时文件，视频和 JSON 都在完成后原子提交。
- 单张 JPEG 最大 2 MiB，单次请求的图像载荷最大 12 MiB。
- 分析成功前不清理原始证据；事务失败会回滚 observations、cards 和状态。
- 时间轴只在同一天、间隔不超过 120 秒、标题/分类/主应用一致时合并。
- 应用时长求和，资源均值按应用时长加权，峰值取最大，效率按源卡片时长加权。
- 原生编码只使用 Windows 系统组件，不依赖 FFmpeg 或 OpenCV。

## 贡献

欢迎提交 issue 和 pull request。提交代码前请运行：

```powershell
dart format .
flutter analyze --no-pub
flutter test
flutter build windows --release
```

涉及录屏、文件删除、路径迁移、API 请求或密钥处理的改动，应包含对应的失败路径测试。请勿提交真实录屏、数据库、日志、API Key、用户路径或其他个人数据。


## 许可证

Qi Day Flow 使用 [MIT License](LICENSE)。
