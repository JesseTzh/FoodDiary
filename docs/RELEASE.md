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

所有检查和发布统一在 `.github/workflows/pipeline.yml`（Actions 中的 **Pipeline**）。分支推送、标签推送、PR 和手动运行都会触发，整个流程使用 `prepare` 解析出的同一个 commit。手动输入 `release_tag` 时构建该已有标签，留空则使用当前分支。

| 顺序 | 任务 | 前置条件 |
|---|---|---|
| 1 | 解析并校验构建版本 | 触发 Pipeline |
| 2 | Go vet/测试、Flutter analyze/测试 | 版本解析成功，两项并行 |
| 3 | 生产镜像及 Web 启动检查、Android 构建及模拟器启动、双端模拟页面截图 | 相应代码检查通过，三项并行 |
| 4 | 发布 APK Release、Docker 镜像和 GitHub Pages | 全部验证通过，按触发条件发布 |
| 5 | 部署服务器 | 默认分支的 Docker 镜像推送成功 |

PR 只检查并上传 Artifact，不发布。分支推送发布 `ci-<完整 commit SHA>` APK 预发布，标签推送发布同名 Release。Docker 镜像只在默认分支或 `v*` 标签发布；服务器只部署默认分支。手动指定标签只发布该标签的 APK，不更新默认分支的 Docker、服务器或 Pages。

Web 启动检查在 Docker 镜像上运行 Chromium。它检查首次设置密码、登录后首页和重启后的数据。Artifact `fooddiary-web-startup` 包含截图、浏览器日志、Playwright trace 和容器日志，保留 14 天。失败时也会保存诊断材料。当前容器启动检查使用 amd64；发布镜像同时构建 amd64 和 arm64。

Android 启动检查使用 Android 15（API 35）x86_64 模拟器。检查会安装本次构建的 APK，并查看应用进程、前台 Activity 和致命错误日志。Artifact `fooddiary-android-startup` 包含截图和日志，保留 14 天。该检查只验证启动，不验证登录和 API 功能。

## 界面截图与图册

Pipeline 的 `mock-screenshots` 任务使用 `MOCK_API=true` 构建独立 Web 前端，再用 Playwright 截取手机和桌面页面，与 Android 构建并行运行。手机视口为 390×844，桌面视口为 1440×1080。截图覆盖首页、日记、记录、菜谱、收藏、个人资料、设置和登录流程。正式 APK 不启用模拟数据。

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

请在仓库 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。默认分支每次推送或手动运行 Pipeline（未指定标签），全部验证成功后都会自动发布到 GitHub Pages。PR、其他分支和标签只生成图册 Artifact。公开站点统一由 Pipeline 的 `deploy-gallery` 任务更新。最新截图失败时，已发布图册保留上次成功版本。

## 发布 Android

Pipeline 的 `android` 任务只构建一次 APK，执行模拟器启动检查后上传 APK、SHA-256 和发布说明。全部验证通过后，`release` 任务下载本次已验证产物发布到 GitHub Release。分支推送创建名为 `ci-<完整 commit SHA>` 的预发布，不替换正式版；标签推送上传到同名 Release。也可在 **Actions → Pipeline → Run workflow** 中填写已有 `release_tag`。

创建并推送版本标签：

```sh
git tag v2.0.0
git push origin v2.0.0
```

仓库变量 `API_BASE_URL` 可设置 APK 首次配置时预填的 HTTPS 服务地址。APK 首次启动需确认地址并验证连接，保存后自动复用；未设置变量时需手动输入地址。Web 继续使用当前页面地址（或构建时指定的地址），不显示配置入口。

正式签名需要配置以下 GitHub Actions Secrets：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |

未配置正式签名 Secret 时，工作流使用开发签名，并在 Release 说明中标记 APK 为预览包。工作流在 Runner 临时目录生成签名文件，并在结束时清理。工作流使用 `GITHUB_TOKEN` 的 `contents: write` 权限，无需额外 PAT。

## Android 应用内更新

Android 在启动并确认后端地址后自动检查更新；应用回到前台时每隔至少 6 小时再次检查，也可在“设置 → 检查应用更新”手动触发。检查无需登录。网络异常、旧服务端或 Release 暂未发布时，自动检查静默跳过。版本不同会显示当前版本、服务端版本和下载大小，用户确认后才开始下载。下载期间请保留应用，失败可重试。

版本匹配使用完整 Git commit 和 APK 实际 `versionCode`。Pipeline 为 APK 发布 `android-update.json`，其中记录 commit、显示版本、versionCode、文件名、大小和 SHA-256；Docker 镜像写入同一 commit 及 Release 标签。服务端只选择**与自身代码版本匹配**的 Release（默认分支为 `ci-<完整 commit SHA>`，标签构建为同名 Release），避免获取其他分支或尚未部署的新客户端。Pipeline 先完成 APK Release 发布，再发布 Docker 镜像和部署服务器。

- `GET /api/v1/updates/android`：返回目标 APK 版本信息；未配置版本的开发服务返回 `enabled: false`。版本信息成功缓存 5 分钟、查询失败缓存 30 秒。
- `GET /api/v1/updates/android/download?sha256=<清单中的校验值>`：首次下载时服务端从 GitHub 获取 APK，验证大小和 SHA-256 后缓存到数据目录的 `updates/`，再转发给客户端。并发下载共用缓存，支持 Range 请求，只保留当前安装包。版本已变化时返回 409，客户端需重新检查更新。

客户端仅访问已配置的后端，不直接连接 GitHub。客户端再次校验大小和 SHA-256，并检查包名、versionCode 和签名，再打开系统安装界面；Android 8 及以上首次安装需按系统提示允许该应用安装更新包。用户取消安装后可点击“安装更新”重试。服务端版本低于已安装 APK 的 versionCode 时提示升级服务端，避免尝试覆盖安装旧版本。更新不会静默安装。

Pipeline 构建的镜像无需额外配置。私有仓库或需要提高 GitHub API 限额时可设置：

| 环境变量 | 用途 |
|---|---|
| `FOODDIARY_UPDATE_REPOSITORY` | APK 所在 GitHub 仓库，默认 `JesseTzh/FoodDiary` |
| `FOODDIARY_GITHUB_TOKEN` | 仅保存在服务端、可读取目标仓库 Releases 的 Token，公开仓库可不设置 |
| `FOODDIARY_UPDATE_TAG` | 覆盖目标 Release 标签；镜像内有 commit 时清单仍须匹配该 commit |

自行构建镜像时传入 `--build-arg BUILD_COMMIT="$(git rev-parse HEAD)" --build-arg BUILD_RELEASE_TAG="ci-$(git rev-parse HEAD)"`；该 Release 必须包含 Pipeline 生成的清单与 APK。`make backend` 会写入当前 Git commit，默认选择对应 `ci-<commit>` Release；直接运行 Go 的开发服务可设置 `FOODDIARY_UPDATE_TAG` 来测试指定 Release。旧 Release 没有清单，需通过新 Pipeline 重新构建。

覆盖安装要求始终使用同一正式签名密钥，并保持 versionCode 递增。统一构建脚本使用 UTC 时间戳（自 2000-01-01 起的秒数）生成 versionCode，以避免不同构建之间版本号倒退；Android 的整数上限在 2068 年前仍可满足。不同 Runner 自动生成的开发签名可能不同，不能依赖开发签名实现跨版本更新。签名不匹配时客户端会显示失败原因，保留原应用。已经安装的旧 APK 没有更新功能，需要先手动安装一次包含本功能、签名兼容的新 APK。
