# QiDayFlow 时间轴、采样频率与 AI 相似帧过滤实施计划

日期：2026-07-13
状态：调研完成，待确认后实施
范围：Windows-only Flutter/Dart + C++ runner

## 1. 现状与约束

### 时间轴

- `lib/data/repositories/sqlite_day_flow_repository.dart:822-831` 的 `listCardsForReportDate` 固定按 `started_at_ms ASC` 返回。
- `lib/features/presentation/app_controller.dart:830-838` 原样映射到 `timelineCards`。
- `lib/features/presentation/pages/timeline_page.dart:36-47` 目前只做搜索过滤，不做排序。
- 页面已有统一分类颜色入口 `categoryColor(...)`，位于 `lib/features/presentation/app_theme.dart:167`。
- 每张卡片已有开始、结束时间和 `duration`，当日类别分布不需要新增数据库查询。

### 捕获频率

- 产品当前固定为 1920×1080、1 FPS、60 秒 MP4 切片：`lib/services/native/capture_video_spec.dart:1-5`。
- `AppSettings` 虽然持久化 `captureFps`，但 `AppController.startCapture()` 实际始终传固定 `captureFramesPerSecond`，用户设置没有生效。
- C++ bridge 和 capture service 均硬性拒绝非 1 FPS：
  - `windows/runner/native_bridge.cpp:1171-1188`
  - `windows/runner/capture_service.cpp:1274-1283`
- C++ 捕获循环本身使用 `1.0 / config_.fps` 安排下一帧，理论上能支持低于 1 FPS；但 Media Foundation 编码参数、元数据和切片结束条件仍固定为 1 FPS。
- 当前切片按“写满 60 帧”结束。若只把 FPS 改成 `1/30`，第二帧在 30 秒时就会被错误当成 60 秒切片完成，不能直接改小数 FPS。

### AI 图片输入

- 原始证据是完整 MP4，不应因 AI 成本优化而丢弃。
- `ChunkEvidenceReader` 调用原生 `extractVideoFrames`，当前每个 60 秒切片均匀抽取最多 8 张 JPEG。
- 原生抽帧已经把 Media Foundation RGB32 转为 BGRA，再编码 JPEG；这是最低成本的视觉相似度判断位置。
- `OpenAiAnalysisService` 把每张 JPEG 作为 `detail: high` 的 data URL 发送，因此过滤一张图片能直接减少上传、视觉 token 和 API 成本。

## 2. 功能一：时间轴默认倒序并允许选择排序

### 产品行为

- 新增 `TimelineSortOrder`：
  - `newestFirst`：最新优先，页面默认值。
  - `oldestFirst`：最早优先。
- 排序选项属于当前页面的展示状态，不写入全局设置；重新启动应用回到用户要求的默认倒序。
- 切换日期、搜索或数据刷新后保持当前页面已选择的排序方式。
- 排序键保持确定性：
  - 最新优先：`startedAt DESC, endedAt DESC, id DESC`。
  - 最早优先：`startedAt ASC, endedAt ASC, id ASC`。
- 先过滤再排序或先排序再过滤结果等价；实现上建议复制列表后排序，绝不修改 ViewModel 暴露的原列表。

### UI

- 在搜索框同一工具行增加带文本的排序菜单/下拉框，显示“最新优先”或“最早优先”。
- 窄窗口使用 `Wrap` 或搜索框下方一行，禁止依赖固定宽 Row。
- 提供 tooltip、语义标签和键盘可操作性。

### 测试

1. 输入乱序卡片，首次渲染顺序为最新到最早。
2. 选择“最早优先”后顺序反转。
3. 相同开始时间使用结束时间和 ID 稳定排序。
4. 搜索后仍遵守当前排序。
5. 600–800 px 窄窗口无 overflow。

## 3. 功能二：时间轴新增当日类别分布

### 数据口径

- 数据来自所选日期的全部 `timelineCards`，不受搜索框影响。
- 每个类别时长为该类别所有卡片 `duration` 之和。
- 占比为 `categoryDuration / allCategoryDuration`。
- 过滤非正时长；总时长为零时显示空态，不计算 NaN/Infinity。
- 不读取统计页的 7/30 天聚合，避免口径和刷新时机错位。

### UI

- 放在时间轴头部和搜索工具行之间，使用紧凑卡片：
  - 标题“当日类别分布”。
  - 一条横向堆叠条，颜色复用 `categoryColor`。
  - 下方可换行的类别项：颜色、类别名、时长、百分比。
- 类别顺序按时长降序；同值按类别名排序，保证稳定。
- 每个 segment 同时提供 tooltip 和 Semantics label，例如“编程，2 小时 15 分钟，占当日 63%”。
- 空数据时显示“这一天还没有可统计的活动”。

