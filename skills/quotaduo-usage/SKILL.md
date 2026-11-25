---
name: quotaduo-usage
description: >-
  Write the current Antigravity /usage quota into QuotaDuo's local file.
  Use when the user says 写入 QuotaDuo 额度, 更新 QuotaDuo, or asks to save
  the Models & Quota table for QuotaDuo. Runs only inside the already
  open agy session.
---

# 把本次 /usage 写入 QuotaDuo

把当前会话里的官方额度写成一个本地 JSON 文件。QuotaDuo 之后自己读这个文件。

## 绝对不要做

- 不要执行 `agy`、`agy --print /usage`、`agy -p /usage`，也不要再启动任何 `agy` 进程。
- 不要打开浏览器，不要登录，不要读取或写入 OAuth、token、cookie、keyring。
- 不要把账号邮箱写进文件。

另起一个 `agy` 进程看不到这个窗口的登录态，会跳到 Google 登录。`/usage` 打出来之后，这个窗口往往不能再接着输入斜杠或调用 skill。所以不要要求用户先打 `/usage`、再在同一屏继续说写入。

## 步骤

1. 用户会把 `/usage` 的打印结果复制出来，连同一句「写入 QuotaDuo 额度」一起贴进一个还能输入的 agy 窗口。优先解析这条消息里贴上的 Models & Quota 表格。
2. 消息里没有这张表时，停下来，说明做法：先在已登录的窗口打 `/usage`，复制整段输出，再到一个还能打字的窗口粘贴，并加上「写入 QuotaDuo 额度」。不要自己去跑命令代替 `/usage`。
3. 跟着粘贴内容里的标题分组，不要自己补一组。某一组没有 5 小时窗口，就不要补一个。
   - 标题是 `GEMINI MODELS`：`title` 写 `Gemini`。模型名原样放进 `models`，包括 Argon、Neon、Carbon、Hydrogen。Argon 已经并进这一组的 Weekly 和 Five Hour，不要再单独开 `Argon` 组。
   - 标题是 `CLAUDE AND GPT MODELS`：`title` 写 `Claude / GPT`。
   - 只有粘贴里仍单独出现 `GEMINI 4 ARGON` 这种旧标题时，才保留第三组，`title` 写 `Argon`。
4. 每个窗口：
   - 周额度的 `label` 写 `周`，Five Hour 的 `label` 写 `5时`。
   - `remainingPercent` 用表上的剩余百分比，例如 `98.39`。
   - 下一行是 `Quota available`：不要写 `resetsAt`。
   - 下一行是 `Refreshes in 165h 2m` 这类：按**现在的本地时间**加上这段间隔，写成带时区的 ISO8601，放到 `resetsAt`。
5. `models` 只写模型名，用逗号分隔。不要写 Account 那一行。
6. 用 shell 把 JSON 原子写到 `~/.config/quotaduo/agy.json`，然后 `chmod 600`。目录不存在就先创建。写完用 `python3 -m json.tool` 确认能解析，并告诉用户 QuotaDuo 刷新后会读到这份文件。

## 文件格式

```json
{
  "writtenAt": "2026-11-17T11:10:00+09:00",
  "groups": [
    {
      "title": "Gemini",
      "models": "Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen",
      "windows": [
        {"label": "周", "remainingPercent": 100},
        {"label": "5时", "remainingPercent": 100}
      ]
    },
    {
      "title": "Claude / GPT",
      "models": "Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
      "windows": [
        {"label": "周", "remainingPercent": 100},
        {"label": "5时", "remainingPercent": 100}
      ]
    }
  ]
}
```

`writtenAt` 是写入时刻。`title` 用 `Gemini` 或 `Claude / GPT`。Argon 写在 Gemini 的 `models` 里。没有的组不要空着写进去。`Quota available` 的窗口不要写 `resetsAt`。
