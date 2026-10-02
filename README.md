# FoodDiary 🍳

移动端优先的「每日做饭成果」记录 PWA：记录每天做了什么菜，附成品照片、用料、步骤、耗时和评分，支持离线记录与数据导出。

## 功能

- 记录管理：菜名、分类、用料、步骤、耗时、难度、评分、标签、备注与成品照片（拍照/相册）
- 登录保护：单密码访问，首次使用在页面设置密码；会话自动续期，一个月不活跃才需重新登录
- 游客浏览：可把指定记录标记为「开放给游客」，未登录访客在登录页即可只读浏览这些记录（含照片），未开放记录对游客不可见
- 回顾：今日首页、时间线浏览、按菜名/标签搜索
- 统计：本月做饭天数、菜品数量、平均评分、连续天数、最常做分类
- PWA：可安装到手机主屏，Service Worker 离线缓存，断网时保存本机、联网后同步
- 导出：JSON（含记录）与 ZIP（含照片）一键下载

## 技术栈

| 端 | 技术 |
|---|---|
| 前端 | React + TypeScript + Vite + React Router，PWA（manifest + Service Worker） |
| 后端 | Go + chi + SQLite（WAL），golang-migrate 迁移，本地文件存储媒体 |
| 部署 | 多阶段 Docker 构建，Go 单体托管 API、前端静态资源和媒体文件 |
| CI | GitHub Actions：构建、测试与空数据卷启动验证、远程部署脚本 |

## 快速开始

本地开发（同时启动 Go API `:8080` 和 Vite dev server）：

```bash
make dev
```

生产运行（Docker，访问 http://localhost:8080，数据持久化在 `./data`，拉取 `jessetzh/fooddiary` 镜像）：

```bash
docker compose up -d
```

本地构建镜像并运行：

```bash
docker build -t jessetzh/fooddiary:latest .
docker compose up -d
```

## 常用命令

```bash
make dev      # 前后端同时开发
make build    # 构建前端 + Go 二进制
make check    # go test/vet + 前端类型检查与构建
npm run test  # 前端单元测试
```

## 目录结构

```text
frontend/            # React PWA（Vite）
backend/
├── cmd/server/      # Go 服务入口与路由
├── internal/        # 内部包
└── migrations/      # SQLite 迁移
docs/DEVELOPMENT.md  # 详细开发文档（产品范围、API 契约、数据模型、路线图）
scripts/ci/          # CI 辅助脚本（启动验证、远程部署）
```

## 配置

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `FOODDIARY_ADDR` | `:8080` | 监听地址 |
| `FOODDIARY_DATA_DIR` | `/data` | SQLite 与媒体根目录 |
| `FOODDIARY_FRONTEND_DIR` | `frontend/dist` | SPA 构建产物目录 |
| `FOODDIARY_MAX_UPLOAD_BYTES` | `20971520` | 单张图片上限（20 MiB） |
| `FOODDIARY_MEDIA_RETENTION_DAYS` | `30` | 已删除媒体保留天数 |
| `FOODDIARY_PASSWORD` | 空 | 启动时初始化/重置访问密码；不设置则在首次访问页面时设置 |
| `FOODDIARY_SESSION_DAYS` | `30` | 会话有效期；每次访问自动续期 |

> 生产环境需启用 HTTPS（反向代理），否则相机调用、PWA 安装等能力会受浏览器安全策略限制。

## API 概览

统一前缀 `/api/v1`：`auth/status`、`auth/setup`、`auth/login`、`auth/logout` 登录保护（会话 Cookie，HttpOnly），其余接口均需登录；`entries` 增删改查与复制、`entries/{id}/guest-share` 开放/取消开放给游客、`entries/{id}/media` 照片上传、`stats` 统计、`tags` 标签、`sync` 离线同步、`export` 导出；游客免登录只读接口为 `guest/entries` 与 `guest/entries/{id}`（仅返回开放记录），开放记录的照片可直接访问，其余媒体仍需登录；健康检查位于 `/health/live` 与 `/health/ready`。完整契约见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
