# FoodDiary 移动端 PWA 开发文档

版本：v0.1（MVP）  
目标：开发一个可安装、移动端优先、支持离线记录的“每日做饭成果”应用。用户可以记录当天做了什么、成品照片、用料、步骤、耗时、评分和备注，并按日期、标签和菜名回顾。

本文以 `/Users/jessetzh/CodeSpace/bophotos` 为架构参考，保留其“React SPA + Go 单体服务 + SQLite + 本地文件 + Docker”的简单部署模型，同时针对手机端和离线场景增加 PWA、IndexedDB 本地缓存、同步队列和图片压缩。

## 1. 产品范围

### 1.1 MVP 必须支持

1. 今日首页：显示今日记录数量、最近一次成果和“新增做饭记录”主按钮。
2. 新增记录：日期、菜名、分类、成品照片（最多 9 张）、用料、步骤、耗时、难度、评分、口味标签和备注。
3. 记录详情：查看照片、基本信息、用料和步骤；可编辑、复制为新记录、删除。
4. 日历/时间线：按日浏览，显示当天记录卡片和缩略图。
5. 搜索与筛选：按菜名、标签、分类、评分、日期范围筛选。
6. 统计：本月做饭天数、菜品数量、最常做分类、平均评分、连续做饭天数。
7. PWA：可安装到手机主屏；核心页面和已访问图片可离线打开；离线新增/编辑记录，恢复网络后自动同步。
8. 数据导出：导出 JSON（含记录和元数据）及 ZIP（含 JSON 和照片）。

### 1.2 MVP 暂不实现

- 多用户、社交分享、评论和关注。
- 云端图片识别、营养计算、购物清单自动生成。
- 原生 App、推送通知、复杂权限管理。

## 2. 技术方案

### 2.1 技术栈

前端：

- React 19、TypeScript、Vite、React Router。
- TanStack Query：服务端状态、重试和缓存。
- Tailwind CSS + Radix UI 或轻量组件层：移动端优先，避免桌面端过度复杂。
- `vite-plugin-pwa` + Workbox：Service Worker、预缓存和运行时缓存。
- Dexie：IndexedDB 封装，保存离线记录、图片 Blob、同步队列。
- `browser-image-compression` 或 Web Worker：上传前压缩图片。
- Vitest、React Testing Library、Playwright：单元、组件和端到端测试。

后端：

- Go 1.24、chi、`database/sql`、SQLite、golang-migrate。
- `github.com/mattn/go-sqlite3` 或项目统一采用的 SQLite 驱动；开启 WAL、外键和 busy timeout。
- 本地文件存储：原图、压缩图、缩略图分目录保存。
- `chi/middleware`、结构化日志和统一 JSON 错误响应。
- OpenAPI 3.1 文档作为接口唯一契约。

部署：

- 开发环境：Vite `5173` + Go API `8080`，Vite 代理 `/api`、`/media`、`/health`。
- 生产环境：多阶段 Docker 构建，Go 同时托管 API、媒体和前端 `dist`。
- 默认数据目录 `/data`，包含 `app.db` 和 `media/`；通过 Docker volume 持久化。

### 2.2 总体架构

```mermaid
flowchart TB
  Phone[手机浏览器/PWA] --> SPA[React SPA]
  SPA --> SW[Service Worker]
  SPA --> IDB[(IndexedDB\n记录缓存/图片Blob/同步队列)]
  SPA --> API[Go REST API]
  API --> DB[(SQLite)]
  API --> FS[本地媒体存储]
  SW --> Cache[静态资源与运行时缓存]
  API --> Health[/health/live /health/ready]
```

数据原则：服务器是跨设备同步的事实来源；IndexedDB 是手机端离线工作副本。每个本地变更先写入 IndexedDB 和 `sync_outbox`，在线时按顺序提交，成功后记录 `server_id` 和 `updated_at`。

## 3. 初始化与目录结构

在当前目录执行：

```bash
mkdir -p frontend backend docs
cd frontend
pnpm create vite . --template react-ts
pnpm add react-router-dom @tanstack/react-query dexie vite-plugin-pwa browser-image-compression zod date-fns clsx lucide-react
pnpm add -D tailwindcss @tailwindcss/vite vitest jsdom @testing-library/react @testing-library/jest-dom @testing-library/user-event playwright
cd ../backend
go mod init fooddiary
go get github.com/go-chi/chi/v5 github.com/golang-migrate/migrate/v4 github.com/mattn/go-sqlite3
```

