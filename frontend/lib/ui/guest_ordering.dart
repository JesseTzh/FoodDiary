import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api.dart';
import 'dish_photo.dart';
import 'theme.dart';

String orderTime(String value) {
  final d = DateTime.parse(value).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String? guestOrderToken(Uri uri) {
  // Hash links work on the Flutter dev server, static hosts, and the Go server.
  final fragment = uri.fragment;
  final route = fragment.startsWith('/') ? Uri.tryParse(fragment) : null;
  return route?.queryParameters['guest_order'] ??
      uri.queryParameters['guest_order'];
}

String guestOrderUrl(Api api, String token) {
  final root = kIsWeb
      ? Uri.base.replace(fragment: '', query: '')
      : Uri.parse(api.base);
  return root
      .replace(queryParameters: {'guest_order': token}, fragment: '/')
      .toString();
}

class GuestOrderRecordsPage extends StatefulWidget {
  final Api api;
  const GuestOrderRecordsPage({super.key, required this.api});
  @override
  State<GuestOrderRecordsPage> createState() => _GuestOrderRecordsPageState();
}

class _GuestOrderRecordsPageState extends State<GuestOrderRecordsPage> {
  List<dynamic>? links;
  String? error;
  bool creating = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => load(quiet: true),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load({bool quiet = false}) async {
    try {
      final result = await widget.api.request('GET', '/order-links');
      if (mounted) {
        setState(() {
          links = result as List;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && !quiet) setState(() => error = '$e');
    }
  }

  Future<void> copyLink(Map link) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: guestOrderUrl(widget.api, link['id'])),
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('点菜链接已复制，可以发给来宾啦')));
      }
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('分享点菜链接'),
          content: SelectableText(guestOrderUrl(widget.api, link['id'])),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> create() async {
    final title = TextEditingController();
    var days = 7;
    DateTime? customExpiry;
    final route = DialogRoute<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('创建点菜分享'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: '分享名称',
                    hintText: '例如：周末来家里吃饭',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: days,
                  decoration: const InputDecoration(labelText: '链接有效期'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('一天')),
                    DropdownMenuItem(value: 7, child: Text('一周（默认）')),
                    DropdownMenuItem(value: 30, child: Text('一个月')),
                    DropdownMenuItem(value: 0, child: Text('自定义过期时间')),
                  ],
                  onChanged: (v) => update(() => days = v!),
                ),
                if (days == 0)
                  TextButton.icon(
                    icon: const Icon(Icons.schedule),
                    label: Text(
                      customExpiry == null
                          ? '选择日期和时间'
                          : orderTime(customExpiry!.toIso8601String()),
                    ),
                    onPressed: () async {
                      final now = DateTime.now();
                      final date = await showDatePicker(
                        context: context,
                        initialDate:
                            customExpiry ?? now.add(const Duration(days: 7)),
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 89)),
                      );
                      if (date == null || !context.mounted) return;
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(
                          customExpiry ?? now,
                        ),
                      );
                      if (time != null && context.mounted) {
                        update(
                          () => customExpiry = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            time.hour,
                            time.minute,
                          ),
                        );
                      }
                    },
                  ),
                const SizedBox(height: 12),
                const Text(
                  '来宾可浏览当前全部菜谱并下单，无需登录。',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  days == 0 &&
                      (customExpiry == null ||
                          !customExpiry!.isAfter(DateTime.now()))
                  ? null
                  : () => Navigator.pop(context, {
                      'title': title.text.trim(),
                      'expires_at':
                          (days == 0
                                  ? customExpiry!
                                  : DateTime.now().add(Duration(days: days)))
                              .toUtc()
                              .toIso8601String(),
                    }),
              child: const Text('创建链接'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    title.dispose();
    if (result == null || !mounted) return;
    setState(() => creating = true);
    try {
      final link = await widget.api.request('POST', '/order-links', result);
      if (!mounted) return;
      await load();
      if (mounted) await copyLink(link);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('点菜记录'),
      actions: [
        IconButton(
          tooltip: '刷新点菜记录',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: creating ? null : create,
      tooltip: '创建点菜分享',
      child: creating
          ? const CircularProgressIndicator()
          : const Icon(Icons.add),
    ),
    body: error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: load, child: const Text('重试')),
              ],
            ),
          )
        : links == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const Text(
                  '来宾点菜',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '创建分享邀请朋友选菜，下单后会显示在这里。',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 20),
                if (links!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 90),
                    child: Center(child: Text('还没有点菜记录，点击右下角 + 创建分享')),
                  ),
                for (final link in links!) ...[
                  _linkCard(link),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
  );

  Widget _linkCard(Map link) {
    final expired = !DateTime.parse(link['expires_at']).isAfter(DateTime.now());
    final orders = link['orders'] as List;
    return CozyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  link['title'],
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Tag(expired ? '已过期' : '可点菜'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '有效至 ${orderTime(link['expires_at'])}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          Row(
            children: [
              Text('${orders.length} 笔订单'),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        GuestMenuPage(api: widget.api, token: link['id']),
                  ),
                ),
                child: const Text('查看菜单'),
              ),
              TextButton(
                onPressed: expired ? null : () => copyLink(link),
                child: const Text('复制链接'),
              ),
            ],
          ),
          if (orders.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('还没有来宾下单', style: TextStyle(color: muted)),
            ),
          for (final order in orders) ...[
            const Divider(),
            Text(
              '${order['guest_name']} · ${orderTime(order['created_at'])}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final item in order['items'])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(item['title'])),
                    Text('× ${item['quantity']}'),
                  ],
                ),
              ),
            if ((order['note'] as String).isNotEmpty)
              Text('备注：${order['note']}', style: const TextStyle(color: muted)),
          ],
        ],
      ),
    );
  }
}

