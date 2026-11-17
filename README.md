# Top5Plan

> 每天，只做五件事。

Top5Plan 是一个个人使用、离线优先的决策与待办应用。它把「快速记录 → 聚焦五件事 → 集中处理 → 认真回顾」做成一个安静、可恢复、低噪音的个人系统。

- **Windows 客户端**：Flutter Windows 原生窗口，不使用 Electron / Tauri / WebView。
- **Android 客户端**：Flutter Android APK。
- **服务端**：Go 单体 REST 服务 + MySQL 8.4，Docker Compose 部署。
- **本地数据**：SQLite + Drift，业务变更与待同步操作同事务保存。
- **公开站**：React + Vite 静态页，托管于 Cloudflare Pages。

## 下载

- 官网与下载页：<https://t5plan.com/>
- Windows 安装包：<https://t5plan.com/downloads/Top5Plan-Setup-1.0.0-x64.exe>
- Android APK：<https://t5plan.com/apk>
- SHA-256：<https://t5plan.com/downloads/SHA256SUMS.txt>

> 当前版本为测试构建，未使用正式商业代码签名；安装前请阅读下载页说明。

## 功能

- 今日重点最多 5 项，支持选择、排序、完成、移出。
- 完整待办：清单、标签、状态、优先级、日期/时间/提醒、子任务、重复、搜索、筛选、批量完成、归档、回收站。
- 列表 / 看板 / 日历三视图共用同一批任务数据。
- 问题箱：快速记录、初步判断、批量生成可复制提问。
- 每日复盘：3 个决策位 + 1 个未解问题、AI 参与标签、后续回看。
- 本地番茄钟与跨设备计时接力。
- 服务端 AI：OpenAI Chat Completions 兼容接口、加密密钥、手动作业、日报/周报调度、限额、版本保留。
- 同步：操作 ID、基础版本、服务端单调 `change_seq`、事务内版本检查、幂等结果、墓碑、冲突保留、世代恢复。
- 数据：完整 JSON / Markdown 导出；MySQL 一致性备份与独立恢复脚本。
- 应用更新：服务端发布版本公告，客户端手动检查并在启动/恢复前台/定时检查提示。

## 目录结构

```text
client/       Flutter Windows + Android 客户端
server/       Go REST 服务、迁移、OpenAPI
deploy/       Docker Compose、Caddy、备份/恢复脚本、环境变量示例
packaging/    Windows 安装包脚本
```

## 服务端快速开始

```bash
cd deploy
cp .env.example .env
# 修改 .env：数据库 DSN、MySQL 密码、T5_MASTER_KEY
openssl rand -base64 32
docker compose --profile bundled-db up -d --build
curl http://127.0.0.1:8080/readyz
```

生产环境请使用 HTTPS，并确保 MySQL 不暴露公网。

生成一次性配对码：

```bash
docker compose exec t5d /app/t5d pair
```

更多实现与安全边界见 [SUMMARY.md](SUMMARY.md)。

## 技术栈

- Flutter / Dart / Drift / SQLite
- Go / MySQL 8.4 / OpenAPI
- React / Vite
- Docker Compose / Caddy

## 安全说明

- 仓库不包含生产密钥、数据库密码、客户端令牌、SSH 私钥或代码签名私钥。
- AI API Key 只在服务端以 AES-256-GCM 加密保存；主密钥来自环境变量。
- 服务端只保存配对码与设备令牌的 SHA-256 哈希。
- 仓库不声称端到端加密，也不声称本地 SQLite 全盘加密。
- 发现安全问题请见 [SECURITY.md](SECURITY.md)。

## License

[MIT](LICENSE) © 2026 DeepSleep7433