建议目录：

```text
FoodDiary/
├── frontend/
│   ├── public/manifest.webmanifest
│   └── src/
│       ├── app/                 # providers、router、错误边界
│       ├── api/                 # fetch client、OpenAPI 类型
│       ├── db/                  # Dexie schema、sync outbox
│       ├── features/
│       │   ├── diary/           # 首页、时间线、表单、详情
│       │   ├── stats/           # 统计
│       │   ├── settings/        # 导出、同步状态、主题
│       │   └── media/           # 相机、压缩、上传队列
│       ├── shared/              # UI、日期、校验、格式化
│       └── styles/
├── backend/
│   ├── cmd/server/main.go
│   ├── internal/
│   │   ├── api/                 # router、respond、middleware
│   │   ├── diary/               # model、repository、service、http
│   │   ├── media/               # 上传、缩略图、静态读取
│   │   ├── sync/                # 变更游标和冲突处理
│   │   └── repository/
│   ├── migrations/
│   └── openapi/openapi.yaml
├── docs/DEVELOPMENT.md
├── Dockerfile
├── docker-compose.yml
└── Makefile
```

## 4. 数据模型与迁移

### 4.1 SQLite 表

`diary_entries`：

| 字段 | 类型 | 约束/说明 |
|---|---|---|
| `id` | TEXT | UUID 主键 |
| `cooked_on` | TEXT | `YYYY-MM-DD`，必填 |
| `title` | TEXT | 1–80 字，必填 |
| `category` | TEXT | `home`, `baking`, `soup`, `staple`, `dessert`, `other` |
| `duration_minutes` | INTEGER | 0–1440，可空 |
| `difficulty` | INTEGER | 1–5，可空 |
| `rating` | INTEGER | 1–5，可空 |
| `ingredients_json` | TEXT | JSON 数组 |
| `steps_json` | TEXT | JSON 数组 |
| `notes` | TEXT | 最多 2000 字 |
| `created_at`/`updated_at` | TEXT | UTC RFC3339 |
| `deleted_at` | TEXT | 软删除时间，可空 |
| `version` | INTEGER | 乐观并发版本 |

`entry_tags`：`entry_id`、`tag` 联合主键。  
`media_assets`：`id`、`entry_id`、`original_name`、`mime`、`size_bytes`、`width`、`height`、`sha256`、`status`、`created_at`。  
`sync_changes`：`seq` 自增游标、`entity_type`、`entity_id`、`operation`、`version`、`changed_at`。  
`app_settings`：键值配置，例如 `schema_version`、`allow_guest`。若 MVP 只服务单个家庭，可暂不引入登录表，但必须保留后续加入账号的边界。

首个迁移 `000001_foundation.up.sql` 必须创建表、索引和触发器；至少为 `cooked_on`、`title`、`updated_at` 建索引。删除记录采用软删除，导出和同步完成后再由清理任务物理清理媒体。

### 4.2 前端 IndexedDB

Dexie 数据库 `fooddiary` 包含：

- `entries`: `localId`, `serverId`, `cookedOn`, `updatedAt`, `syncState`。
- `media`: `localId`, `entryLocalId`, `blob`, `mime`, `sortOrder`。
- `outbox`: `++seq`, `operation`, `entity`, `entityId`, `payload`, `retryCount`, `nextRetryAt`。
- `meta`: `key`, `value`，保存最后同步游标和设备 ID。

## 5. API 契约

统一前缀 `/api/v1`，统一响应：

```json
{ "data": {}, "error": null, "meta": { "request_id": "..." } }
```

错误返回 `4xx/5xx`，结构为 `{ "data": null, "error": { "code": "VALIDATION_ERROR", "message": "...", "fields": {} } }`。

