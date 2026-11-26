# 在 GitHub 上生成 QQ 音乐版 IPA

本机是 Windows，没有 Xcode，iOS 二进制只能在 macOS 上编。这条路把编译放到
GitHub 托管的 macOS runner 上跑，产物既挂 artifact 也挂 Release，后者可以直接匿名下载。

## 0. 现状

| 项 | 状态 |
|---|---|
| QQ 音乐适配层（6 个 Swift 文件 + 27 处分流） | 完成 |
| iOS 26 SDK 兼容改造（`MELOX_NO_IOS27`） | 完成 |
| 构建脚本 `build_qq_unsigned.sh` | 完成 |
| GitHub Actions 流水线 | 完成 |
| **推送到某个可跑 Actions 的仓库** | **待做——需要仓库** |
| IPA 文件 | 待前一项完成后自动产出 |

本机 `git remote` 指向上游 `AritxOnly/MeloX-Overtone`，本机凭据属于账号
`Miku999`，对该仓库没有推送权限（`403 Permission denied`）。所以在推送之前，
必须先有一个自己名下的仓库。

## 1. 建仓库（唯一需要手工的一步）

打开 <https://github.com/new>：

- Repository name：`MeloX-Overtone`
- 可见性：**Public**（公开仓库的 Actions 完全免费；私有库 macOS runner 按 10 倍扣额度）
- **不要**勾 Add README / .gitignore / license（要空仓库）

点 Create repository，得到 `https://github.com/Miku999/MeloX-Overtone`。

## 2. 推送

```bash
cd E:/workbuddy/2026-11-26-10-55-54/melox_work/melox-src
git remote add mine https://github.com/Miku999/MeloX-Overtone.git
git push -u mine qq
```

推送即触发 `Build QQ Music unsigned IPA`。若提示
`refusing to allow a Personal Access Token to create or update workflow`，
说明凭据缺 `workflow` scope——在仓库网页上 Add file 上传一次
`.github/workflows/build-qq-ipa.yml`，再到 Actions 页面 Run workflow 即可。

## 3. 拿 IPA

构建约 15~25 分钟。完成后：

- **直接下载（推荐）**：`https://github.com/Miku999/MeloX-Overtone/releases/latest`
- 或 Actions → 该次 run → 页面底部 Artifacts →
  `MeloX-QQMusic-unsigned-<run_number>.zip`

产物是未签名 IPA，需自签（Sideloadly / AltStore / TrollStore / 自备证书）后安装。
Bundle ID 为 `com.aritxonly.qqmusic.MeloX`，可与网易云原版共存。

## 4. 手动触发与参数

Actions → Build QQ Music unsigned IPA → Run workflow：

| 输入 | 默认 | 说明 |
|---|---|---|
| `runner` | `macos-26` | 有 Xcode 27.1+ 的镜像可填 `macos-27` / `xcode-27` |
| `min_ios_sdk` | `26.0` | 配合 `sdk26_compat=1` |
| `sdk26_compat` | `1` | 1 = 注入 `MELOX_NO_IOS27`，剔除 iOS 27.1 专属 API |
| `retention_days` | `14` | artifact 保留天数 |

要有完整的折叠屏分屏布局，就把 `sdk26_compat=0`、`min_ios_sdk=27.1`，并换到带
Xcode 27.1+ 的 runner。

## 5. `MELOX_NO_IOS27` 关掉了什么

只影响视图层，播放 / 歌词 / 搜索 / 歌单 / 下载全不受影响：

| 文件 | 降级后行为 |
|---|---|
| `NowPlayingAdaptiveView.swift` | 整个类型不参与编译 |
| `NowPlayingTabletView.swift` | 直接渲染 `standardBody` |
| `SkylineLyricsView.swift` | 走 `ZStack` 分支 |
| `TextPVFullScreenPlayerView.swift` | 走 `ZStack` 分支 |
| `NowPlayingView.swift` | `hasDisplayDivision` 恒为 `false` |

代价是 iPhone Fold 那种双屏分屏播放器布局不生效，其余一致。

## 6. 失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `No Xcode` / `iOS SDK too old` | runner 上没有满足阈值的 Xcode | 换 `runner`，或用 `sdk26_compat=1` + `min_ios_sdk=26.0` |
| `cannot find 'ArrangementView' in scope` | 没注入 `MELOX_NO_IOS27` | 确认 `SDK26_COMPAT=1`，日志里应有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=MELOX_NO_IOS27` |
| `bundle id patch did not apply` | 临时工程替换没生效 | 脚本只给 macOS 用，`sed -i ''` 在 GNU sed 下语义不同 |
| `Preflight ... FAIL` | 源码结构或跨文件符号被改坏 | 本地跑 `python3 .github/scripts/qq_preflight.py` |
| 90 分钟超时 | runner 排队 + 首次全量编译 | 重跑一次，第二次快很多 |

## 7. 回退

```bash
cd E:/workbuddy/2026-11-26-10-55-54/melox_work/melox-src
git checkout main
```

原始文件备份在 `melox_work/backup_originals/`（含 `sdk26/` 子目录里改造前的 5 个视图）。