### 测试

1. 同类别多卡片正确求和。
2. 分布使用全部当日卡片，不随搜索过滤变化。
3. 百分比总和显示误差可控；内部值不做过早四舍五入。
4. 零时长无异常。
5. 分类颜色与现有卡片一致。
6. 鼠标、键盘、触摸和语义树均可发现类别、时长和占比。

## 4. 功能三：用户可选截图频率

### 数据模型

不要继续用 `captureFps` 表达 10/20/30 秒一次。新增明确字段：

```text
captureIntervalSeconds ∈ {1, 10, 20, 30}
```

兼容旧设置：

- `fromJson` 同时接受旧 `captureFps` 和新 `captureIntervalSeconds`。
- 新字段存在时优先。
- 只有旧字段时映射到 1 秒；旧值即使是 2–10，也因现有 Controller 从未使用而按实际历史行为迁移为 1 秒。
- `toJson` 只写新字段；读取旧设置后下一次保存自动完成迁移。
- 默认值保持 1 秒，避免升级后静默降低采集密度。

### UI 和运行时语义

- 设置页采集区域新增四档单选/下拉：1 秒、10 秒、20 秒、30 秒。
- 辅助说明：频率越低，本地视频体积、CPU 和 AI 候选图片越少，但短暂活动可能不被图像捕获。
- 录制中修改不重启、不截断当前切片；下次开始录制时生效，并明确显示该提示。
- `SettingsDraft`、`SettingsViewData` 和保存流程完整携带该字段。

### 原生配置

推荐把 method channel 和 C++ 配置也改为 `captureIntervalSeconds`，避免浮点 FPS：

```text
CaptureConfig.capture_interval_seconds: uint32_t
```

必须把图像采样和窗口元数据采样解耦：

- 图像/MP4 帧按用户选择的 1/10/20/30 秒采样。
- 前台窗口、进程、CPU 和内存资源元数据继续约每 1 秒采样，不能随截图间隔降频。
- 元数据采样不应触发 GPU Desktop Duplication 取帧或 H.264 编码。
- 暂停、空闲暂停和停止时两个节拍都应一起停止；恢复后重新建立各自 deadline，避免补采或 burst。

否则选择 30 秒会把应用归属和时间轴时长精度从约 1 秒退化到 30 秒，属于不可接受的功能回退。

Media Foundation 参数：

- frame rate numerator = 1
- frame rate denominator = intervalSeconds
- frame duration ticks = 10,000,000 × intervalSeconds

必须把“切片结束”从帧数驱动改成单调时钟驱动：

- 每个切片覆盖约 60 秒真实时间。
- 在下一次采样前若当前切片已达到 60 秒，先 finalize，再将该采样作为新切片首帧。
- 停止录制时继续允许不足 60 秒的 partial chunk。
- 期望常规帧数分别约为 60、6、3、2，但不得再用这些数字直接决定 wall-clock 切片边界。
- 元数据 schema 升级为 v4，写入 `captureIntervalSeconds`；读取器继续兼容 schema v3 的固定 1 FPS 文件。

### 测试

1. 设置 JSON 新字段 round-trip 与旧 `captureFps` 迁移。
2. UI 仅允许 1/10/20/30。
3. Controller 确实把选中间隔传给 native service。
4. C++ 配置拒绝其他值。
5. 60 秒常规切片在四档下的真实 duration、帧时间戳和帧数合理。
6. 暂停/恢复、显示器切换、停止时 partial chunk 不回退。
7. schema v3 旧视频仍可分析；schema v4 元数据规格校验通过。
8. 用 Media Foundation 读取实际四档 MP4，验证 duration、非黑帧和可抽帧性。

## 5. 功能四：相邻相似帧不送 AI

### 放置位置

在 `CaptureService::ExtractVideoFrames` 的 RGB32/BGRA 解码完成后、JPEG 编码前过滤。

保留：

- 原始 MP4。
- 所有 window context、进程和资源元数据。
- 至少一张关键帧。

只减少：

- JPEG 编码数量。
- Dart 内存中的关键帧数量。
- OpenAI 请求中的 `image_url` 数量。

### 候选与输出

- 最终 AI 图片上限继续为 8。
- 1 秒采样时，先在整段中均匀选最多 24 个候选，再从中保留最多 8 个视觉上有意义的帧；这样重复画面不会占满 8 个名额。
- 10/20/30 秒档候选数不超过实际帧数。
- 第一候选永远保留。
- 后续候选与“上一个已保留帧”比较，而不是与上一个候选比较，确保 A→B→A 都能被识别为变化。
- 若过滤后只有一张，允许只向 AI 发送一张；当前输入校验已允许 1–8 张。

### 低成本视觉特征

