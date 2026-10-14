import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'theme.dart';

/// Reads the capture date stored in common image metadata.
///
/// Camera photos usually store this in JPEG EXIF DateTimeOriginal. The text
/// fallback also handles PNG comments and exports from apps that preserve the
/// date as an ISO-like string.
DateTime? imageDateFromBytes(Uint8List bytes) {
  final exifDate = _jpegExifDate(bytes);
  if (exifDate != null) return exifDate;
  final text = String.fromCharCodes(bytes.where((b) => b >= 32 && b <= 126));
  final match = RegExp(
    r'(20\d{2})[:\-](\d{2})[:\-](\d{2})(?:[ T](\d{2})[:\-](\d{2})(?::(\d{2}))?)?',
  ).firstMatch(text);
  if (match == null) return null;
  return _validDate(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

DateTime? _jpegExifDate(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    final marker = bytes[offset + 1];
    offset += 2;
    if (marker == 0xda || marker == 0xd9) break;
    if (offset + 2 > bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    if (marker == 0xe1 &&
        length >= 8 &&
        String.fromCharCodes(bytes.sublist(offset + 2, offset + 8)) ==
            'Exif\u0000\u0000') {
      final result = _readExifTiff(bytes, offset + 8, offset + length);
      if (result != null) return result;
    }
    offset += length;
  }
  return null;
}

DateTime? _readExifTiff(Uint8List bytes, int start, int end) {
  if (start + 8 > end) return null;
  final little = bytes[start] == 0x49 && bytes[start + 1] == 0x49;
  if (!little && !(bytes[start] == 0x4d && bytes[start + 1] == 0x4d))
    return null;
  int u16(int p) =>
      little ? bytes[p] | bytes[p + 1] << 8 : bytes[p] << 8 | bytes[p + 1];
  int u32(int p) => little
      ? bytes[p] | bytes[p + 1] << 8 | bytes[p + 2] << 16 | bytes[p + 3] << 24
      : bytes[p] << 24 | bytes[p + 1] << 16 | bytes[p + 2] << 8 | bytes[p + 3];
  if (u16(start + 2) != 42) return null;
  DateTime? readIfd(int at, int depth) {
    if (depth > 2 || at < start || at + 2 > end) return null;
    final count = u16(at);
    for (var i = 0; i < count; i++) {
      final p = at + 2 + i * 12;
      if (p + 12 > end) break;
      final tag = u16(p);
      final type = u16(p + 2);
      final n = u32(p + 4);
      final size = type == 2 ? n : 0;
      final valueAt = size > 4 ? start + u32(p + 8) : p + 8;
      if ((tag == 0x9003 || tag == 0x9004 || tag == 0x0132) &&
          type == 2 &&
          valueAt >= start &&
          valueAt + size <= end) {
        final value = String.fromCharCodes(
          bytes.sublist(valueAt, valueAt + size),
        );
        final match = RegExp(r'(20\d{2})[:\-](\d{2})[:\-](\d{2})')
            .firstMatch(value);
        if (match != null) {
          final parsed = _validDate(
            int.parse(match.group(1)!),
            int.parse(match.group(2)!),
            int.parse(match.group(3)!),
          );
          if (parsed != null) return parsed;
        }
      }
      if ((tag == 0x8769 || tag == 0x8825) && type == 4 && n == 1) {
        final nested = readIfd(start + u32(p + 8), depth + 1);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  return readIfd(start + u32(start + 4), 0);
}

DateTime? _validDate(int year, int month, int day) {
  final value = DateTime.tryParse(
    '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
  );
  return value != null &&
          value.year == year &&
          value.month == month &&
          value.day == day
      ? value
      : null;
}

class DishPhoto extends StatelessWidget {
  final Api api;
  final String? path;
  final double? width;
  final double height;
  const DishPhoto({
    super.key,
    required this.api,
    this.path,
    this.width,
    this.height = 220,
  });
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      width: width,
      height: height,
      child: path == null
          ? placeholder()
          : api.mock && path!.startsWith('asset:')
          ? Image.asset(path!.substring(6), fit: BoxFit.cover)
          : api.mock && path!.startsWith('data:')
          ? Image.memory(
              base64Decode(path!.split(',').last),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder(),
            )
          : Image.network(
              api.url(path!),
              headers: kIsWeb ? null : api.headers,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder(),
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : placeholder(),
            ),
    ),
  );
  Widget placeholder() => Container(
    color: const Color(0xFFFFEFD9),
    child: const Center(
      child: Icon(
        Icons.ramen_dining_rounded,
        color: Color(0xFFDBAC76),
        size: 40,
      ),
    ),
  );
}

class WelcomePage extends StatefulWidget {
  final Api api;
  final bool setup, loading;
  final String? error;
  final Future<void> Function() onAuthenticated;
  const WelcomePage({
    super.key,
    required this.api,
    required this.setup,
    required this.loading,
    required this.onAuthenticated,
    this.error,
  });
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final password = TextEditingController();
  bool busy = false, obscure = true;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (password.text.length < 6) {
      toast(context, '密码至少需要 6 位');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.api.request(
        'POST',
        widget.setup ? '/auth/setup' : '/auth/login',
        {'password': password.text},
      );
      await widget.onAuthenticated();
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(50),
                  child: Image.asset('assets/images/app-logo.png', width: 180),
                ),
                const SizedBox(height: 26),
                const Text(
                  '做饭日记',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 12),
                const SizedBox(height: 36),
                if (widget.loading)
                  const CircularProgressIndicator(color: gold)
                else if (widget.error != null) ...[
                  const Text(
                    '暂时连接不上厨房',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.error!.replaceFirst('Exception: ', ''),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  PrimaryButton('重新连接', onPressed: widget.onAuthenticated),
                ] else ...[
                  TestId(
                    widget.setup
                        ? 'first-run-password-prompt'
                        : 'login-password-prompt',
                    child: Text(
                      widget.setup ? '给我们的小厨房设一个密码' : '欢迎回到我们的小厨房',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TestId(
                    widget.setup
                        ? 'setup-password-input'
                        : 'login-password-input',
                    child: TextField(
                      controller: password,
                      obscureText: obscure,
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        hintText: widget.setup ? '设置密码（至少 6 位）' : '输入厨房密码',
                        prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 19,
                          ),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: const BorderSide(color: line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: const BorderSide(color: line),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  PrimaryButton(
                    busy
                        ? '正在打开厨房…'
                        : widget.setup
                        ? '开启做饭日记'
                        : '进入小厨房',
                    semanticIdentifier: widget.setup
                        ? 'setup-submit'
                        : 'login-submit',
                    onPressed: busy ? null : submit,
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class RecordPage extends StatefulWidget {
  final Api api;
  final Diary? entry;
  final String? initialTitle;
  final List<Recipe> recipes;
  const RecordPage({
    super.key,
    required this.api,
    this.entry,
    this.initialTitle,
    this.recipes = const [],
  });
  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  final form = GlobalKey<FormState>();
  late TextEditingController notes;
  final customTag = TextEditingController();
  late DateTime date;
  String meal = '晚餐', category = '家常菜';
  int mood = 0;
  final Set<String> tags = {};
  final List<XFile> files = [];
  final List<int> fileDishIndices = [];
  final List<Uint8List> previews = [];
  final List<Map<String, dynamic>> dishes = [];
  List<Recipe> recipes = [];
  bool showCustomTag = false;
  bool saving = false;
  String? savedId;
  int uploaded = 0;
  int photoDishIndex = 0;
  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    notes = TextEditingController(text: e?.notes ?? '');
    date = e == null ? DateTime.now() : DateTime.parse(e.date);
    meal = e?.meal ?? meal;
    category = categories.contains(e?.category) ? e!.category : category;
    mood = e?.mood ?? 0;
    tags.addAll(e?.tags ?? []);
    dishes.addAll(
      e?.dishes.isNotEmpty == true
          ? e!.dishes
          : [
              {'id': '', 'title': e?.title ?? widget.initialTitle ?? ''},
            ],
    );
    recipes = widget.recipes;
    if (recipes.isEmpty) {
      widget.api.request('GET', '/recipes').then((v) {
        if (mounted) {
          setState(() => recipes = (v as List).map((r) => Recipe(r)).toList());
        }
      });
    }
  }

  @override
  void dispose() {
    notes.dispose();
    customTag.dispose();
    super.dispose();
  }

  void addCustomTag() {
    final value = customTag.text.trim();
    if (value.isEmpty) return;
    if (value.length > 20) {
      toast(context, '自定义标签不能超过 20 个字');
      return;
    }
    setState(() {
      tags.add(value);
      customTag.clear();
      showCustomTag = false;
    });
  }

  Future<void> pick(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final selected = source == ImageSource.camera
          ? [
              await picker.pickImage(
                source: source,
                maxWidth: 1600,
                imageQuality: 85,
              ),
            ]
          : await picker.pickMultiImage(maxWidth: 1600, imageQuality: 85);
      final room = 9 - (widget.entry?.photos.length ?? 0) - files.length;
      final incoming = selected.whereType<XFile>().take(room).toList();
      DateTime? suggestedDate;
      for (final f in incoming) {
        final data = await f.readAsBytes();
        if (data.length > 20 * 1024 * 1024) {
          if (mounted) toast(context, '单张照片不能超过 20 MB');
          continue;
        }
        if (mounted) {
          setState(() {
            files.add(f);
            previews.add(data);
            fileDishIndices.add(photoDishIndex.clamp(0, dishes.length - 1));
          });
        }
        suggestedDate ??= imageDateFromBytes(data);
      }
      if (suggestedDate != null && !_sameDay(suggestedDate!, date) && mounted) {
        final useImageDate = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('发现照片日期'),
            content: Text(
              '照片信息显示拍摄日期为 ${suggestedDate!.toIso8601String().substring(0, 10)}，与当前做饭日期不同。要使用照片日期吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续使用当前日期'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('使用照片日期'),
              ),
            ],
          ),
        );
        if (useImageDate == true && mounted) {
          setState(() => date = suggestedDate!);
        }
      }
      if (selected.length > room && mounted) toast(context, '最多可以保存 9 张照片');
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      if (savedId == null) {
        final body = {
          ...?widget.entry?.toJson(),
          'title': dishes.first['title'],
          'dishes': dishes
              .map((d) => {'id': d['id'], 'title': d['title']})
              .toList(),
          'notes': notes.text.trim(),
          'cooked_on': date.toIso8601String().substring(0, 10),
          'meal': meal,
          'category': category,
          'mood': mood,
          'tags': tags.toList(),
        };
        final result = await widget.api.request(
          widget.entry == null ? 'POST' : 'PATCH',
          widget.entry == null ? '/entries' : '/entries/${widget.entry!.id}',
          body,
        );
        savedId = result['id'];
        if (result['dishes'] is List) {
          dishes
            ..clear()
            ..addAll(
              (result['dishes'] as List).map(
                (d) => {'id': d['id'] ?? '', 'title': d['title'] ?? ''},
              ),
            );
        }
      }
      while (uploaded < files.length) {
        final index = fileDishIndices[uploaded].clamp(0, dishes.length - 1);
        final dishId = dishes[index]['id']?.toString();
        await widget.api.upload(
          savedId!,
          files[uploaded],
          recipeId: dishId == null || dishId.isEmpty ? null : dishId,
        );
        uploaded++;
      }
      if (mounted) {
        toast(context, '这份美味回忆已经保存 ♥');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        toast(context, savedId == null ? e : '日记已保存，照片上传失败。点击保存重试，或返回后编辑补传。');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.entry == null ? '记录做饭' : '编辑日记')),
      body: PageBody(
        children: [
          Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CozyCard(
                  child: Column(
                    children: [
                      const Icon(
                        Icons.camera_alt_outlined,
                        size: 30,
                        color: Color(0xFF8C6746),
                      ),
                      const SizedBox(height: 8),
                      const Text('晒晒今天的美味', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 4),
                      const Text(
                        '最多可添加 9 张照片',
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                      const SizedBox(height: 12),
                      DropdownButton<int>(
                        isExpanded: true,
                        value: photoDishIndex.clamp(0, dishes.length - 1),
                        onChanged: savedId != null
                            ? null
                            : (v) {
                                if (v != null) {
                                  setState(() => photoDishIndex = v);
                                }
                              },
                        items: [
                          for (var i = 0; i < dishes.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                '照片归属：${dishes[i]['title'].toString().isEmpty ? '第 ${i + 1} 道菜' : dishes[i]['title']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: saving || savedId != null
                                ? null
                                : () => pick(ImageSource.gallery),
                            icon: const Icon(
                              Icons.photo_library_outlined,
                              size: 18,
                            ),
                            label: const Text('选择照片'),
                          ),
                          TextButton.icon(
                            onPressed: saving || savedId != null
                                ? null
                                : () => pick(ImageSource.camera),
                            icon: const Icon(
                              Icons.camera_alt_outlined,
                              size: 18,
                            ),
                            label: const Text('拍照'),
                          ),
                        ],
                      ),
                      if (previews.isNotEmpty ||
                          widget.entry?.photos.isNotEmpty == true)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final path
                                in widget.entry?.photos ?? <String>[])
                              DishPhoto(
                                api: widget.api,
                                path: path,
                                width: 76,
                                height: 76,
                              ),
                            for (var i = 0; i < previews.length; i++)
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.memory(
                                          previews[i],
                                          width: 76,
                                          height: 76,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      if (savedId == null)
                                        Positioned(
                                          top: -8,
                                          right: -8,
                                          child: IconButton(
                                            onPressed: saving
                                                ? null
                                                : () => setState(() {
                                                    files.removeAt(i);
                                                    previews.removeAt(i);
                                                    fileDishIndices.removeAt(i);
                                                  }),
                                            icon: const Icon(
                                              Icons.cancel,
                                              color: ink,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  SizedBox(
                                    width: 130,
                                    child: DropdownButton<int>(
                                      isExpanded: true,
                                      value: fileDishIndices[i],
                                      onChanged: saving || savedId != null
                                          ? null
                                          : (v) {
                                              if (v != null) {
                                                setState(
                                                  () => fileDishIndices[i] = v,
                                                );
                                              }
                                            },
                                      items: [
                                        for (var d = 0; d < dishes.length; d++)
                                          DropdownMenuItem(
                                            value: d,
                                            child: Text(
                                              dishes[d]['title']
                                                      .toString()
                                                      .trim()
                                                      .isEmpty
                                                  ? '第 ${d + 1} 道菜'
                                                  : dishes[d]['title'],
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                label('今天做的菜'),
                for (var i = 0; i < dishes.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Autocomplete<Recipe>(
                            key: ObjectKey(dishes[i]),
                            initialValue: TextEditingValue(
                              text: dishes[i]['title'] ?? '',
                            ),
                            optionsBuilder: (v) => v.text.trim().isEmpty
                                ? const []
                                : recipes.where(
                                    (r) => r.title.toLowerCase().contains(
                                      v.text.trim().toLowerCase(),
                                    ),
                                  ),
                            displayStringForOption: (r) => r.title,
                            onSelected: (r) => setState(() {
                              dishes[i].addAll({'id': r.id, 'title': r.title});
                            }),
                            fieldViewBuilder:
                                (
                                  context,
                                  controller,
                                  focus,
                                  submit,
                                ) => TextFormField(
                                  controller: controller,
                                  focusNode: focus,
                                  readOnly: savedId != null,
                                  maxLength: 80,
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                      ? '写下今天做的菜吧'
                                      : null,
                                  onChanged: (v) => setState(
                                    () => dishes[i].addAll({
                                      'id': '',
                                      'title': v,
                                    }),
                                  ),
                                  decoration: InputDecoration(
                                    hintText: '菜名',
                                    counterText: '',
                                    suffixIcon: i > 0
                                        ? IconButton(
                                            tooltip: '移除这道菜',
                                            onPressed: savedId == null
                                                ? () {
                                                    if (fileDishIndices
                                                        .contains(i)) {
                                                      toast(
                                                        context,
                                                        '请先修改这道菜的照片归属或移除照片',
                                                      );
                                                      return;
                                                    }
                                                    setState(() {
                                                      dishes.removeAt(i);
                                                      for (
                                                        var f = 0;
                                                        f <
                                                            fileDishIndices
                                                                .length;
                                                        f++
                                                      ) {
                                                        if (fileDishIndices[f] >
                                                            i) {
                                                          fileDishIndices[f]--;
                                                        }
                                                      }
                                                      photoDishIndex =
                                                          photoDishIndex == i
                                                          ? 0
                                                          : photoDishIndex > i
                                                          ? photoDishIndex - 1
                                                          : photoDishIndex;
                                                    });
                                                  }
                                                : null,
                                            icon: const Icon(Icons.close),
                                          )
                                        : null,
                                  ),
                                ),
                            optionsViewBuilder: (context, select, options) =>
                                Align(
                                  alignment: Alignment.topLeft,
                                  child: Material(
                                    elevation: 4,
                                    child: SizedBox(
                                      width: 280,
                                      child: ListView(
                                        shrinkWrap: true,
                                        children: options
                                            .map(
                                              (r) => ListTile(
                                                title: Text(r.title),
                                                onTap: () => select(r),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: savedId != null || dishes.length >= 20
                        ? null
                        : () => setState(
                            () => dishes.add({'id': '', 'title': ''}),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('再添加一道菜'),
                  ),
                ),
                const SizedBox(height: 8),
                label('做饭日期'),
                OutlinedButton.icon(
                  onPressed: savedId != null
                      ? null
                      : () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (d != null) setState(() => date = d);
                        },
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(date.toIso8601String().substring(0, 10)),
                ),
                const SizedBox(height: 18),
                label('餐次'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ['早餐', '午餐', '晚餐', '下午茶']
                      .map(
                        (m) => Tag(
                          m,
                          selected: meal == m,
                          onTap: savedId != null
                              ? null
                              : () => setState(() => meal = m),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 22),
                label('心得记录'),
                TextFormField(
                  controller: notes,
                  readOnly: savedId != null,
                  maxLength: 200,
                  maxLines: 3,
                  decoration: const InputDecoration(hintText: '今天的做饭心得…'),
                ),
                const SizedBox(height: 8),
                label('标签'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in {...diaryTags, ...tags})
                      Tag(
                        t,
                        selected: tags.contains(t),
                        onTap: savedId != null
                            ? null
                            : () => setState(() {
                                tags.contains(t) ? tags.remove(t) : tags.add(t);
                              }),
                      ),
                    Tag(
                      '+',
                      onTap: savedId != null
                          ? null
                          : () =>
                                setState(() => showCustomTag = !showCustomTag),
                    ),
                  ],
                ),
                if (showCustomTag) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          autofocus: true,
                          controller: customTag,
                          readOnly: savedId != null,
                          maxLength: 20,
                          onSubmitted: (_) => addCustomTag(),
                          decoration: const InputDecoration(
                            hintText: '添加自定义标签',
                            counterText: '',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: savedId != null ? null : addCustomTag,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                label('心情'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(
                    5,
                    (i) => Semantics(
                      label: ['满足', '幸福', '开心', '惊喜', '不太顺利'][i],
                      selected: mood == i,
                      button: true,
                      child: InkWell(
                        onTap: savedId != null
                            ? null
                            : () => setState(() => mood = i),
                        borderRadius: BorderRadius.circular(16),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: mood == i
                                ? const Color(0xFFFFEACB)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            moods[i],
                            style: const TextStyle(fontSize: 26),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                PrimaryButton(
                  saving
                      ? '正在保存美味…'
                      : savedId != null
                      ? '重试上传照片'
                      : '保存',
                  onPressed: saving ? null : save,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget label(String title) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: Text(
    title,
    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
  ),
);

class DiaryPage extends StatefulWidget {
  final Api api;
  final Diary entry;
  final bool offline;
  const DiaryPage({
    super.key,
    required this.api,
    required this.entry,
    this.offline = false,
  });
  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  late Diary entry;
  int photo = 0;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    entry = widget.entry;
  }

  Future<void> edit() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordPage(api: widget.api, entry: entry),
      ),
    );
    try {
      final value = await widget.api.request('GET', '/entries/${entry.id}');
      if (mounted) setState(() => entry = Diary(value));
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  Future<void> toggle() async {
    setState(() => busy = true);
    try {
      await widget.api.request('PATCH', '/entries/${entry.id}/favorite', {
        'favorite': !entry.favorite,
      });
      final value = await widget.api.request('GET', '/entries/${entry.id}');
      if (mounted) setState(() => entry = Diary(value));
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份日记？'),
        content: const Text('删除后，这份美味回忆将从日记中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => busy = true);
    try {
      await widget.api.request('DELETE', '/entries/${entry.id}');
      if (mounted) {
        toast(context, '日记已删除');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('美味回忆'),
      actions: [
        IconButton(
          tooltip: '收藏日记',
          onPressed: widget.offline || busy ? null : toggle,
          icon: Icon(
            entry.favorite ? Icons.favorite : Icons.favorite_border,
            color: const Color(0xFFFF9284),
          ),
        ),
      ],
    ),
    body: PageBody(
      children: [
        DishPhoto(
          api: widget.api,
          path: entry.photos.isEmpty ? null : entry.photos[photo],
          width: double.infinity,
          height: 265,
        ),
        const SizedBox(height: 22),
        Text(
          '${entry.date}    ${entry.meal}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Text(
          entry.title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
        ),
        if (entry.dishes.length > 1) ...[
          const SizedBox(height: 12),
          label('今天的菜'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entry.dishes
                .map((dish) => Tag(dish['title'] ?? ''))
                .toList(),
          ),
        ],
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        Text(
          entry.notes.isEmpty ? '今天也好好吃饭了，给自己一个小小的拥抱。' : entry.notes,
          style: const TextStyle(height: 2, fontSize: 15),
        ),
        const SizedBox(height: 24),
        if (entry.photos.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(
                entry.photos.length,
                (i) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() => photo = i),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: photo == i ? orange : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: DishPhoto(
                        api: widget.api,
                        path: entry.photos[i],
                        width: 78,
                        height: 78,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
        label('标签'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: entry.tags.isEmpty
              ? [const Tag('美味日常')]
              : entry.tags.map((t) => Tag(t)).toList(),
        ),
        const SizedBox(height: 22),
        label('心情'),
        Text(
          moods[entry.mood.clamp(0, 4)],
          style: const TextStyle(fontSize: 32),
        ),
        const SizedBox(height: 30),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.offline || busy ? null : edit,
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('编辑'),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              tooltip: '删除日记',
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFFF9284),
              ),
              onPressed: widget.offline || busy ? null : remove,
              icon: const Icon(Icons.delete_outline, color: Colors.white),
            ),
          ],
        ),
      ],
    ),
  );
}

class RecipePage extends StatefulWidget {
  final Api api;
  final Recipe recipe;
  final bool offline;
  const RecipePage({
    super.key,
    required this.api,
    required this.recipe,
    this.offline = false,
  });
  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  late Recipe recipe;
  late bool favorite;
  bool busy = false;
  late List<dynamic> photos;
  String? coverMediaId;
  @override
  void initState() {
    super.initState();
    recipe = widget.recipe;
    favorite = recipe.favorite;
    photos = List<dynamic>.from(widget.recipe.photos);
    coverMediaId = widget.recipe.coverMediaId;
  }

  Future<void> toggle() async {
    setState(() => busy = true);
    try {
      await widget.api.request(
        'PATCH',
        '/recipes/${widget.recipe.id}/favorite',
        {'favorite': !favorite},
      );
      if (mounted) setState(() => favorite = !favorite);
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> selectCover(String mediaId) async {
    try {
      await widget.api.request('PATCH', '/recipes/${widget.recipe.id}/cover', {
        'media_id': mediaId,
      });
      if (mounted) setState(() => coverMediaId = mediaId);
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = recipe;
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日菜谱'),
        actions: [
          IconButton(
            tooltip: '编辑菜谱',
            onPressed: widget.offline || busy
                ? null
                : () async {
                    final result = await Navigator.of(context).push<Recipe>(
                      MaterialPageRoute(
                        builder: (_) =>
                            NewRecipePage(api: widget.api, recipe: recipe),
                      ),
                    );
                    if (result != null && mounted) {
                      setState(() => recipe = result);
                    }
                  },
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '收藏菜谱',
            onPressed: widget.offline || busy ? null : toggle,
            icon: Icon(
              favorite ? Icons.favorite : Icons.favorite_border,
              color: const Color(0xFFFF9284),
            ),
          ),
        ],
      ),
      body: PageBody(
        children: [
          if (coverMediaId != null &&
              photos.any((p) => p['id'] == coverMediaId))
            DishPhoto(
              api: widget.api,
              path: photos.firstWhere((p) => p['id'] == coverMediaId)['url'],
              height: 260,
            )
          else
            DishPhoto(
              api: widget.api,
              path: photos.isEmpty ? null : photos.last['url'] as String,
              height: 260,
            ),
          const SizedBox(height: 24),
          Text(
            r.title,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(r.description, style: const TextStyle(color: muted)),
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: Tag(r.category)),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 20),
            label('做过的照片'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: photos
                  .map(
                    (p) => InkWell(
                      onTap: widget.offline ? null : () => selectCover(p['id']),
                      child: Stack(
                        children: [
                          DishPhoto(
                            api: widget.api,
                            path: p['url'],
                            width: 76,
                            height: 76,
                          ),
                          if (p['id'] == coverMediaId)
                            const Positioned(
                              right: 2,
                              top: 2,
                              child: Icon(
                                Icons.check_circle,
                                color: Colors.green,
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 28),
          label('准备食材'),
          CozyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: r.ingredients
                  .map(
                    (i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          const Icon(Icons.circle, size: 5, color: orange),
                          const SizedBox(width: 12),
                          Expanded(child: Text(i)),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 26),
          label('一起下厨'),
          ...r.steps.asMap().entries.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: const Color(0xFFFFE7C4),
                    child: Text(
                      '${s.key + 1}',
                      style: const TextStyle(color: ink, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(s.value)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            '今天就做这道菜',
            icon: Icons.restaurant,
            onPressed: widget.offline
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RecordPage(
                        api: widget.api,
                        initialTitle: r.title,
                        recipes: [r],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class NewRecipePage extends StatefulWidget {
  final Api api;
  final Recipe? recipe;
  const NewRecipePage({super.key, required this.api, this.recipe});
  @override
  State<NewRecipePage> createState() => _NewRecipePageState();
}

class _NewRecipePageState extends State<NewRecipePage> {
  final title = TextEditingController(),
      description = TextEditingController(),
      ingredients = TextEditingController(),
      steps = TextEditingController();
  String category = '家常菜';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    final r = widget.recipe;
    if (r != null) {
      title.text = r.title;
      description.text = r.description;
      ingredients.text = r.ingredients.join('\n');
      steps.text = r.steps.join('\n');
      category = r.category;
    }
  }

  @override
  void dispose() {
    for (final c in [title, description, ingredients, steps]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (title.text.trim().isEmpty ||
        ingredients.text.trim().isEmpty ||
        steps.text.trim().isEmpty) {
      toast(context, '请填写菜名、食材和做法');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await widget.api.request(
        widget.recipe == null ? 'POST' : 'PATCH',
        widget.recipe == null ? '/recipes' : '/recipes/${widget.recipe!.id}',
        {
          'title': title.text.trim(),
          'description': description.text.trim(),
          'category': category,
          'ingredients': ingredients.text
              .split('\n')
              .where((s) => s.trim().isNotEmpty)
              .toList(),
          'steps': steps.text
              .split('\n')
              .where((s) => s.trim().isNotEmpty)
              .toList(),
        },
      );
      if (mounted) {
        toast(context, widget.recipe == null ? '拿手菜已经收进菜谱 ♥' : '菜谱已更新');
        Navigator.pop(context, Recipe(result));
      }
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.recipe == null ? '我的拿手菜' : '编辑菜谱')),
    body: PageBody(
      children: [
        label('菜谱名称'),
        TextField(
          controller: title,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '给拿手菜起个名字'),
        ),
        const SizedBox(height: 16),
        label('一句话介绍'),
        TextField(
          controller: description,
          maxLength: 200,
          decoration: const InputDecoration(hintText: '这道菜的特别之处…'),
        ),
        const SizedBox(height: 16),
        label('分类'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: categories
              .skip(1)
              .map(
                (c) => Tag(
                  c,
                  selected: category == c,
                  onTap: () => setState(() => category = c),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 24),
        label('准备食材'),
        TextField(
          controller: ingredients,
          maxLines: 4,
          maxLength: 2000,
          decoration: const InputDecoration(hintText: '每行一种食材\n鸡蛋 3 个\n番茄 2 个'),
        ),
        const SizedBox(height: 16),
        label('做法步骤'),
        TextField(
          controller: steps,
          maxLines: 5,
          maxLength: 5000,
          decoration: const InputDecoration(hintText: '每行一个步骤\n洗净番茄，切块…'),
        ),
        const SizedBox(height: 24),
        PrimaryButton(busy ? '正在保存…' : '保存菜谱', onPressed: busy ? null : save),
      ],
    ),
  );
}

class CollectionPage extends StatelessWidget {
  final Api api;
  final List<Recipe> recipes;
  final List<Diary> entries;
  final bool offline;
  final String title;
  const CollectionPage({
    super.key,
    required this.api,
    required this.recipes,
    required this.entries,
    this.offline = false,
    this.title = '我的收藏',
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: PageBody(
      children: [
        if (recipes.isEmpty && entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Text('把喜欢的美味，慢慢收集起来吧 ♡', style: TextStyle(color: muted)),
            ),
          ),
        ...recipes.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CozyCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: DishPhoto(
                  api: api,
                  path: r.photos.isEmpty
                      ? null
                      : r.photos.last['url'] as String,
                  width: 56,
                  height: 56,
                ),
                title: Text(r.title),
                subtitle: Text(r.category),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        RecipePage(api: api, recipe: r, offline: offline),
                  ),
                ),
              ),
            ),
          ),
        ),
        ...entries.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CozyCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: DishPhoto(
                  api: api,
                  path: e.photos.isEmpty ? null : e.photos.first,
                  width: 56,
                  height: 56,
                ),
                title: Text(e.title),
                subtitle: Text(e.date),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DiaryPage(api: api, entry: e, offline: offline),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class SettingsPage extends StatefulWidget {
  final Api api;
  final Map<String, dynamic> profile;
  final VoidCallback onLogout;
  final bool offline;
  const SettingsPage({
    super.key,
    required this.api,
    required this.profile,
    required this.onLogout,
    this.offline = false,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController name, bio;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.profile['name']);
    bio = TextEditingController(text: widget.profile['bio']);
  }

  @override
  void dispose() {
    name.dispose();
    bio.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await widget.api.request('PATCH', '/profile', {
        'name': name.text.trim(),
        'bio': bio.text.trim(),
      });
      if (mounted) toast(context, '小厨房资料已更新');
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: PageBody(
      children: [
        label('我们的名字'),
        TextField(controller: name, maxLength: 30),
        const SizedBox(height: 16),
        label('一句话介绍'),
        TextField(controller: bio, maxLength: 100, maxLines: 2),
        const SizedBox(height: 22),
        PrimaryButton(
          busy ? '正在保存…' : '保存资料',
          onPressed: busy || widget.offline ? null : save,
        ),
        const SizedBox(height: 30),
        const CozyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('做饭日记 2.0', style: TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(
                '离线时可浏览已缓存的日记与菜谱。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: busy || widget.offline
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await widget.api.logout();
                    await widget.api.prefs.remove(
                      'snapshot:${widget.api.base}',
                    );
                    widget.onLogout();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) toast(context, e);
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: const Text('退出小厨房'),
        ),
      ],
    ),
  );
}
