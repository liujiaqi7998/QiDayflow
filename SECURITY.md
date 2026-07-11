# Security policy

## Supported versions

Qi Day Flow 目前处于早期开发阶段。安全修复只针对 `master` 分支的最新代码。

## Reporting a vulnerability

请通过仓库所有者提供的私密安全报告渠道（例如 GitHub Security Advisories 的 "Report a vulnerability"）提交问题。不要在公开 issue 中包含以下内容：

- API Key、Authorization header 或其他凭据
- 真实录屏、关键帧、窗口标题或个人数据
- 本地数据库、日志或用户目录
- 可直接利用的任意文件读写或路径越界细节

报告中请说明受影响版本、复现条件、潜在影响和最小化的复现步骤。请使用虚构数据或经过脱敏的测试文件。

如果仓库尚未启用私密漏洞报告，请先创建一个不含利用细节的公开 issue，请求维护者提供私密联系方式。

## Scope

优先处理以下问题：

- 屏幕内容或窗口信息被发送到未配置的目标
- API Key 明文落盘或进入日志
- 采集、日志或缓存清理可访问用户数据目录之外的文件
- 数据目录迁移覆盖已有数据库
- 原生通道绕过录制状态机或安全路径验证