核心接口：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/health/live` | 进程存活 |
| GET | `/health/ready` | SQLite 可用 |
| GET | `/api/v1/auth/status` | 登录状态（是否已设密码、当前会话是否有效） |
| POST | `/api/v1/auth/setup` | 首次设置访问密码（仅未设置时可用，重复调用返回 409） |
| POST | `/api/v1/auth/login` | 密码登录，签发会话 Cookie（失败限速：10 次失败锁 15 分钟） |
| POST | `/api/v1/auth/logout` | 退出登录，销毁会话 |
| GET | `/api/v1/entries?from=&to=&q=&tag=&page=` | 列表、筛选、分页（需登录） |
| POST | `/api/v1/entries` | 创建记录（需登录） |
| GET | `/api/v1/entries/{id}` | 详情（需登录） |
| PATCH | `/api/v1/entries/{id}` | 更新记录，带 `version`（需登录） |
| DELETE | `/api/v1/entries/{id}` | 软删除（需登录） |
| POST | `/api/v1/entries/{id}/copy` | 复制为新记录（需登录） |
| POST | `/api/v1/entries/{id}/media` | multipart 上传照片（需登录） |
| GET | `/media/assets/{id}/{variant}` | `thumbnail`/`preview`/`original`（需登录） |
| GET | `/api/v1/stats?from=&to=` | 统计数据（需登录） |
| GET | `/api/v1/tags` | 标签建议（需登录） |
| GET | `/api/v1/sync?cursor=` | 拉取服务端变更（需登录） |
| POST | `/api/v1/sync/push` | 批量提交离线变更（需登录） |
| GET | `/api/v1/export?format=json\|zip` | 导出数据（需登录） |

登录与会话：单密码模式，密码以 PBKDF2-SHA256（600k 次迭代、随机盐）哈希后存于 `app_settings`；除 `/health/*`、`/api/v1/auth/status`、`auth/setup`、`auth/login` 与前端静态资源外全部需要会话。会话为 32 字节随机 token 的 HttpOnly Cookie（SameSite=Lax），仅存 SHA-256 于 `sessions` 表；**滑动过期**：每次访问自动把有效期续到 30 天后（Cookie 同步续期），连续 30 天不访问才失效。`FOODDIARY_PASSWORD` 环境变量可在启动时初始化或重置密码。

创建记录示例：

```json
{
  "cooked_on": "2026-10-01",
  "title": "番茄鸡蛋面",
  "category": "staple",
  "duration_minutes": 25,
  "difficulty": 2,
  "rating": 4,
  "ingredients": [{"name":"鸡蛋","amount":"2 个"}],
  "steps": ["烧水煮面", "炒鸡蛋和番茄", "混合调味"],
  "tags": ["快手", "工作日晚餐"],
  "notes": "下次少放一点盐"
}
```

同步规则：客户端发送 `device_id`、本地操作 ID、实体 `version`。服务端按操作 ID 幂等处理；版本相同则接受，版本冲突返回 `409 CONFLICT` 和服务端版本。MVP 冲突策略为“保留服务端版本并将本地草稿复制为冲突草稿”，禁止静默覆盖。

## 6. 前端页面与交互

路由：

- `/` 今日首页。
- `/diary` 时间线/日历。
- `/diary/new` 新增记录。
- `/diary/:id` 详情。
- `/diary/:id/edit` 编辑。
- `/stats` 统计。
- `/settings` 设置、导出和同步状态。

底部导航固定为“今天、记录、统计、设置”；新增按钮使用悬浮主按钮。表单必须支持相机拍照和相册选择，图片先显示本地预览，再进入上传队列。保存按钮在离线时显示“保存到本机”，在线时显示“保存并同步”。

响应式断点以 375px、390px、430px 为重点；触控目标至少 44×44px；正文默认 16px；支持 `prefers-color-scheme` 和安全区域 `env(safe-area-inset-bottom)`。

## 7. PWA 与离线实现

1. `manifest.webmanifest` 配置 `name`、`short_name`、`start_url: /`、`display: standalone`、主题色、图标 192/512。
2. Service Worker 预缓存 HTML、JS、CSS、图标；字体采用缓存优先。
3. `/api/v1/entries` 使用 Network First，失败后读 IndexedDB；详情和缩略图使用 stale-while-revalidate。
4. 新增/编辑/删除先写 IndexedDB，再追加 `outbox`；网络恢复、应用启动和用户点击“立即同步”时执行队列。
5. 同步采用指数退避（1s、5s、30s、5min，最多 5 次），失败记录到设置页；不可重试的 4xx 进入“需要处理”。
6. 图片压缩为最长边 1600px、JPEG/WebP 质量 0.82；原图只在用户主动选择“保留原图”时上传。
7. 明确显示离线状态、未同步数量、最近同步时间；关闭页面不能丢失已保存的本地记录。

## 8. 后端实现顺序

1. 初始化配置、日志、SQLite 连接、迁移和 `/health`。
2. 完成 `diary_entries` CRUD、校验、分页和筛选。
3. 完成媒体上传、SHA-256 去重、缩略图/预览图生成和静态读取。
4. 增加标签、统计查询和导出。
5. 增加 `sync_changes`、游标同步和冲突响应。
6. 接入 SPA 静态托管和非保留路径 fallback。
7. 编写 OpenAPI，并在 CI 中校验实现与文档的关键路径一致。

## 9. 测试与质量门禁

本地命令：

```bash
make dev                 # 同时启动前后端
make check               # Go 测试、vet、前端类型检查和构建
cd frontend && pnpm test
cd frontend && pnpm exec playwright test
```

必须覆盖：

- 日期、标题、评分、图片数量和文件大小校验。
- CRUD、分页、筛选、软删除、版本冲突和同步幂等。
- 图片上传失败、重复上传、缩略图生成失败。
- 离线新增 -> 刷新 -> 恢复网络 -> 自动同步。
- 手机宽度 375px 下新增、编辑、返回和底部导航。
- PWA manifest、Service Worker 注册、离线打开最近记录。
- 导出 JSON 可重新解析，ZIP 包含照片和元数据。

发布前执行 Lighthouse：Performance ≥ 85、Accessibility ≥ 90、PWA 核心项通过；`go test ./...`、`go vet ./...`、`pnpm type-check`、`pnpm build` 全部通过。

## 10. Docker 与运行配置

环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FOODDIARY_ADDR` | `:8080` | 监听地址 |
| `FOODDIARY_DATA_DIR` | `/data` | SQLite 和媒体根目录 |
| `FOODDIARY_FRONTEND_DIR` | `frontend/dist` | SPA 构建目录 |
| `FOODDIARY_MAX_UPLOAD_BYTES` | `20971520` | 单张图片 20 MiB |
| `FOODDIARY_MEDIA_RETENTION_DAYS` | `30` | 软删除媒体保留期 |
| `FOODDIARY_PASSWORD` | 空 | 启动时初始化/重置访问密码；不设置则首次访问在页面设置 |
| `FOODDIARY_SESSION_DAYS` | `30` | 会话有效期（滑动续期） |

`docker-compose.yml` 暴露 `8080:8080`，挂载 `./data:/data`，设置 `restart: unless-stopped`。生产反向代理必须启用 HTTPS，否则相机、Service Worker 和安装能力会受浏览器安全策略限制；本机开发的 `localhost` 例外。

## 11. 分阶段执行计划

### 第 1 阶段：骨架（1–2 天）

- 初始化仓库、Vite、Go、Docker、Makefile。
- 建立路由、底部导航、设计 token、SQLite 迁移和健康检查。
- 交付：空壳 PWA 能安装，CI 能通过。

### 第 2 阶段：记录闭环（3–5 天）

- 完成新增、详情、编辑、删除、照片上传和本地缩略图。
- 交付：在线完成一条记录的完整生命周期。

### 第 3 阶段：回顾和统计（2–3 天）

- 时间线/日历、搜索筛选、标签和统计页。
- 交付：能按日期和标签找回历史成果。

### 第 4 阶段：离线和同步（3–5 天）

- IndexedDB、outbox、Service Worker、冲突处理和同步状态页。
- 交付：飞行模式下可新增，联网后自动同步且不丢数据。

### 第 5 阶段：发布（1–2 天）

- 导出、备份恢复、Lighthouse、Playwright、Docker 镜像和部署文档。
- 交付：可在 HTTPS 环境安装使用，数据目录可备份恢复。

## 12. 完成定义（Definition of Done）

- 新用户在手机上 60 秒内可以创建一条带照片的做饭记录。
- 记录在离线状态保存后，强制关闭并重新打开仍然存在。
- 网络恢复后，记录和照片均能同步；重复点击不会产生重复记录。
- 时间线、搜索、统计与详情数据一致。
- 删除、导出和冲突处理都有明确反馈，不发生静默数据丢失。
- 所有质量门禁通过，Docker 从干净目录启动后访问 `http://localhost:8080` 正常。
