# 做饭日记 Flutter 客户端

共享 Flutter 界面支持 Web CanvasKit PWA 与 Android，详细操作见 [项目说明](../README.md)。

```sh
flutter pub get
flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://localhost:8080
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

Web 发布请从仓库根目录运行 `make web`，生成包含本地 CanvasKit 与 PWA Service Worker 的完整资源。Android 发布使用 `make apk API_BASE_URL=https://your-server.example`。
