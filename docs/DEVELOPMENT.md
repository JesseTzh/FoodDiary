# 开发说明

## 结构

```text
frontend/
  lib/main.dart                 应用入口、主导航、加载与离线快照
  lib/data/api.dart             Web Cookie / Android Bearer 会话、请求与上传
  lib/data/models.dart          日记、菜谱、标签、心情模型
  lib/data/client_web.dart      支持 Cookie 的浏览器请求
  lib/data/client_stub.dart     Android HTTP 客户端
  lib/ui/theme.dart             奶油色主题和共享组件
  lib/ui/pages.dart             登录、记录、详情、菜谱、收藏、清单、设置
  assets/images/                参考图裁切插画与菜品图
  assets/fonts/                 随包中文字体及 OFL 许可
  web/                          Manifest、CanvasKit 启动与安装图标
  android/                      原生工程与可选正式签名
backend/
  cmd/server/main.go            登录、日记 CRUD、照片、路由与启动
  cmd/server/kitchen.go         菜谱、收藏、个人资料、食材清单
  migrations/                   SQLite 迁移
scripts/build-web.sh             发布构建入口
scripts/build-pwa.py             根据实际构建资源生成版本化离线缓存
```

## 新版接口

前缀 `/api/v1`。JSON 响应 `{ "data": ..., "error": null }`；错误响应 `{ "data": null, "error": { "code": "...", "message": "..." } }`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/auth/status` | 是否设置密码、当前是否登录 |
| POST | `/auth/setup` | 首次设置密码并登录 |
| POST | `/auth/login` | 密码登录 |
| POST | `/auth/logout` | 退出并销毁会话 |
| GET | `/entries?q=&month=&favorite=true` | 日记列表，返回 items / total |
| POST | `/entries` | 新增日记 |
| GET | `/entries/{id}` | 日记详情，包含照片 |
| PATCH | `/entries/{id}` | 完整更新，必须携带 version |
| DELETE | `/entries/{id}` | 软删除 |
| PATCH | `/entries/{id}/favorite` | `{ "favorite": true }` |
| POST | `/entries/{id}/media` | multipart `file` 上传照片 |
| GET | `/recipes` | 全部菜谱 |
| POST | `/recipes` | 创建个人菜谱 |
| PATCH | `/recipes/{id}/favorite` | 收藏或取消收藏 |
| GET | `/profile` | 昵称、简介、记录数、创建菜谱数、收藏数 |
| PATCH | `/profile` | 更新 name / bio |
| GET | `/groceries` | 食材清单 |
| POST | `/groceries` | `{ "name": "鸡蛋一盒" }` |
| PATCH | `/groceries/{id}` | `{ "checked": true }` |
| DELETE | `/groceries/{id}` | 删除食材 |

以上业务接口均需要登录。Web 请求带 Cookie；Android 从登录响应的 `X-Session-Token` 读取会话令牌，之后使用 `Authorization: Bearer <token>`。令牌只在数据库中保存 SHA-256 哈希，采用已有的会话过期和密码限速机制。跨源 Web 开发配置 CORS 白名单；生产采用同源托管。

日记写入示例：

```json
{
  "cooked_on": "2026-10-12",
  "title": "番茄炒蛋 + 清炒时蔬",
  "meal": "晚餐",
  "category": "家常菜",
  "notes": "今天是超成功的一天！",
  "tags": ["家常菜", "晚餐"],
  "mood": 0,
  "favorite": false,
  "version": 1
}
```

- 菜名 1–80 字，心得最多 200 字，心情为 0–4；日期严格解析。
- 日记与标签在同一事务写入；编辑采用 version 检查，冲突返回 409。
- 相机/相册客户端按最长边 1600、质量 85 处理；服务器接受 JPEG、PNG、WebP、GIF，最多 9 张，每张最多 20 MiB；超限拒绝，不截断文件。
- 创建菜谱的 ingredients / steps 为字符串数组；每行一个食材或步骤。
- 所有导航统计基于实际业务记录。前端「记录天数」按不同日期去重；profile 的 entry_count 是日记条数。

## PWA 行为

构建后生成 `sw.js`，版本号取全部构建文件的内容哈希。应用壳、字体、图片及本地 CanvasKit 预缓存；安装失败不替换旧缓存。新版等待用户点击刷新后激活，激活时移除旧版本缓存。

API 请求始终直接访问网络，不在 Service Worker 中缓存私密 JSON。应用在成功加载三组业务数据后，把快照保存到 SharedPreferences（Web 为浏览器本地存储）；断网时可读取快照。照片采用网络优先、离线缓存回退，最多缓存 100 张；退出登录清理照片缓存和当前服务器快照。未访问照片离线可能不可见。

离线模式仅支持浏览日记和菜谱，不支持新增、编辑、收藏或食材清单；应用启动、手动刷新及「重试」会重新连接。

## Android

`com.jessetzh.fooddiary`，主清单声明网络权限，相机和相册通过 image_picker 接入。正式包使用 HTTPS；debug/profile 可使用 HTTP 开发服务器。服务地址通过 `--dart-define=API_BASE_URL=...` 设置，用户也可在登录页或设置页修改。

构建命令请使用 README 中的 `make apk` / `make appbundle`。正式签名读取 `android/key.properties`，文件和 keystore 均被忽略。无配置时使用开发签名。

## 验证和发布

`make check` 执行 Go vet 和 Flutter analyze；`make build` 生成后端与 PWA；`make apk` 生成 APK。修改 Web 后必须重新执行构建脚本，确保离线资源版本与页面一致。

生产反向代理需放行 `.wasm`、字体与 `/media/`，保留服务器返回的 WASM MIME。`index.html`、`flutter_bootstrap.js` 和 `sw.js` 不应被代理长时间缓存。数据库和照片统一备份 `FOODDIARY_DATA_DIR`，不要把该目录放进镜像。

### 本地验证 CI Web 截图

需要 Docker、Node.js 22、curl 和 jq：

```sh
npm ci --prefix scripts/ci/web
(cd scripts/ci/web && npx playwright install chromium)
docker build -t fooddiary-ci:local .
./scripts/ci/verify-fresh-start.sh
```

脚本只接受不存在的命名数据卷，避免误用已有数据；默认卷名 `fooddiary-ci-data`，结束时清理本次容器和卷。并行运行时通过 `CI_CONTAINER`、`CI_VOLUME` 和 `CI_HOST_PORT` 指定不同资源；`CI_ARTIFACTS_DIR` 可指定截图目录。容器清理前保存日志，Cookie 临时文件不作为 Artifact 上传。每个 Web 阶段使用新的浏览器上下文，避免会话及 PWA 缓存掩盖初始化问题。

浏览器依赖锁定在 `scripts/ci/web/package-lock.json`；升级 Playwright 后应重新安装对应 Chromium。查看 trace：`npx --prefix scripts/ci/web playwright show-trace web-startup-artifacts/after-restart-trace.zip`。Trace 可能包含本次测试的会话信息，仅使用 CI 临时测试数据。
