# 做饭日记

做饭日记是一个记录做饭过程的应用。它支持手机、桌面和 Web。应用使用 Flutter 构建界面，使用 Go 和 SQLite 保存数据。

## 主要功能

- 记录日期、餐次、菜名、心得、标签、心情和照片。
- 按月份、菜名、心得和标签查找日记。
- 创建、查找和收藏菜谱。
- 查看记录天数、菜谱数和收藏数。
- 在 Web 上安装为 PWA，并在离线时查看已保存内容。
- 在 Android 上使用相机或相册添加照片。

## 快速开始

要求：Flutter 3.47.7、Dart 3.13、Go 1.26。

安装依赖并启动开发环境：

```sh
flutter --version
cd frontend
flutter pub get
cd ..
make dev
```

开发地址：

- Web：<http://localhost:5173>
- API：<http://localhost:8080>

第一次打开应用时，请设置厨房密码。之后使用该密码登录。

只启动前端并使用本地模拟数据：

```sh
make mock
```

## 常用命令

```sh
make check
make build
make apk API_BASE_URL=https://your-server.example
make appbundle API_BASE_URL=https://your-server.example
```

发布 Web 时使用 `make build` 或 `make web`。不要直接使用 `flutter build web`，因为该命令不会生成项目使用的 PWA Service Worker。

## 文档

- [开发说明](docs/DEVELOPMENT.md)：代码结构、接口、认证、PWA、Android 和本地验证。
- [发布说明](docs/RELEASE.md)：Docker、CI、截图图册和 Android Release。
- [前端说明](frontend/README.md)：Flutter 前端开发和模拟数据。

## 数据和部署

默认数据目录是 `./data`。目录包含 SQLite 数据库、照片和签名密钥。生产环境必须使用 HTTPS。请备份整个数据目录，不要把它加入镜像。

主要环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `FOODDIARY_ADDR` | `:8080` | API 监听地址 |
| `FOODDIARY_DATA_DIR` | `./data` | 数据目录 |
| `FOODDIARY_FRONTEND_DIR` | `frontend/build/web` | Web 文件目录 |
| `FOODDIARY_PASSWORD` | 空 | 启动时设置或更改厨房密码 |
| `FOODDIARY_JWT_SECRET` | 自动生成 | JWT 签名密钥 |
| `FOODDIARY_CORS_ORIGINS` | 空 | CORS 来源白名单 |

## 许可和素材

`frontend/assets/images` 中的图片是项目素材。发布前请确认素材有使用许可。Noto Sans SC 使用 SIL Open Font License，许可文件位于 `frontend/assets/fonts/OFL.txt`。
