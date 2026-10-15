import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'theme.dart';
import 'image_upload.dart';
import 'cropped_photo.dart';
import '../version.dart';

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
  if (!little && !(bytes[start] == 0x4d && bytes[start + 1] == 0x4d)) {
    return null;
  }
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
  final double? height;
  final Rect? crop;
  const DishPhoto({
    super.key,
    required this.api,
    this.path,
    this.width,
    this.height,
    this.crop,
  });
  @override
  Widget build(BuildContext context) {
    final photo = path == null ? placeholder() : _photo();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: width,
        child: height == null
            ? AspectRatio(aspectRatio: 16 / 9, child: photo)
            : SizedBox(height: height, child: photo),
      ),
    );
  }

  Widget _photo() {
    final ImageProvider provider;
    if (api.mock && path!.startsWith('asset:')) {
      provider = AssetImage(path!.substring(6));
    } else if (api.mock && path!.startsWith('data:')) {
      provider = MemoryImage(base64Decode(path!.split(',').last));
    } else {
      provider = NetworkImage(
        api.url(path!),
        headers: kIsWeb ? null : api.headers,
      );
    }
    final selection = crop;
    if (selection != null &&
        (selection.width < .99 || selection.height < .99)) {
      return CroppedPhoto(
        image: provider,
        crop: selection,
        placeholder: (_) => placeholder(),
      );
    }
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder(),
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : placeholder(),
    );
  }

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

Rect? cropFromMedia(dynamic media) {
  if (media is! Map) return null;
  final w = (media['crop_width'] as num?)?.toDouble() ?? 1;
  final h = (media['crop_height'] as num?)?.toDouble() ?? 1;
  if (w >= .99 && h >= .99) return null;
  return Rect.fromLTWH(
    (media['crop_x'] as num?)?.toDouble() ?? 0,
    (media['crop_y'] as num?)?.toDouble() ?? 0,
    w,
    h,
  );
}

