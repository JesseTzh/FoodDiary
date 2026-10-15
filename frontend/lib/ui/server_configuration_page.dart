import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/api.dart';
import 'theme.dart';

class ServerConfigurationPage extends StatefulWidget {
  final Api api;
  final VoidCallback onSaved;
  final VoidCallback? onCancel;

  const ServerConfigurationPage({
    super.key,
    required this.api,
    required this.onSaved,
    this.onCancel,
  });

  @override
  State<ServerConfigurationPage> createState() =>
      _ServerConfigurationPageState();
}

class _ServerConfigurationPageState extends State<ServerConfigurationPage> {
  late final address = TextEditingController(text: widget.api.base);
  bool busy = false;
  String? error;

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.configureServer(address.text);
      if (mounted) widget.onSaved();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException ? e.message : '连接或保存失败，请检查地址和网络后重试';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('配置后端地址')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.dns_outlined, size: 64, color: gold),
                const SizedBox(height: 24),
                const Text(
                  '连接你的小厨房',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                const Text(
                  '请输入做饭日记后端的访问地址，连接成功后即可登录。地址会保存在本机。',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: address,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => save(),
                  decoration: const InputDecoration(
                    labelText: '后端地址',
                    hintText: 'https://food.example.com',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  kReleaseMode
                      ? '请使用 HTTPS 地址，无需添加 /api/v1。'
                      : '开发版支持 HTTP，如 http://10.0.2.2:8080。无需添加 /api/v1。',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                if (widget.onCancel != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '切换到其他后端后需要重新登录。',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                PrimaryButton(
                  busy ? '正在连接…' : '连接并保存',
                  onPressed: busy ? null : save,
                ),
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: busy ? null : widget.onCancel,
                    child: const Text('取消'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
