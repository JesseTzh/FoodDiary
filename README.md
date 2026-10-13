# 做饭日记 · FoodDiary

Flutter 3.47.7 / Dart 3.13 构建一套适配手机和桌面的界面；Web 使用 CanvasKit，支持安装为 PWA；Android 使用 Flutter 原生渲染。Go 1.26 + SQLite 后端负责密码登录、日记、照片、菜谱、收藏、个人资料和食材清单。

## 功能

- 首页：虎鼠厨房插画、今日记录入口、推荐菜谱、最近日记。
- 日记：按年月筛选、搜索菜名/心得/标签、详情、编辑、删除和收藏。
- 记录：日期、餐次、菜品名称、200 字心得、标签、五种心情、相机/相册照片，最多 9 张。
- 菜谱：分类、搜索、食材和做法、收藏、创建自己的菜谱、一键开始做饭记录。
- 我的：实际记录天数、创建菜谱数、收藏数、资料设置和食材采购清单。
- PWA：可安装、离线应用壳、上次加载的日记/菜谱快照、已访问照片缓存、版本更新提示。离线模式为只读；不提供离线写入队列。
- Android：相机、相册、持久化登录、APK/AAB 构建。

视觉采用参考图的奶油色、橙黄按钮、圆角卡片及虎鼠插画。`frontend/assets/images` 为用户提供的参考图裁切资源；默认菜谱仅作初始内容，日记和统计从真实数据开始。发布前请确认参考图素材的使用授权，并按需替换为高分辨率独立素材。Noto Sans SC 字体使用 SIL OFL，许可位于 `frontend/assets/fonts/OFL.txt`。

## 开发

```sh
cd frontend
flutter pub get
cd ..
make dev
```

API 默认 `http://localhost:8080`，Flutter Web `http://localhost:5173`。首次进入设置厨房密码，以后使用该密码登录。开发环境 CORS 仅允许指定的前端来源。Android 和 Web 使用相同接口；Web 使用 HttpOnly Cookie，Android 使用存储在本机的会话令牌。

Android 模拟器：

```sh
cd frontend
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

正式 Android 包仅允许 HTTPS；调试包允许 HTTP。

## 构建

```sh
make check             # go vet + flutter analyze
make build             # CanvasKit PWA + Go 可执行文件
make apk API_BASE_URL=https://your-domain.example
make appbundle API_BASE_URL=https://your-domain.example
```

Web 构建必须使用 `make web` 或 `./scripts/build-web.sh`，脚本会在 Flutter 构建后生成 PWA Service Worker。直接执行 `flutter build web` 不会生成自定义 `sw.js`。

输出：

- Web：`frontend/build/web/`
- 后端：`fooddiary`
- APK：`frontend/build/app/outputs/flutter-apk/app-release.apk`
- AAB：`frontend/build/app/outputs/bundle/release/app-release.aab`

`frontend/web/flutter_bootstrap.js` 显式指定 `renderer: 'canvaskit'`；构建使用 `--no-web-resources-cdn`，CanvasKit 和中文字体随站点打包。不要添加 `--wasm`，它会选择不同的渲染链路。

Android 正式签名：复制 `frontend/android/key.properties.example` 为 `key.properties`，配置自己的 keystore。没有该文件时使用开发签名，便于安装预览；商店发布需要自己的签名。不要提交密钥或密码。

## 运行和部署

```sh
make build
./fooddiary
# 或从源码构建 Docker 镜像
 docker build -t fooddiary:local .
 docker run --rm -p 8080:8080 -v fooddiary-data:/data fooddiary:local
