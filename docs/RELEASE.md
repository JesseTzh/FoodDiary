# 发布说明

## Docker 部署

构建并启动服务：

```sh
make build
./fooddiary
```

也可以构建 Docker 镜像：

```sh
docker build -t fooddiary:local .
docker run --rm -p 8080:8080 -v fooddiary-data:/data fooddiary:local
```

Go 服务同时提供 API、照片和 Web 文件。生产环境建议使用同源 HTTPS。PWA 安装和相机访问需要 HTTPS 或 localhost。请把 `FOODDIARY_DATA_DIR` 指向持久化目录，并备份数据库、照片和 `jwt.key`。不要把数据目录放入镜像。

反向代理需允许 `.wasm`、字体和 `/media/` 请求，并保留 WASM MIME 类型。不要长时间缓存 `index.html`、`flutter_bootstrap.js` 或 `sw.js`。

## CI 工作流

`.github/workflows/pipeline.yml` 在 PR、`main` 推送、`v*` 标签推送和手动运行时执行 Go 测试与 vet、Flutter analyze、Docker 镜像构建和 Web 启动检查。PR 与手动运行也会构建 Android APK。Android Release 单独负责推送时的 APK 构建和启动检查，避免重复构建。

Web 启动检查在 Docker 镜像上运行 Chromium。它检查首次设置密码、登录后首页和重启后的数据。Artifact `fooddiary-web-startup` 包含截图、浏览器日志、Playwright trace 和容器日志，保留 14 天。失败时也会保存诊断材料。当前容器启动检查使用 amd64；发布镜像同时构建 amd64 和 arm64。

Android 启动检查使用 Android 15（API 35）x86_64 模拟器。检查会安装本次构建的 APK，并查看应用进程、前台 Activity 和致命错误日志。Artifact `fooddiary-android-startup`（Android Release 中为 `fooddiary-release-android-startup`）包含截图和日志，保留 14 天。该检查只验证启动，不验证登录和 API 功能。

## 界面截图与图册

APK 构建成功后，工作流 `.github/workflows/mock-screenshots.yml` 会使用 `MOCK_API=true` 构建独立 Web 前端，再用 Playwright 截取手机和桌面页面。手机视口为 390×844，桌面视口为 1440×1080。截图覆盖首页、日记、记录、菜谱、收藏、个人资料、设置和登录流程。正式 APK 不启用模拟数据。

Artifact `fooddiary-mock-pages` 包含页面截图、语义快照、页面清单、浏览器日志和 Playwright trace，保留 14 天。测试通过页面语义确认导航成功。任何真实后端请求都会失败。测试提供人工检查用的截图，不执行像素基线比较。

成功后，工作流还会生成 `mock-page-artifacts/site/` 静态图册。图册支持搜索、手机或桌面筛选、页面锚点、图片放大和查看原图。每个页面包含功能说明、进入路径和检查重点。图册只发布截图，不发布 trace、日志或语义快照。功能说明和页面清单维护在 `scripts/ci/web/mock-page-catalog.mjs`。

本地生成截图后，可打开 `mock-page-artifacts/site/index.html`。修改图册说明或样式后，可运行：

```sh
node scripts/ci/web/build-mock-gallery.mjs
```

该命令要求手机和桌面截图及其 manifest 完整匹配。也可以运行完整截图检查：

```sh
bash scripts/build-web.sh --dart-define=MOCK_API=true
bash scripts/ci/verify-mock-pages.sh
```

要发布到 GitHub Pages，请在仓库 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**，再在默认分支手动运行 Pipeline。默认分支推送、PR、其他分支和标签只生成图册 Artifact，不更新公开站点。最新截图失败时，已发布图册保留上次成功版本。

## 发布 Android

`.github/workflows/android-release.yml` 在分支和标签推送时构建 APK，并在 Flutter 检查和模拟器启动检查通过后上传 APK 与 SHA-256 文件。分支推送创建名为 `ci-<完整 commit SHA>` 的预发布，不替换正式版。标签推送上传到同名 Release。也可在 **Actions → Android Release → Run workflow** 中填写已有标签。

创建并推送版本标签：

```sh
git tag v2.0.0
git push origin v2.0.0
```

仓库变量 `API_BASE_URL` 可设置 APK 的默认 HTTPS 服务地址。未设置时，Web 使用当前页面地址，Android 使用模拟器默认地址。

正式签名需要配置以下 GitHub Actions Secrets：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |

未配置正式签名 Secret 时，工作流使用开发签名，并在 Release 说明中标记 APK 为预览包。工作流在 Runner 临时目录生成签名文件，并在结束时清理。工作流使用 `GITHUB_TOKEN` 的 `contents: write` 权限，无需额外 PAT。