实现无第三方依赖的纯 C++ 特征函数：

1. 从 BGRA 按网格采样/缩小到 64×36 或 96×54 灰度亮度图。
2. 同时计算：
   - 平均绝对亮度差（MAD）。
   - 超过局部差阈值的采样点比例（changed-pixel ratio）。
3. 只有两个指标都低于阈值时才判定“高度相似”。

不使用：

- 文件 SHA-256：压缩噪声和微小变化会导致完全不同。
- 单独 dHash：对小弹窗和局部文字变化可能过于迟钝。
- 完整 SSIM/OpenCV：依赖和计算成本对当前用途不划算。

### 阈值策略

不直接把未经验证的数字作为生产阈值。先做独立 C++ spike/harness，使用合成或脱敏测试帧测量分布：

- 完全相同。
- 仅鼠标光标移动。
- 时钟数字变化。
- 单行代码/文本变化。
- 小型通知/弹窗。
- 页面滚动。
- 应用切换。
- 视频播放。
- 黑帧/解码异常。

初始实验区间（仅用于校准，不是最终常量）：

- MAD：1–3 / 255。
- changed-pixel threshold：绝对亮度差 10–16。
- changed-pixel ratio：0.3%–1.0%。

选择标准：

- 完全相同和仅光标移动大部分被跳过。
- 单行文字变化、小弹窗、滚动、应用切换必须保留。
- 单次比较目标 < 5 ms（Release，1080p 输入，测试机）。

若窗口上下文在候选时间点发生变化，则保守地强制保留，即使像素指标接近；可以由 Dart 从 metadata 的 window segments 生成受保护 offset 并传给 native extractor，或在 native extractor 接收对应 offset 列表。

### 可观察性与隐私

每个切片记录不含内容的计数：

```text
candidateFrames
selectedFrames
skippedSimilarFrames
similarityAlgorithmVersion
```

只进受管理日志或 extraction result，不记录截图、窗口标题、文件完整路径或像素特征。

### 失败降级

- 特征计算失败：保留候选帧，不得丢帧。
- 阈值配置异常：关闭过滤并保留原有最多 8 帧行为。
- 过滤绝不让关键帧为空。
- 旧 JPEG schema 1 证据保持现有行为，首版只优化 MP4 schema 3/4。

### 测试

1. 纯 C++ 特征函数单元测试。
2. 相同帧只保留首帧。
3. A→A→B→B→A 得到 A/B/A。
4. 小弹窗和单行文字变化保留。
5. 仅光标变化按校准目标跳过。
6. 失败时 fail-open。
7. 输出始终 1–8 张，时间戳递增且在切片范围内。
8. API 请求 fixture 证明确实减少 `image_url` 数量。
9. 真实 MP4 harness 比较过滤前后图片数量、CPU 时间、JPEG 总字节和 SHA-256，不读取用户 AppData。

## 6. 推荐实施顺序（拆分 Codex 任务）

### Task A：时间轴 UX（低风险）

- 先写 Widget RED 测试。
- 实现默认倒序、排序菜单、当日类别分布、响应式和 semantics。
- 只改 Flutter presentation/test 文件。

验证：format、analyze、timeline focused tests、全量 Flutter tests。

### Task B：采样间隔与 schema v4（高风险）

- 先覆盖设置迁移、method channel contract、C++ chunk runtime RED tests。
- 实现 `captureIntervalSeconds` 全链路。
- 用实际 MP4 做四档生产链路 harness。

验证：Dart tests、四组现有 native tests、新 native interval tests、Release build、真实 MP4 抽帧。

### Task C：AI 相似帧过滤（独立可回滚）

- 先做 C++ spike 校准阈值并保存 benchmark 结果。
- 阈值满足标准后，落到 extraction pipeline。
- 默认启用保守算法；发生异常 fail-open。

验证：pure C++ tests、extractor integration test、Dart request fixture、Release build、成本对比。

每个 Task 独立调用 Codex，禁止提交/推送；主代理在每个 Task 后独立审查 diff 和执行完整验证。不要让一个 Codex 会话同时修改 A/B/C。

## 7. 完成定义

- 时间轴首次打开和每次应用重启均为最新优先，用户可切换最早优先。
- 当日类别分布与真实卡片时长一致，不受搜索影响，窄窗口和辅助技术可用。
- 设置只出现 1/10/20/30 秒，保存后下次录制真实生效。
- 四档生成的 60 秒 MP4 时间轴、元数据和抽帧均正确，旧 schema 可读。
- 高相似候选帧不会进入 AI 请求，原始 MP4 不被删除或降质。
- 相似度算法有基准数据，不依赖魔法阈值，失败时保守保留帧。
- 所有 Flutter/native 测试、静态分析和 Windows Release 构建通过。
