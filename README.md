# QuotaBar

本地 macOS 菜单栏应用，可视化 **Codex** 剩余配额与 **Cursor Pro** 用量。

仿照 [QuotaDot](https://github.com/MeowkingCP/QuotaDot) 的思路：只读本地登录态，直接请求各服务端的用量接口，不经过任何中继服务器。

## 功能

- 菜单栏常驻：显示各 Provider 中**最低剩余百分比**
- 下拉面板：
  - **Codex**：Session（短窗口）与 Weekly 环形进度、重置倒计时、套餐类型
  - **Cursor**：当前计费周期 Plan / Auto / API 等用量环与金额摘要
- 每 **5 分钟**自动刷新，面板内可手动刷新
- 某一 Provider 失败不影响另一个

## 要求

- macOS 14+
- Xcode Command Line Tools / Swift 6
- 本机已登录 Codex（`~/.codex/auth.json`）和/或 Cursor IDE

## 构建与运行

```bash
cd QuotaBar
chmod +x script/build_and_run.sh
./script/build_and_run.sh debug --run
```

仅构建：

```bash
./script/build_and_run.sh
# 产物：.build/QuotaBar.app
open .build/QuotaBar.app
```

命令行冒烟测试（不启动菜单栏 UI）：

```bash
swift build
.build/debug/QuotaBar --smoke-test
```

## 鉴权说明

| Provider | 来源 | 接口 |
|----------|------|------|
| Codex | `~/.codex/auth.json` 的 `access_token` | `GET https://chatgpt.com/backend-api/wham/usage` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 中的 `cursorAuth/accessToken` | `GET https://cursor.com/api/usage-summary`、`POST https://cursor.com/api/dashboard/get-current-period-usage` |

可选环境变量：

```bash
export CURSOR_SESSION_TOKEN='user_…::eyJ…'   # 或浏览器 Cookie WorkosCursorSessionToken 原值
export CODEX_HOME="$HOME/.codex"             # 可选，默认 ~/.codex
```

若 Cursor 本地 token 失效，可在 [cursor.com/dashboard](https://cursor.com/dashboard) 登录后，从 DevTools → Application → Cookies 复制 `WorkosCursorSessionToken` 设为环境变量再启动。

## 项目结构

```text
Sources/QuotaBar/
  App/         MenuBarExtra 入口
  Models/      统一用量模型
  Services/    Codex / Cursor 客户端
  Stores/      刷新与状态
  Views/       菜单栏标签与下拉面板
```

## 隐私与风险

- 凭证只读本地文件，请求直达官方域名，无第三方上传。
- Codex / Cursor 用量接口均为非公开、可能变更的内部 API；字段变动时部分圆环可能暂时无法解析。
- 本项目与 OpenAI、Cursor 无关，相关商标归属其所有者。

## License

MIT
