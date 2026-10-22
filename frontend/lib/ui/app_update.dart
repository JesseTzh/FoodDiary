import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api.dart';
import '../version.dart';

class AndroidUpdate {
  final String commit, version, sha256;
  final int versionCode, size;
  final bool canInstall;
  const AndroidUpdate({
    required this.commit,
    required this.version,
    required this.sha256,
    required this.versionCode,
    required this.size,
    required this.canInstall,
  });
}

class AppUpdater {
  static const channel = MethodChannel('fooddiary/updates');
  final Api api;
  final String currentCommit;
  AppUpdater(this.api, {this.currentCommit = appBuildCommit});

  Future<AndroidUpdate?> check() async {
    final installed = await channel.invokeMapMethod<String, dynamic>(
      'installedVersion',
    );
    final currentCode = installed!['versionCode'] as int;
    // Update checks work before login and never send account credentials.
    final response = await api.client
        .get(Uri.parse(api.url('/api/v1/updates/android')))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw Exception('更新包暂未就绪，请稍后重试');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes))['data'];
    if (data['enabled'] == false) return null;
    final release = data['release'] as Map<String, dynamic>;
    final commit = release['commit'] as String;
    final digest = release['sha256'] as String;
    final version = release['version'] as String;
    final code = release['version_code'] as int;
    final size = release['size'] as int;
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        version.isEmpty ||
        code <= 0 ||
        size <= 0 ||
        size > 512 * 1024 * 1024) {
      throw const FormatException('更新信息无效，请稍后重试');
    }
    if (commit == currentCommit && code == currentCode) return null;
    return AndroidUpdate(
      commit: commit,
      version: version,
      sha256: digest,
      versionCode: code,
      size: size,
      canInstall: code >= currentCode,
    );
  }

  Future<void> download(AndroidUpdate update) =>
      channel.invokeMethod<void>('download', {
        'url': api.url(
          '/api/v1/updates/android/download?sha256=${update.sha256}',
        ),
        'sha256': update.sha256,
        'size': update.size,
        'versionCode': update.versionCode,
      });

  Future<void> install(AndroidUpdate update) =>
      channel.invokeMethod<void>('install', {'sha256': update.sha256});
}

bool _updateInProgress = false;

Future<void> checkForAppUpdate(
  BuildContext context,
  Api api, {
  bool automatic = false,
}) async {
  if (!api.canConfigureServer || _updateInProgress) return;
  _updateInProgress = true;
  try {
    final updater = AppUpdater(api);
    final update = await updater.check();
    if (!context.mounted) return;
    if (update == null) {
      if (!automatic) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前暂无可用更新')));
      }
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppUpdateDialog(updater: updater, update: update),
    );
  } catch (_) {
    // Offline, older servers and unpublished releases must not block startup.
    if (!automatic && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('检查更新失败，请检查网络或稍后重试')));
    }
  } finally {
    _updateInProgress = false;
  }
}

class AppUpdateDialog extends StatefulWidget {
  final AppUpdater updater;
  final AndroidUpdate update;
  const AppUpdateDialog({
    super.key,
    required this.updater,
    required this.update,
  });

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool busy = false, downloaded = false;
  double? progress;
  String? error;

  @override
  void initState() {
    super.initState();
    AppUpdater.channel.setMethodCallHandler((call) async {
      if (call.method == 'downloadProgress' && mounted) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        setState(() {
          progress = ((args['received'] as num) / (args['total'] as num)).clamp(
            0.0,
            1.0,
          );
        });
      }
    });
  }

  @override
  void dispose() {
    AppUpdater.channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> downloadAndInstall() async {
    setState(() {
      busy = true;
      error = null;
      if (!downloaded) progress = null;
    });
    try {
      if (!downloaded) {
        await widget.updater.download(widget.update);
        if (!mounted) return;
        setState(() {
          downloaded = true;
          progress = 1;
        });
      }
      await widget.updater.install(widget.update);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          error = e.message ?? '更新失败，请重试';
          if (e.code == 'UPDATE_MISSING') {
            downloaded = false;
            progress = null;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '更新失败，请检查网络和剩余空间后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.update.canInstall ? '发现应用更新' : '应用与服务端版本不一致'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前版本：$appVersion\n服务端版本：${widget.update.version}'),
            const SizedBox(height: 12),
            Text(
              widget.update.canInstall
                  ? '是否下载更新包？大小约 ${(widget.update.size / 1024 / 1024).toStringAsFixed(1)} MB，下载后将打开系统安装界面。'
                  : '服务端版本较旧，Android 无法覆盖安装。请先升级服务端。',
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: downloaded ? 1 : progress),
              const SizedBox(height: 8),
              Text(
                downloaded
                    ? '正在打开安装界面，请按系统提示授权'
                    : progress == null
                    ? '正在准备更新包，首次下载可能需要几分钟…'
                    : '正在下载 ${(progress! * 100).toStringAsFixed(0)}%',
              ),
            ],
            if (downloaded && !busy) ...[
              const SizedBox(height: 12),
              const Text('安装包已下载，可点击“安装更新”再次打开系统安装界面。'),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(downloaded || !widget.update.canInstall ? '关闭' : '暂不更新'),
        ),
        if (widget.update.canInstall)
          FilledButton(
            onPressed: busy ? null : downloadAndInstall,
            child: Text(
              downloaded
                  ? '安装更新'
                  : error != null
                  ? '重试下载'
                  : '下载更新',
            ),
          ),
      ],
    ),
  );
}
