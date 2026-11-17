# Top5Plan 项目说明

## 1. 项目定位

Top5Plan 是一个单人多设备、离线优先的个人决策与待办应用。目标不是管理一切，而是帮助用户把今天压缩到最重要的五件事，并留下关键判断。

核心循环：

```text
快速记录 → 聚焦五件事 → 集中处理 → 认真回顾
```

## 2. 系统组成

```text
Windows / Android 客户端
  ├─ Flutter UI
  ├─ Drift + SQLite（本地业务数据与待同步操作）
  └─ 后台同步 / 本地提醒 / 番茄钟

              HTTPS / REST
                    │
                    ▼
              Go 服务端 t5d
  ├─ 设备配对与令牌认证
  ├─ 增量同步、版本检查、幂等、墓碑、冲突保留
  ├─ 设置、专注会话
  ├─ AI 配置加密、任务与日报/周报
  ├─ 应用更新公告
  └─ MySQL 8.4

公开站：React + Vite → Cloudflare Pages
```

## 3. 关键设计

### 离线优先

所有输入先写入本地 SQLite，网络不可用时不影响记录。同步是后台行为，不是使用应用的前提。

### 同步模型

- 客户端操作拥有唯一 operation ID。
- 每次写入带基础版本。
- 服务端使用单调 `change_seq` 记录变更日志。
- 同一操作重复提交幂等返回。
- 版本冲突会保留，而不是静默覆盖。
- 删除使用墓碑。
- 支持世代轮换（`rotate-generation`），客户端检测到世代变化后重新 bootstrap。

### 安全边界

- 无公开注册；一次性配对码 + 可撤销独立设备令牌。
- 配对码与设备令牌只保存 SHA-256 哈希。
- 客户端令牌保存到操作系统安全存储。
- AI Key 只在服务端保存，使用 AES-256-GCM 加密；主密钥来自 `T5_MASTER_KEY`。
- 请求日志不记录 Authorization、请求体、私人记录或 AI Key。
- MySQL 默认不暴露公网；t5d 只绑定本机回环，由 Caddy 终止 HTTPS。
- 本项目不声称端到端加密或本地数据库全盘加密。

### 数据导出与恢复

- 客户端支持完整 JSON 与 Markdown 导出。
- 服务端支持 MySQL `mysqldump --single-transaction` 一致性备份。
- 提供独立恢复脚本；恢复后建议执行世代轮换。

## 4. 目录说明

```text
client/        Flutter Windows + Android 客户端
server/        Go 服务、数据库迁移、OpenAPI
deploy/        Compose、Caddy、备份/恢复、env 示例
packaging/     Windows 安装包构建脚本
```

## 5. 本地开发

### Go 服务端

```bash
cd server
go test ./...
go build ./cmd/t5d
```

### Flutter 客户端

```bash
cd client
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

### 生产部署

```bash
cd deploy
cp .env.example .env
# 填写 T5_DB_DSN、T5_MASTER_KEY、MySQL 密码
docker compose --profile bundled-db up -d --build
```

## 6. 已实现范围

- 今日五件事、完整待办、清单/看板/日历视图
- 问题箱、每日复盘、番茄钟
- SQLite 本地优先与多端增量同步
- AI 配置/任务/日报/周报
- 数据导出、备份与恢复
- 应用更新公告
- Windows 安装包、Android APK、静态官网/下载页

## 7. 明确非目标

- 不做多人协作
- 不做 Web 客户端
- 不引入 Redis、消息队列、Kubernetes
- 不声称端到端加密
- 不做 macOS / Linux 客户端（当前版本）

## 8. 仓库脱敏说明

公开仓库已排除：

- 内部 `docs/` 文档
- `artifacts/` 测试与性能原始结果
- 代码签名私钥 / 测试证书
- release 二进制文件
- 本地数据库备份与日志
- 任何生产环境密钥、密码、令牌

如需构建安装包，请使用 `packaging/` 中的脚本和自己的签名证书。

## 9. License

MIT License。详见 [LICENSE](LICENSE)。
