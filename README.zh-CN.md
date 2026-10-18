# AI Usage

macOS 悬浮额度小组件，展示 Codex、Grok Bot 和 Muse 的剩余额度与自动重置倒计时。当前版本：0.3.7。

## 功能

- 无 Dock 图标；可拖动，限制在屏幕物理边界内。
- 左右边缘磁吸、自动收纳、悬停展开；收纳栏显示各服务百分比。
- 渐变进度条和 `5D 23:52` 倒计时。
- 右键菜单提供刷新、Settings 和退出；可选择显示哪些服务。
- Codex 重置券展示与确认使用（取决于账号接口是否提供）。

## 构建与运行

需要 Apple 芯片 Mac、macOS 14+ 和 Xcode Command Line Tools。

```sh
bash build.sh
open "build/AI Usage.app"
```

构建仅写入项目的 build 目录，不自动安装。可将生成的 App 拖到 Applications。当前为本地签名，未经过 Apple 公证。

## 登录与数据来源

- **Codex**：需要安装并登录 Codex.app，通过其本地 app-server 读取额度。
- **Grok**：需要安装并登录 Grok Bot，读取当前用户本机的登录存储和对应钥匙串项，在内存中解密后请求额度接口。
- **Muse**：通过 Settings 中的登录窗口登录，会话保存在该 App 的 macOS WebKit 存储中。额度查询编号改变时尝试从公开网页脚本自动发现。

每台电脑使用自己的登录账号。仓库不包含任何登录令牌、Cookie、钥匙串数据或个人额度快照。服务内部接口并非稳定的公开 API，上游改版后可能需要适配；读取失败会显示错误而非继续显示旧额度。

## 验证

```sh
"build/AI Usage.app/Contents/MacOS/CodexUsage" --self-test
"build/AI Usage.app/Contents/MacOS/CodexUsage" --drag-self-test
```

验证屏幕边界、磁吸阈值、拖动状态和额度解析。运行正常 App 才会查询真实账号。

## 文件

- `Sources/`：Swift/AppKit 源码及三家服务适配。
- `Resources/`：App 元数据与图标。保留原 bundle ID 以兼容已有设置及 Muse 会话。
- `使用说明.md`：使用说明和版本记录。
