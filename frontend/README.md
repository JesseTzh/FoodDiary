# 做饭日记 Flutter 客户端

共享 Flutter 界面支持 Web CanvasKit PWA 与 Android，详细操作见 [项目说明](../README.md)。

```sh
flutter pub get
flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://localhost:8080
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

Web 发布请从仓库根目录运行 `make web`，生成包含本地 CanvasKit 与 PWA Service Worker 的完整资源。Android 发布使用 `make apk API_BASE_URL=https://your-server.example`。

## 无后端本地调试

仓库根目录运行 `make mock`，或在 frontend 目录运行：

```sh
flutter run -d chrome --web-port=5173 --dart-define=MOCK_API=true
# Android 真机/模拟器同样可用
flutter run --dart-define=MOCK_API=true
```

Mock 默认进入已登录状态，提供跨月份日记、照片、菜谱和收藏。支持日记新增/编辑/删除、照片上传预览、收藏、创建菜谱和个人资料修改；修改会保存至本地，刷新/重启后保留。退出后使用密码 `mock123456` 登录。版本冲突、未登录、记录不存在和主要输入约束也会返回模拟错误。

Mock 不请求后端，不读取真实凭据，快照和数据与正式接口隔离。仅显式传入 `MOCK_API=true` 时开启，正常构建默认关闭。Web 重置数据可在浏览器开发者工具 Application → Local Storage 删除 `flutter.fooddiary:mock:v1` 和 `flutter.snapshot:mock://local` 后刷新；Android 可清除应用数据。图片以 base64 保存，建议使用少量小图，避免耗尽浏览器本地存储配额。

底部导航为触控条保留至少 34 个逻辑像素；系统上报更大的安全区时使用系统值。