class GuestMenuPage extends StatefulWidget {
  final Api api;
  final String token;
  const GuestMenuPage({super.key, required this.api, required this.token});
  @override
  State<GuestMenuPage> createState() => _GuestMenuPageState();
}

class _GuestMenuPageState extends State<GuestMenuPage> {
  Map<String, dynamic>? menu;
  String? error;
  String selectedTag = '全部';
  final cart = <String, int>{};
  final name = TextEditingController();
  final note = TextEditingController();
  bool submitting = false;
  bool expired = false;
  String? requestId;
  Map<String, dynamic>? submitted;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    note.dispose();
    super.dispose();
  }

  List<dynamic> get recipes => menu?['recipes'] as List? ?? [];
  int get count => cart.values.fold(0, (a, b) => a + b);
  bool get canOrder =>
      !expired &&
      menu != null &&
      DateTime.parse(menu!['expires_at']).isAfter(DateTime.now());

  Future<void> load() async {
    try {
      final result = await widget.api.request(
        'GET',
        '/guest/order/${Uri.encodeComponent(widget.token)}',
      );
      if (mounted) {
        setState(() {
          menu = Map<String, dynamic>.from(result);
          error = null;
          expired = false;
          final available = recipes.map((r) => r['id']).toSet();
          cart.removeWhere((key, _) => !available.contains(key));
          if (!{
            '全部',
            ...recipes.expand((r) => (r['tags'] as List).cast<String>()),
          }.contains(selectedTag)) {
            selectedTag = '全部';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiError && (e.status == 410 || e.status == 404)) {
            expired = true;
          }
        });
      }
    }
  }

  void change(String id, int delta) {
    if (submitting || !canOrder) return;
    setState(() {
      final next = ((cart[id] ?? 0) + delta).clamp(0, 99);
      if (next == 0) {
        cart.remove(id);
      } else {
        cart[id] = next;
      }
      requestId = null;
    });
  }

  Widget quantity(String id, {VoidCallback? after}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (cart.containsKey(id)) ...[
        IconButton(
          tooltip: '减少一份',
          onPressed: submitting || !canOrder
              ? null
              : () {
                  change(id, -1);
                  after?.call();
                },
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('${cart[id]}'),
      ],
      IconButton(
        tooltip: '添加一份',
        onPressed: submitting || !canOrder || (cart[id] ?? 0) >= 99
            ? null
            : () {
                change(id, 1);
                after?.call();
              },
        icon: const Icon(Icons.add_circle),
        color: gold,
      ),
    ],
  );

  Future<void> checkout() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '购物车',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: submitting || cart.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  cart.clear();
                                  requestId = null;
                                });
                                update(() {});
                              },
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                  if (cart.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有选菜，先去挑几道吧'),
                    ),
                  for (final r in recipes.where(
                    (r) => cart.containsKey(r['id']),
                  ))
                    Row(
                      children: [
                        Expanded(child: Text(r['title'])),
                        quantity(r['id'], after: () => update(() {})),
                      ],
                    ),
                  TextField(
                    controller: name,
                    enabled: !submitting,
                    maxLength: 30,
                    decoration: const InputDecoration(labelText: '怎么称呼你（选填）'),
                    onChanged: (_) => requestId = null,
                  ),
                  TextField(
                    controller: note,
                    enabled: !submitting,
                    maxLength: 200,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: '口味或其他备注（选填）'),
                    onChanged: (_) => requestId = null,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: submitting || cart.isEmpty || !canOrder
                          ? null
                          : () async {
                              setState(() => submitting = true);
                              update(() {});
                              requestId ??= List.generate(
                                24,
                                (_) => Random.secure()
                                    .nextInt(256)
                                    .toRadixString(16)
                                    .padLeft(2, '0'),
                              ).join();
                              try {
                                final result = await widget.api.request(
                                  'POST',
                                  '/guest/order/${Uri.encodeComponent(widget.token)}/orders',
                                  {
                                    'request_id': requestId,
                                    'guest_name': name.text.trim(),
                                    'note': note.text.trim(),
                                    'items': [
                                      for (final e in cart.entries)
                                        {
                                          'recipe_id': e.key,
                                          'quantity': e.value,
                                        },
                                    ],
                                  },
                                );
                                if (!mounted) return;
                                setState(() {
                                  submitted = Map<String, dynamic>.from(result);
                                  cart.clear();
                                  requestId = null;
                                });
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              } catch (e) {
                                if (mounted &&
                                    e is ApiError &&
                                    e.status == 410) {
                                  setState(() => expired = true);
                                }
                                if (sheetContext.mounted) {
                                  ScaffoldMessenger.of(
                                    sheetContext,
                                  ).showSnackBar(SnackBar(content: Text('$e')));
                                }
                              } finally {
                                if (mounted) setState(() => submitting = false);
                                if (sheetContext.mounted) update(() {});
                              }
                            },
                      child: Text(submitting ? '正在下单…' : '下单 · 共 $count 份'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tags = <String>{
      '全部',
      ...recipes.expand((r) => (r['tags'] as List).cast<String>()),
    }.toList();
    final visible = recipes
        .where(
          (r) =>
              selectedTag == '全部' || (r['tags'] as List).contains(selectedTag),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(menu?['title'] ?? '来宾点菜'),
        actions: [
          IconButton(
            tooltip: '刷新菜单',
            onPressed: submitting ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: menu == null || submitted != null
          ? null
          : FloatingActionButton.extended(
              onPressed: checkout,
              icon: const Icon(Icons.shopping_bag_outlined),
              label: Text('购物车 ($count)'),
            ),
      body: submitted != null
          ? _receipt()
          : error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      expired ? Icons.timer_off_outlined : Icons.cloud_off,
                      size: 48,
                      color: muted,
                    ),
                    const SizedBox(height: 16),
                    Text(error!, textAlign: TextAlign.center),
                    if (!expired)
                      TextButton(onPressed: load, child: const Text('重试')),
                  ],
                ),
              ),
            )
          : menu == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '今天想吃什么？',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '有效至 ${orderTime(menu!['expires_at'])}',
                        style: const TextStyle(color: muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 88,
                        child: ColoredBox(
                          color: const Color(0xFFFFEFD9),
                          child: ListView(
                            children: [
                              for (final tag in tags)
                                Material(
                                  color: selectedTag == tag
                                      ? Colors.white
                                      : Colors.transparent,
                                  child: InkWell(
                                    onTap: () =>
                                        setState(() => selectedTag = tag),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 20,
                                      ),
                                      child: Text(
                                        tag,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: selectedTag == tag
                                              ? ink
                                              : muted,
                                          fontWeight: selectedTag == tag
                                              ? FontWeight.w700
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: visible.isEmpty
                            ? const Center(child: Text('暂无菜谱'))
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  100,
                                ),
                                itemCount: visible.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (context, i) {
                                  final r = visible[i];
                                  final photos = r['photos'] as List? ?? [];
                                  final cover =
                                      photos
                                          .where(
                                            (p) =>
                                                p['id'] == r['cover_media_id'],
                                          )
                                          .firstOrNull ??
                                      photos.firstOrNull;
                                  final image =
                                      cover?['url'] as String? ??
                                      ((r['image'] as String? ?? '').isEmpty
                                          ? null
                                          : r['image'] as String);
                                  return CozyCard(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (image != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 10,
                                            ),
                                            child: DishPhoto(
                                              api: widget.api,
                                              path: image,
                                              height: 126,
                                              width: double.infinity,
                                              crop: cropFromMedia(cover),
                                            ),
                                          ),
                                        Text(
                                          r['title'],
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        if ((r['description'] as String)
                                            .isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: Text(
                                              r['description'],
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: muted,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                (r['tags'] as List).join(' · '),
                                                style: const TextStyle(
                                                  color: muted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            quantity(r['id']),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _receipt() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Icon(Icons.check_circle_outline, size: 64, color: gold),
      const SizedBox(height: 16),
      const Center(
        child: Text(
          '下单成功',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
      ),
      const Center(
        child: Text('主人已经可以看到你点的菜啦', style: TextStyle(color: muted)),
      ),
      const SizedBox(height: 24),
      for (final item in submitted!['items'])
        ListTile(
          title: Text(item['title']),
          trailing: Text('× ${item['quantity']}'),
        ),
      if ((submitted!['note'] as String).isNotEmpty)
        Text('备注：${submitted!['note']}'),
      const SizedBox(height: 20),
      Text(
        '下单时间：${orderTime(submitted!['created_at'])}',
        style: const TextStyle(color: muted),
      ),
      TextButton(
        onPressed: () => setState(() => submitted = null),
        child: const Text('继续点菜'),
      ),
    ],
  );
}
