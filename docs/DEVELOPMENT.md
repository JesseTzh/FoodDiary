# 开发说明

## 环境与启动

项目使用 Flutter 3.47.7、Dart 3.13 和 Go 1.26。安装 Flutter 依赖并启动前后端：

```sh
cd frontend
flutter pub get
cd ..
make dev
```

API 地址是 `http://localhost:8080`，Web 地址是 `http://localhost:5173`。首次访问时设置厨房密码。Web 使用 HttpOnly Cookie；Android 使用本机安全存储的会话令牌。

Android 模拟器可使用以下命令连接本机 API：

```sh
cd frontend
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

正式 Android 包只允许 HTTPS。debug 和 profile 包可连接 HTTP 开发服务。

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
  cmd/server/kitchen.go         菜谱、收藏、个人资料
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
| POST | `/auth/refresh` | 轮换刷新令牌并获取新的访问 JWT |
| POST | `/auth/logout` | 退出并即时撤销整个会话 |
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

以上业务接口均需要登录。访问令牌为 HS256 JWT（`golang-jwt/jwt/v5 v5.3.1`），有效 15 分钟，严格验证算法、签名、issuer、audience、subject、exp、iat、nbf、jti 和 sid，且每次检查数据库会话是否仍有效。Web 会话固定 7 天、Android 固定 30 天；刷新不延长期限。每次登录创建独立会话，支持多端同时在线，单端退出或刷新令牌重放只撤销该端的会话；配置密码不变时重启保留会话，密码真正变化时原子地更新密码并撤销所有端的会话。刷新令牌为 32 字节随机值，数据库只保存 SHA-256 哈希；原令牌轮换后保留消费记录，重放会撤销整个会话，退出同样即时撤销访问 JWT。

Web 访问 JWT 放在 `fooddiary_session` HttpOnly Cookie，刷新令牌放在路径 `/api/v1/auth` 的 `fooddiary_refresh` HttpOnly Cookie；刷新接口无需有效访问 JWT。Android 登录、刷新请求必须带 `X-FoodDiary-Client: app`，响应 `X-Session-Token` 和 `X-Refresh-Token` 分别提供访问和刷新令牌，存入 flutter_secure_storage；业务请求使用访问 JWT 的 `Authorization: Bearer <token>`，刷新和退出则使用刷新令牌。浏览器响应不暴露令牌头。

浏览器写请求（包括登录）要求 Origin 与同源或 CORS 白名单匹配；没有 Origin 的原生请求要求 `X-FoodDiary-Client: app`。客户端遇到访问 JWT 过期会自动刷新并重试一次，并合并同一 Api 实例的并发刷新。升级迁移清除旧会话；旧版客户端需升级并重新登录。

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

离线模式仅支持浏览日记和菜谱，不支持新增、编辑或收藏；应用启动、手动刷新及「重试」会重新连接。

## 配置和数据保护

| 变量 | 默认值 | 用途 |
|---|---|---|
| `FOODDIARY_ADDR` | `:8080` | 监听地址 |
| `FOODDIARY_DATA_DIR` | `./data` | SQLite、照片和签名密钥目录 |
| `FOODDIARY_FRONTEND_DIR` | `frontend/build/web` | Web 构建目录 |
| `FOODDIARY_PASSWORD` | 空 | 启动时设置或更改厨房密码 |
| `FOODDIARY_JWT_SECRET` | 自动生成并保存到 `data/jwt.key` | 至少 32 字节的十六进制 HS256 密钥 |
| `FOODDIARY_CORS_ORIGINS` | 空 | 逗号分隔的跨域来源白名单 |

更改厨房密码会撤销所有会话。相同密码下重启服务不会撤销会话。更改 JWT 密钥会使旧 JWT 失效。备份时请包含数据库、照片和 `jwt.key`。多实例部署必须共享同一数据库和签名密钥。

生产环境必须使用 HTTPS。反向代理应覆盖客户端提供的 `X-Forwarded-Proto`，并保留原始 Host。登录限速按直连 IP 计算；应用不信任外部 `X-Forwarded-For`。代理后的用户可能共用一个限速计数。不要把不可信来源加入 CORS 白名单。

Web 使用 HttpOnly、SameSite=Lax Cookie；HTTPS 下 Cookie 带 Secure 标记。写请求会检查 Origin。Android 使用安全存储，并发送 `X-FoodDiary-Client: app`。

## Android

`com.jessetzh.fooddiary`，主清单声明网络权限，相机和相册通过 image_picker 接入。正式包使用 HTTPS；debug/profile 可使用 HTTP 开发服务器。服务地址通过 `--dart-define=API_BASE_URL=...` 设置。

构建命令请使用根目录的 `make apk` / `make appbundle`。正式签名读取 `frontend/android/key.properties`，文件和 keystore 均被忽略。无配置时使用开发签名。正式签名时复制 `frontend/android/key.properties.example` 并填写自己的 keystore 信息。不要提交签名文件、密钥或密码。

## 验证和发布

`make check` 执行 Go vet 和 Flutter analyze；`make build` 生成后端与 PWA；`make apk` 生成 APK。修改 Web 后必须重新执行构建脚本，确保离线资源版本与页面一致。

Web 构建必须运行 `make web` 或 `./scripts/build-web.sh`。脚本会在 Flutter 构建后生成 Service Worker。构建使用本地 CanvasKit 和中文字体，不要添加 `--wasm`。

Web、`make apk`、`make appbundle` 与 CI 通过 `scripts/build-flutter.sh` 统一注入显示版本号，格式为 `Ver:yymmdd-hhmm-gitsha`，日期和时间使用打包时的北京时间（Asia/Shanghai）。直接 `flutter run` 未注入版本时显示 `Ver:dev`。

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
