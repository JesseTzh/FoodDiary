import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'theme.dart';

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
                  child: Image.asset('assets/images/logo.png', width: 180),
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
                  Text(
                    widget.setup ? '给我们的小厨房设一个密码' : '欢迎回到我们的小厨房',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 18),
                  TextField(
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
                  const SizedBox(height: 14),
                  PrimaryButton(
                    busy
                        ? '正在打开厨房…'
                        : widget.setup
                        ? '开启做饭日记'
                        : '进入小厨房',
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
  const RecordPage({
    super.key,
    required this.api,
    this.entry,
    this.initialTitle,
  });
  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  final form = GlobalKey<FormState>();
  late TextEditingController title, notes;
  late DateTime date;
  String meal = '晚餐', category = '家常菜';
  int mood = 0;
  final Set<String> tags = {};
  final List<XFile> files = [];
  final List<Uint8List> previews = [];
  bool saving = false;
  String? savedId;
  int uploaded = 0;
  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    title = TextEditingController(text: e?.title ?? widget.initialTitle ?? '');
    notes = TextEditingController(text: e?.notes ?? '');
    date = e == null ? DateTime.now() : DateTime.parse(e.date);
    meal = e?.meal ?? meal;
    category = categories.contains(e?.category) ? e!.category : category;
    mood = e?.mood ?? 0;
    tags.addAll(e?.tags ?? []);
  }

  @override
  void dispose() {
    title.dispose();
    notes.dispose();
    super.dispose();
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
          });
        }
      }
      if (selected.length > room && mounted) toast(context, '最多可以保存 9 张照片');
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      if (savedId == null) {
        final body = {
          ...?widget.entry?.toJson(),
          'title': title.text.trim(),
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
      }
      while (uploaded < files.length) {
        await widget.api.upload(savedId!, files[uploaded]);
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
                ),
                const SizedBox(height: 26),
                label('菜品名称'),
                TextFormField(
                  controller: title,
                  readOnly: savedId != null,
                  maxLength: 80,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '写下今天做的菜吧' : null,
                  decoration: const InputDecoration(hintText: '例如：番茄炒蛋 + 清炒时蔬'),
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
                  children: diaryTags
                      .map(
                        (t) => Tag(
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
                      )
                      .toList(),
                ),
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
  late bool favorite;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    favorite = widget.recipe.favorite;
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

  @override
  Widget build(BuildContext context) {
    final r = widget.recipe;
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日菜谱'),
        actions: [
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
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset(
              'assets/images/${r.image}.png',
              height: 260,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
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
                      builder: (_) =>
                          RecordPage(api: widget.api, initialTitle: r.title),
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
  const NewRecipePage({super.key, required this.api});
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
      await widget.api.request('POST', '/recipes', {
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
      });
      if (mounted) {
        toast(context, '拿手菜已经收进菜谱 ♥');
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
    appBar: AppBar(title: const Text('我的拿手菜')),
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
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/${r.image}.png',
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
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

class GroceriesPage extends StatefulWidget {
  final Api api;
  final bool offline;
  const GroceriesPage({super.key, required this.api, this.offline = false});
  @override
  State<GroceriesPage> createState() => _GroceriesPageState();
}

class _GroceriesPageState extends State<GroceriesPage> {
  final name = TextEditingController();
  List<dynamic> items = [];
  bool loading = true, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final list = await widget.api.request('GET', '/groceries');
      if (mounted) {
        setState(() {
          items = list;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> mutate(String method, String path, [Object? body]) async {
    setState(() => busy = true);
    try {
      await widget.api.request(method, path, body);
      if (method == 'POST') name.clear();
      await load();
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('食材清单')),
    body: PageBody(
      children: [
        const Text(
          '把想吃的写下来，下次买菜就不会忘啦。',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(hintText: '例如：鸡蛋一盒'),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              onPressed: busy || widget.offline
                  ? null
                  : () {
                      if (name.text.trim().isNotEmpty) {
                        mutate('POST', '/groceries', {
                          'name': name.text.trim(),
                        });
                      }
                    },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (error != null) ...[
          Text(error!, style: const TextStyle(color: muted)),
          TextButton(onPressed: load, child: const Text('重试')),
        ],
        if (!loading && error == null && items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(
              child: Text('清单空空的，添一点新鲜吧。', style: TextStyle(color: muted)),
            ),
          ),
        ...items.map(
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: CozyCard(
              padding: EdgeInsets.zero,
              child: CheckboxListTile(
                value: i['checked'],
                onChanged: busy || widget.offline
                    ? null
                    : (v) => mutate('PATCH', '/groceries/${i['id']}', {
                        'checked': v,
                      }),
                title: Text(
                  i['name'],
                  style: TextStyle(
                    decoration: i['checked']
                        ? TextDecoration.lineThrough
                        : null,
                    color: i['checked'] ? muted : ink,
                  ),
                ),
                secondary: IconButton(
                  tooltip: '删除食材',
                  onPressed: busy || widget.offline
                      ? null
                      : () => mutate('DELETE', '/groceries/${i['id']}'),
                  icon: const Icon(Icons.close, size: 18, color: muted),
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