class WelcomePage extends StatefulWidget {
  final Api api;
  final bool setup, loading;
  final String? error;
  final Future<void> Function() onAuthenticated;
  final VoidCallback? onConfigureServer;
  const WelcomePage({
    super.key,
    required this.api,
    required this.setup,
    required this.loading,
    required this.onAuthenticated,
    this.error,
    this.onConfigureServer,
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
                if (widget.onConfigureServer != null)
                  TextButton.icon(
                    onPressed: busy || widget.loading
                        ? null
                        : widget.onConfigureServer,
                    icon: const Icon(Icons.dns_outlined),
                    label: const Text('修改后端地址'),
                  ),
                const SizedBox(height: 24),
                const Text(
                  appVersion,
                  style: TextStyle(color: muted, fontSize: 11),
                ),
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
  late TextEditingController diaryNotes;
  final customTag = TextEditingController();
  late DateTime date;
  String category = '家常菜';
  int step = 0;
  int mood = 0;
  int rating = 0;
  final Set<String> tags = {};
  final List<XFile> files = [];
  final List<Rect> fileCrops = [];
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
    notes = TextEditingController(
      text: e?.dishes.isNotEmpty == true ? e!.dishes.first['notes'] ?? '' : '',
    );
    diaryNotes = TextEditingController(text: e?.notes ?? '');
    date = e == null ? DateTime.now() : DateTime.parse(e.date);
    step = e == null ? 0 : 1;
    category = categories.contains(e?.category) ? e!.category : category;
    mood = e?.mood ?? 0;
    rating = e?.rating ?? 0;
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
    diaryNotes.dispose();
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

  void _syncCurrentDish() {
    if (dishes.isEmpty) return;
    final index = photoDishIndex.clamp(0, dishes.length - 1);
    dishes[index].addAll({
      'notes': notes.text.trim(),
      'rating': rating,
      'tags': tags.toList(),
    });
  }

  Future<void> pick(ImageSource source) async {
    try {
      final room = 9 - (widget.entry?.photos.length ?? 0) - files.length;
      final selected = await ImageUpload.pick(
        context,
        source: source,
        max: room,
      );
      for (final picked in selected) {
        final f = picked.file;
        final data = picked.bytes;
        if (mounted) {
          setState(() {
            files.add(f);
            previews.add(data);
            fileCrops.add(picked.crop);
            fileDishIndices.add(photoDishIndex.clamp(0, dishes.length - 1));
          });
        }
      }
      if (selected.length >= room && mounted) toast(context, '最多可以保存 9 张照片');
      if (selected.isNotEmpty && mounted && step == 0) {
        setState(() => step = 1);
      }
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  Future<void> save() async {
    if (step != 2 && !(form.currentState?.validate() ?? false)) return;
    setState(() => saving = true);
    try {
      if (savedId == null) {
        _syncCurrentDish();
        final body = {
          ...?widget.entry?.toJson(),
          'title': dishes.first['title'],
          'dishes': dishes
              .map(
                (d) => {
                  'id': d['id'],
                  'title': d['title'],
                  'notes': d['notes'] ?? '',
                  'rating': d['rating'] ?? 0,
                  'tags': d['tags'] ?? <String>[],
                },
              )
              .toList(),
          'notes': diaryNotes.text.trim(),
          'cooked_on': date.toIso8601String().substring(0, 10),
          'category': category,
          'mood': mood,
          'rating': rating == 0 ? null : rating,
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
          crop: fileCrops[uploaded],
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

  Widget _photoStep() {
    final hasPhotos =
        previews.isNotEmpty || widget.entry?.photos.isNotEmpty == true;
    return CozyCard(
      child: Column(
        children: [
          if (!hasPhotos) ...[
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
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: saving || savedId != null
                    ? null
                    : () => pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('选择照片'),
              ),
              TextButton.icon(
                onPressed: saving || savedId != null
                    ? null
                    : () => pick(ImageSource.camera),
                label: const Text('拍照'),
              ),
            ],
          ),
          if (hasPhotos)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final path in widget.entry?.photos ?? <String>[])
                  DishPhoto(api: widget.api, path: path, width: 76, height: 76),
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
                                        fileCrops.removeAt(i);
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
                    ],
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _finalStep() => Form(
    key: const ValueKey('final-step'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CozyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '今天的心情与心得',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '给今天的厨房时光留下一句话。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
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
              TextFormField(
                controller: diaryNotes,
                maxLength: 200,
                maxLines: 4,
                decoration: const InputDecoration(hintText: '今天的做饭心得…'),
              ),
              const SizedBox(height: 10),
              const Text('今日心情', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(
                  5,
                  (i) => InkWell(
                    onTap: () => setState(() => mood = i),
                    borderRadius: BorderRadius.circular(16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: mood == i
                            ? const Color(0xFFFFEACB)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        moods[i],
                        style: const TextStyle(fontSize: 28),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          saving ? '正在保存…' : '保存今天的日记',
          icon: Icons.check_rounded,
          onPressed: saving ? null : save,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.entry == null ? '记录做饭' : '编辑日记')),
      body: PageBody(
        children: [
          if (step != 2) _photoStep(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
              axis: Axis.vertical,
              alignment: Alignment.topCenter,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: step == 0
                ? const SizedBox.shrink()
                : step == 2
                ? _finalStep()
                : Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                            (r) =>
                                                r.title.toLowerCase().contains(
                                                  v.text.trim().toLowerCase(),
                                                ),
                                          ),
                                    displayStringForOption: (r) => r.title,
                                    onSelected: (r) => setState(() {
                                      dishes[i].addAll({
                                        'id': r.id,
                                        'title': r.title,
                                      });
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
                                                              dishes.removeAt(
                                                                i,
                                                              );
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
                                                                  photoDishIndex ==
                                                                      i
                                                                  ? 0
                                                                  : photoDishIndex >
                                                                        i
                                                                  ? photoDishIndex -
                                                                        1
                                                                  : photoDishIndex;
                                                            });
                                                          }
                                                        : null,
                                                    icon: const Icon(
                                                      Icons.close,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                        ),
                                    optionsViewBuilder:
                                        (context, select, options) => Align(
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
                        label('这道菜的备注'),
                        TextFormField(
                          controller: notes,
                          readOnly: savedId != null,
                          maxLength: 200,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: '这道菜的制作备注…',
                          ),
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
                                        tags.contains(t)
                                            ? tags.remove(t)
                                            : tags.add(t);
                                      }),
                              ),
                            Tag(
                              '+',
                              onTap: savedId != null
                                  ? null
                                  : () => setState(
                                      () => showCustomTag = !showCustomTag,
                                    ),
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
                                onPressed: savedId != null
                                    ? null
                                    : addCustomTag,
                                child: const Text('添加'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 16),
                        label('这道菜评分'),
                        Row(
                          children: List.generate(
                            5,
                            (i) => IconButton(
                              tooltip: '${i + 1} 分',
                              onPressed: savedId != null
                                  ? null
                                  : () => setState(() => rating = i + 1),
                              icon: Icon(
                                i < rating
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: gold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 50,
                                child: OutlinedButton.icon(
                                  onPressed: saving || dishes.length >= 20
                                      ? null
                                      : () {
                                          if (!(form.currentState?.validate() ??
                                              false)) {
                                            return;
                                          }
                                          _syncCurrentDish();
                                          setState(() {
                                            dishes.add({'id': '', 'title': ''});
                                            notes.clear();
                                            rating = 0;
                                            tags.clear();
                                            showCustomTag = false;
                                            step = 1;
                                            photoDishIndex = dishes.length - 1;
                                          });
                                        },
                                  icon: const Icon(Icons.add),
                                  label: const Text('下一道菜'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PrimaryButton(
                                saving ? '正在保存…' : '完成',
                                icon: Icons.check_rounded,
                                onPressed: saving
                                    ? null
                                    : () {
                                        if (form.currentState?.validate() ??
                                            false) {
                                          _syncCurrentDish();
                                          setState(() => step = 2);
                                        }
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
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
          crop: entry.photoCrops.isEmpty ? null : entry.photoCrops[photo],
          width: double.infinity,
        ),
        const SizedBox(height: 22),
        Text(entry.date, style: const TextStyle(color: muted, fontSize: 12)),
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
                        crop: entry.photoCrops.length > i
                            ? entry.photoCrops[i]
                            : null,
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

  Future<void> uploadPhotos() async {
    setState(() => busy = true);
    var added = 0;
    try {
      final selected = await ImageUpload.pick(
        context,
        source: ImageSource.gallery,
      );
      for (final image in selected) {
        await widget.api.uploadRecipe(recipe.id, image.file, crop: image.crop);
        added++;
      }
      if (mounted && added > 0) toast(context, '照片已上传，可点击照片设置封面');
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (added > 0) {
        try {
          final all = await widget.api.request('GET', '/recipes') as List;
          final updated = Recipe(all.firstWhere((r) => r['id'] == recipe.id));
          if (mounted) {
            setState(() {
              recipe = updated;
              photos = List<dynamic>.from(updated.photos);
              coverMediaId = updated.coverMediaId;
            });
          }
        } catch (e) {
          if (mounted) toast(context, e);
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> removeRecipe() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这道菜谱？'),
        content: const Text('菜谱和它的归档关系会被永久删除，日记中的原照片会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '永久删除',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => busy = true);
    try {
      await widget.api.request('DELETE', '/recipes/${recipe.id}');
      if (mounted) {
        toast(context, '菜谱已永久删除');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
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
            tooltip: '删除菜谱',
            onPressed: widget.offline || busy || !recipe.custom
                ? null
                : removeRecipe,
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          ),
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
                      setState(() {
                        recipe = result;
                        photos = List<dynamic>.from(result.photos);
                        coverMediaId = result.coverMediaId;
                      });
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
              crop: cropFromMedia(
                photos.firstWhere((p) => p['id'] == coverMediaId),
              ),
            )
          else
            DishPhoto(
              api: widget.api,
              path: photos.isEmpty ? null : photos.last['url'] as String,
              crop: photos.isEmpty ? null : cropFromMedia(photos.last),
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
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: widget.offline || busy ? null : uploadPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(busy ? '正在处理…' : '上传菜谱图片'),
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 20),
            label('菜谱照片（点击设为封面）'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: photos
                  .map(
                    (p) => InkWell(
                      onTap: widget.offline || busy
                          ? null
                          : () => selectCover(p['id']),
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
  final List<XFile> files = [];
  final List<Uint8List> previews = [];
  final List<Rect> fileCrops = [];
  int uploaded = 0;
  String? savedId;

  Future<void> pickPhotos() async {
    try {
      final selected = await ImageUpload.pick(
        context,
        source: ImageSource.gallery,
        max: 9 - files.length,
      );
      for (final image in selected) {
        if (!mounted) return;
        setState(() {
          files.add(image.file);
          previews.add(image.bytes);
          fileCrops.add(image.crop);
        });
      }
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

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
        savedId == null && widget.recipe == null ? 'POST' : 'PATCH',
        savedId == null && widget.recipe == null
            ? '/recipes'
            : '/recipes/${savedId ?? widget.recipe!.id}',
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
      savedId = result['id'] as String;
      while (uploaded < files.length) {
        await widget.api.uploadRecipe(
          savedId!,
          files[uploaded],
          crop: fileCrops[uploaded],
        );
        uploaded++;
      }
      final all = await widget.api.request('GET', '/recipes') as List;
      final updated = all.firstWhere((r) => r['id'] == savedId);
      if (mounted) {
        toast(context, widget.recipe == null ? '拿手菜已经收进菜谱 ♥' : '菜谱已更新');
        Navigator.pop(context, Recipe(updated));
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
        label('菜谱图片'),
        if (widget.recipe != null && widget.recipe!.photos.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.recipe!.photos
                .map(
                  (p) => DishPhoto(
                    api: widget.api,
                    path: p['url'],
                    width: 76,
                    height: 76,
                  ),
                )
                .toList(),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: previews
              .asMap()
              .entries
              .map(
                (p) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        p.value,
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                      ),
                    ),
                    if (p.key >= uploaded)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton.filledTonal(
                          tooltip: '移除图片',
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  files.removeAt(p.key);
                                  previews.removeAt(p.key);
                                  fileCrops.removeAt(p.key);
                                }),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ),
                  ],
                ),
              )
              .toList(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy || files.length >= 9 ? null : pickPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('选择菜谱图片'),
          ),
        ),
        const Text(
          '支持 JPEG、PNG、WebP、GIF，单张不超过 20 MB',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 24),
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
