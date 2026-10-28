# QuotaDuo

本地 macOS 菜单栏应用，按本机登录态可视化 **Codex**、**Cursor**、**Claude Code**、**Skywork**、**AGY (Antigravity)** 剩余用量与本地 Token 统计。

未登录的服务**不占面板空间**——你只有 Codex + Cursor 时就显示两个；哪天登录了 Claude Code 或 Skywork，刷新后自动多一张卡。

## 功能

- 菜单栏常驻：主指标剩余百分比（如 `C81·X79`，有 Claude 时再加 `·A72`，有 Skywork 时再加 `·S100`）
- 下拉面板（按登录态动态显示）：
  - **Codex**：Session / Weekly
  - **Cursor**：Plan / Auto / API，并区分当前账期 Cursor / 其他模型 token
  - **Claude**：Session（5h）/ Weekly（7d）
  - **Skywork**：可花积分。点击刷新读一次会员 / 充值 / 登录和真实到期；自动刷新只更新合计。专业积分不计入
  - **AGY**：纯本地解析 `~/.gemini` 会话日志（零网络请求、不碰 OAuth），展示今日/账期 Token 总数、Gemini vs Claude 模型分池及账期倒计时环（顶部菜单栏保持精简不加 `Gxx`）
- 每 **5 分钟**自动刷新；失败时**保留上次成功数据**
- 「登录时启动」（需安装到 `~/Applications`）

## 要求

- macOS 14+
- Xcode Command Line Tools / Swift 6
- 本机已登录上述任一服务

## 构建与运行

```bash
cd QuotaDuo
chmod +x script/build_and_run.sh
./script/build_and_run.sh debug --run
```

脚本会构建、安装到 `~/Applications/QuotaDuo.app`（启动前退出旧进程），并可选启动。

```bash
# 仅安装
./script/build_and_run.sh
open ~/Applications/QuotaDuo.app

# 冒烟测试
swift build && .build/debug/QuotaDuo --smoke-test
```

## 鉴权说明

| Provider | 来源 | 接口 |
|----------|------|------|
| Codex | `~/.codex/auth.json` | `GET https://chatgpt.com/backend-api/wham/usage`（token 临近过期或 401 时 OAuth refresh 并写回） |
| Cursor | Cursor `state.vscdb` → `cursorAuth/accessToken` | `usage-summary` / `get-current-period-usage`；token 总数来自 `get-aggregated-usage-events` |
| Claude | `~/.claude/.credentials.json`、Keychain `Claude Code-credentials`，或 `CLAUDE_CODE_OAUTH_TOKEN` | `GET https://api.anthropic.com/api/oauth/usage`（必要时刷新 OAuth） |
| Skywork | Chrome Cookie（首次解密后缓存到 `~/.config/quotaduo/skywork.json`），或 `SKYWORK_COOKIE` | 自动刷新只打 `get_user_benefits`（合计）。点击刷新再打一次 `detail` 读会员 / 充值 / 登录和到期；`630120` 时停止并不再重试，退回合计 |

可选环境变量：

```bash
export CURSOR_SESSION_TOKEN='user_…::eyJ…'
export CODEX_HOME="$HOME/.codex"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CLAUDE_CODE_OAUTH_TOKEN='…'   # 可选覆盖
export SKYWORK_COOKIE='token=…; k_device_hash=…'   # 可选覆盖 Chrome Cookie
```

## 项目结构

```text
Sources/QuotaDuo/
  App/         MenuBarExtra 入口
  Models/      统一用量模型（动态 Provider）
  Services/    Codex / Cursor / Claude / Skywork 客户端
  Stores/      刷新与可见性
  Views/       菜单栏标签与下拉面板
```

## 隐私与风险

- 默认只读本地登录态；Claude OAuth 刷新成功时会写回凭证文件/Keychain（与 Claude Code 官方刷新行为一致）。
- 用量接口为非公开、可能变更的内部 API。
- 与 OpenAI、Cursor、Anthropic、Skywork 无关，商标归属其所有者。

## License

MIT