```

Go 同时托管 API、照片和 Web 资源，生产建议同源 HTTPS 部署，PWA 安装及相机访问需要 HTTPS 或 localhost。

| 环境变量 | 默认值 | 用途 |
|---|---|---|
| `FOODDIARY_ADDR` | `:8080` | 监听地址 |
| `FOODDIARY_DATA_DIR` | `./data` | SQLite 和照片 |
| `FOODDIARY_FRONTEND_DIR` | `frontend/build/web` | Web 构建目录 |
| `FOODDIARY_PASSWORD` | 空 | 启动时设置或重置厨房密码 |
| `FOODDIARY_JWT_SECRET` | 自动生成并保存到 `data/jwt.key` | 至少 32 字节的十六进制 HS256 签名密钥 |
| `FOODDIARY_CORS_ORIGINS` | 空 | 逗号分隔的跨源来源白名单 |

认证使用 `golang-jwt/jwt/v5 v5.3.1`：访问 JWT 有效 15 分钟，自动刷新；Web 登录固定有效 7 天，App 固定有效 30 天，刷新不延长登录期限；每次登录都会创建独立设备会话，支持多端同时在线，退出某一端不会影响其他端。升级 JWT 后旧登录失效，需要重新登录，旧版客户端需同步升级。退出或刷新令牌重放仅撤销对应设备会话；通过 `FOODDIARY_PASSWORD` 更改密码会撤销全部会话，同一密码下重启服务保留所有设备登录。`FOODDIARY_SESSION_DAYS` 已移除。

生产必须使用 HTTPS；反向代理应覆盖客户端传入的 `X-Forwarded-Proto` 并保留原始 Host。登录限速按直连 IP 计算，不信任外部 `X-Forwarded-For`，代理部署时同一代理后的用户共享限速。签名密钥自动持久化，备份时包含 `jwt.key`；多实例需使用相同密钥与数据库。配置新密钥后旧 JWT 失效，若要强制所有客户端重新登录，应同时撤销数据库会话。Web 使用 HttpOnly、SameSite=Lax Cookie，HTTPS 下标记 Secure；写请求校验 Origin（允许显式 CORS 白名单），App 使用安全存储并发送 `X-FoodDiary-Client: app`。不要将不可信来源加入 CORS 白名单。

`data` 保存真实用户资料，重构不会删除现有数据库。新版以新界面和数据契约为准，不承诺旧客户端兼容。迁移 `000004_kitchen.up.sql` 增加新版业务字段、菜谱和食材清单。

CI 在 PR、main 推送和手动运行时，并行执行 Go 单元测试与 vet、Flutter analyze、生产 Docker 镜像构建与 Web 冒烟测试、Android APK 构建。Web 不再在静态检查任务里重复构建；Docker 构建使用 GitHub Actions BuildKit 缓存，发布多架构镜像时复用已验证的 amd64 构建层。

Web 冒烟测试通过 Chromium 访问镜像实际提供的 CanvasKit 前端，检查空数据卷首次设置密码页、登录后首页和重启后的记录展示，同时验证 API 登录与数据持久化。下载 Actions Artifact `fooddiary-web-startup` 可查看 `first-run.png`、`home.png`、`after-restart.png`，以及浏览器日志、Playwright trace 和容器日志；失败时也收集诊断，保留 14 天。测试通过页面语义等待真实 UI，不依赖固定截图延迟。截图用于人工检查，暂不执行像素基线比较。当前容器运行验证覆盖 amd64，发布同时构建 arm64。

非 PR 运行在 Go、Flutter、Web 检查通过后发布 Docker 镜像；main 随后部署。Android 验证独立执行，不阻塞 Web 发布与部署，但失败仍会使对应 Actions 检查失败。Pipeline 的 `Verify APK startup on Android emulator` 下载本次 release APK，在 Android 15（API 35）x86_64 模拟器检查安装启动、进程持续存活、前台 Activity 和致命错误日志。`v*` 标签的 APK 构建和启动验证统一交给 Android Release，避免两个 workflow 重复构建 APK。配置仓库变量 `API_BASE_URL` 可指定 APK 默认服务器。

下载 Artifact `fooddiary-android-startup`（Android Release 中为 `fooddiary-release-android-startup`）可查看 `startup.png` 和启动、Activity、Logcat 日志，保留 14 天；失败时尝试保存 `failure.png`。Android 检查属于启动冒烟检查，登录与后端接口功能仍需单独测试。

详细接口和结构见 [开发说明](docs/DEVELOPMENT.md)。

## GitHub Release 发布 APK

新增 `.github/workflows/android-release.yml`：推送 `v*` 标签自动构建、完成 Flutter 分析与模拟器启动验证后，将 APK、SHA-256 文件上传到同名 GitHub Release；也可在 Actions → Android Release → Run workflow 填写已有标签手动发布。

```sh
git tag v2.0.0
git push origin v2.0.0
```

可选仓库变量 `API_BASE_URL` 设置 APK 的默认 HTTPS 后端地址，手动触发时也可覆盖。未设置时，Web 使用当前页面地址，Android 使用模拟器默认地址。

正式签名需要以下 GitHub Actions Secrets（四项均配置）：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 正式 keystore 文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |

未配置签名 Secrets 时，工作流使用开发签名生成可安装的预览 APK，并在 Release 说明中标明。签名文件仅在 Runner 临时目录生成，结束时清理。工作流使用 `GITHUB_TOKEN` 的 `contents: write` 权限创建或更新 Release，无需额外 PAT。
