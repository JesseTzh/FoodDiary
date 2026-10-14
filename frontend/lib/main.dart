import 'dart:convert';

import 'package:flutter/material.dart';

import 'data/api.dart';
import 'data/models.dart';
import 'ui/theme.dart';
import 'ui/pages.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FoodDiaryApp());
}

class FoodDiaryApp extends StatefulWidget {
  const FoodDiaryApp({super.key});
  @override
  State<FoodDiaryApp> createState() => _FoodDiaryAppState();
}

class _FoodDiaryAppState extends State<FoodDiaryApp> {
  final api = Api();
  bool ready = false;
  @override
  void initState() {
    super.initState();
    api.init().then((_) {
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '做饭日记',
    debugShowCheckedModeBanner: false,
    theme: kitchenTheme(),
    home: ready ? Kitchen(api: api) : const _OpeningPage(),
  );
}

class _OpeningPage extends StatelessWidget {
  const _OpeningPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFFFFAF3),
    body: const Center(child: CircularProgressIndicator(color: gold)),
  );
}

class Kitchen extends StatefulWidget {
  final Api api;
  const Kitchen({super.key, required this.api});
  @override
  State<Kitchen> createState() => _KitchenState();
}

class _KitchenState extends State<Kitchen> {
  int tab = 0;
  bool loading = true, authenticated = false, setup = false, offline = false;
  String? error;
  List<Diary> entries = [];
  List<Recipe> recipes = [];
  Map<String, dynamic> profile = {};
  String search = '', category = '全部', month = '全部';
  Api get api => widget.api;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final auth = await api.request('GET', '/auth/status');
      if (!auth['authenticated']) {
        if (mounted) {
          setState(() {
            authenticated = false;
            setup = !auth['auth_required'];
            loading = false;
          });
        }
        return;
      }
      final result = await Future.wait([
        api.request('GET', '/entries'),
        api.request('GET', '/recipes'),
        api.request('GET', '/profile'),
      ]);
      await api.prefs.setString('snapshot:${api.base}', jsonEncode(result));
      if (mounted) {
        setState(() {
          entries = (result[0]['items'] as List).map((e) => Diary(e)).toList();
          recipes = (result[1] as List).map((e) => Recipe(e)).toList();
          profile = Map<String, dynamic>.from(result[2]);
          authenticated = true;
          offline = false;
          loading = false;
        });
      }
    } catch (e) {
      final cached = api.prefs.getString('snapshot:${api.base}');
      if (e is ApiError && e.status == 401) {
        if (mounted) {
          setState(() {
            authenticated = false;
            loading = false;
          });
        }
      } else if (cached != null) {
        final result = jsonDecode(cached);
        if (mounted) {
          setState(() {
            entries = (result[0]['items'] as List)
                .map((e) => Diary(e))
                .toList();
            recipes = (result[1] as List).map((e) => Recipe(e)).toList();
            profile = Map<String, dynamic>.from(result[2]);
            authenticated = true;
            offline = true;
            loading = false;
          });
        }
      } else if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  Future<void> open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) await refresh();
  }

  void record([Diary? entry]) {
    if (offline) {
      toast(context, '当前离线，联网后可以记录做饭');
      return;
    }
    open(RecordPage(api: api, entry: entry));
  }

  Future<void> favoriteRecipe(Recipe recipe) async {
    try {
      await api.request('PATCH', '/recipes/${recipe.id}/favorite', {
        'favorite': !recipe.favorite,
      });
      await refresh();
    } catch (e) {
      if (mounted) toast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!authenticated) {
      return WelcomePage(
        api: api,
        setup: setup,
        loading: loading,
        error: error,
        onAuthenticated: refresh,
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final content = Scaffold(
      backgroundColor: cream,
      body: SafeArea(
        child: Column(
          children: [
            if (offline)
              Material(
                color: const Color(0xFFFFECD0),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.cloud_off_outlined, size: 20),
                  title: const Text('离线浏览 · 显示上次保存的内容'),
                  trailing: TextButton(
                    onPressed: refresh,
                    child: const Text('重试'),
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: refresh,
                color: orange,
                child: [home(), diary(), cookbook(), mine()][tab],
              ),
            ),
            if (loading)
              const LinearProgressIndicator(minHeight: 2, color: gold),
          ],
        ),
      ),
      bottomNavigationBar: wide ? null : navigation(),
      floatingActionButton: tab == 1 && !offline
          ? FloatingActionButton(
              backgroundColor: gold,
              foregroundColor: ink,
              onPressed: record,
              child: const Icon(Icons.add),
            )
          : null,
    );
    if (!wide) return content;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 270,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: Image.asset(
                        'assets/images/mascot.png',
                        width: 165,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '做饭日记',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const SizedBox(height: 40),
                    for (var i = 0; i < 4; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          selected: tab == i,
                          selectedTileColor: const Color(0xFFFFEDD2),
                          selectedColor: orange,
                          leading: Icon(navIcons[i]),
                          title: Text(navLabels[i]),
                          onTap: () => setState(() {
                            tab = i;
                            search = '';
                          }),
                        ),
                      ),
                    const Spacer(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const navIcons = [
    Icons.home_rounded,
    Icons.edit_note_rounded,
    Icons.restaurant_menu_rounded,
    Icons.person_outline_rounded,
  ];
  static const navLabels = ['首页', '日记', '菜谱', '我的'];
  Widget navigation() => Container(
    decoration: const BoxDecoration(
      color: paper,
      border: Border(top: BorderSide(color: line)),
    ),
    child: SafeArea(
      top: false,
      // Mobile browsers may report no inset for the gesture area.
      minimum: const EdgeInsets.only(bottom: 34),
      maintainBottomViewPadding: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: List.generate(
            4,
            (i) => Expanded(
              child: InkWell(
                onTap: () => setState(() {
                  tab = i;
                  search = '';
                }),
                child: SizedBox(
                  height: 56,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        navIcons[i],
                        color: tab == i ? orange : muted,
                        size: 25,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        navLabels[i],
                        style: TextStyle(
                          fontSize: 11,
                          color: tab == i ? orange : muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Widget heading(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
  Widget home() {
    final today = DateTime.now();
    final date = '${today.month}月${today.day}日';
    final weekday = ['一', '二', '三', '四', '五', '六', '日'][today.weekday - 1];
    final todays = entries
        .where((e) => e.date == today.toIso8601String().substring(0, 10))
        .length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Row(
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '做饭日记',
                  style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 4),
                Text(
                  '今天也要好好吃饭呀～',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const Spacer(),
            InkWell(
              onTap: () => setState(() => tab = 3),
              child: ClipOval(
                child: Image.asset(
                  'assets/images/mascot.png',
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth <= 600) {
                return Image.asset(
                  'assets/images/hero.png',
                  width: c.maxWidth,
                  height: c.maxWidth * .39,
                  fit: BoxFit.cover,
                );
              }
              return Container(
                height: 220,
                color: const Color(0xFFFFEFD7),
                child: Row(
                  children: [
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '把日子过成\n喜欢的味道',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                height: 1.6,
                              ),
                            ),
                            SizedBox(height: 12),
                            Text(
                              '记录每一餐喜欢的味道。',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Image.asset(
                      'assets/images/hero.png',
                      width: c.maxWidth * .58,
                      height: 220,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 22),
        CozyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '$date   周$weekday',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.wb_sunny_outlined, color: gold, size: 24),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                todays > 0 ? '今天已经留下 $todays 份好吃的回忆' : '今天做了什么？留下美味的小日常吧。',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                '记录今天的做饭',
                icon: Icons.add,
                semanticIdentifier: 'home-record-action',
                onPressed: offline ? null : record,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            const Text(
              '今日菜谱',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => tab = 2),
              child: const Text(
                '更多 ›',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...recipes
            .take(2)
            .map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: recipeRow(r),
              ),
            ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text(
            '最近的美味回忆',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          entryCard(entries.first),
        ],
        const SizedBox(height: 24),
        const Center(
          child: Text(
            '把每次下厨都留下来。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget recipeRow(Recipe r) => InkWell(
    borderRadius: BorderRadius.circular(20),
    onTap: () => open(RecipePage(api: api, recipe: r, offline: offline)),
    child: CozyCard(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/images/${r.image}.png',
              width: 94,
              height: 94,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  r.description,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Text(
                  '♧ ${r.category}',
                  style: const TextStyle(
                    color: Color(0xFFD6A77A),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: offline ? null : () => favoriteRecipe(r),
            icon: Icon(
              r.favorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: orange,
              size: 21,
            ),
          ),
        ],
      ),
    ),
  );
  Widget diary() {
    final months = entries.map((e) => e.date.substring(0, 7)).toSet().toList();
    final filtered = entries
        .where(
          (e) =>
              (month == '全部' || e.date.startsWith(month)) &&
              (e.title.contains(search) ||
                  e.notes.contains(search) ||
                  e.tags.any((t) => t.contains(search))),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
      children: [
        heading(
          '日记',
          trailing: const Icon(Icons.auto_stories_outlined, color: muted),
        ),
        TextField(
          onChanged: (v) => setState(() => search = v),
          decoration: const InputDecoration(
            hintText: '寻找某一道菜，或一段回忆…',
            prefixIcon: Icon(Icons.search, size: 21),
          ),
        ),
        const SizedBox(height: 18),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['全部', ...months]
                .map(
                  (m) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tag(
                      m == '全部'
                          ? m
                          : '${int.parse(m.substring(5))}月 · ${m.substring(0, 4)}',
                      selected: month == m,
                      onTap: () => setState(() => month = m),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 22),
        if (filtered.isEmpty)
          empty('还没有这段美味回忆', '从今天的第一顿饭开始吧。', action: '记录做饭', onTap: record),
        ...filtered.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: entryCard(e),
          ),
        ),
      ],
    );
  }

  Widget entryCard(Diary e) => TestId(
    'diary-entry',
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => open(DiaryPage(api: api, entry: e, offline: offline)),
      child: CozyCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DishPhoto(
              api: api,
              path: e.photos.isEmpty ? null : e.photos.first,
              width: 100,
              height: 112,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${int.parse(e.date.substring(5, 7))}月${int.parse(e.date.substring(8))}日    ${e.meal}',
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.notes.isEmpty ? '今天也认真做饭了～' : e.notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        moods[e.mood.clamp(0, 4)],
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '美味日常',
                        style: TextStyle(
                          color: Color(0xFFD6A77A),
                          fontSize: 10,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        e.favorite ? Icons.favorite : Icons.favorite_border,
                        color: const Color(0xFFFF9184),
                        size: 16,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget cookbook() {
    final filtered = recipes
        .where(
          (r) =>
              (category == '全部' || r.category == category) &&
              r.title.contains(search),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        heading(
          '菜谱',
          trailing: IconButton(
            tooltip: '创建菜谱',
            onPressed: offline ? null : () => open(NewRecipePage(api: api)),
            icon: const Icon(Icons.add_circle_outline, color: orange),
          ),
        ),
        TextField(
          onChanged: (v) => setState(() => search = v),
          decoration: const InputDecoration(
            hintText: '搜索菜谱…',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: categories
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tag(
                      c,
                      selected: c == category,
                      onTap: () => setState(() => category = c),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 22),
        if (filtered.isEmpty) empty('这里还没有菜谱', '试试其他分类，或添加你的拿手菜。'),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 650 ? 3 : 2;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                crossAxisSpacing: 14,
                mainAxisSpacing: 16,
                mainAxisExtent: c.maxWidth / cols * .7 + 83,
              ),
              itemBuilder: (context, i) {
                final r = filtered[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () =>
                      open(RecipePage(api: api, recipe: r, offline: offline)),
                  child: CozyCard(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.asset(
                              'assets/images/${r.image}.png',
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                          child: Text(
                            r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                r.category,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: muted,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 36,
                              child: IconButton(
                                onPressed: offline
                                    ? null
                                    : () => favoriteRecipe(r),
                                icon: Icon(
                                  r.favorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: const Color(0xFFFF9581),
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget mine() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 36, 24, 32),
    children: [
      Row(
        children: [
          ClipOval(
            child: Image.asset(
              'assets/images/mascot.png',
              width: 76,
              height: 76,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile['name'] ?? '小虎和小鼠',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  profile['bio'] ?? '',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 32),
      Row(
        children: [
          stat(
            '${profile['entry_count'] ?? 0}',
            '记录天数',
            entries.map((e) => e.date).toSet().length.toString(),
          ),
          stat('${profile['recipe_count'] ?? 0}', '创建菜品'),
          stat('${profile['favorite_count'] ?? 0}', '收藏菜谱'),
        ],
      ),
      const SizedBox(height: 30),
      CozyCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            menu(
              Icons.favorite_border,
              '我的收藏',
              () => open(
                CollectionPage(
                  api: api,
                  recipes: recipes.where((r) => r.favorite).toList(),
                  entries: entries.where((e) => e.favorite).toList(),
                  offline: offline,
                ),
              ),
            ),
            menu(
              Icons.menu_book_outlined,
              '我的菜谱',
              () => open(
                CollectionPage(
                  api: api,
                  recipes: recipes.where((r) => r.custom).toList(),
                  entries: const [],
                  offline: offline,
                  title: '我的菜谱',
                ),
              ),
            ),
            menu(
              Icons.shopping_bag_outlined,
              '食材清单',
              () => open(GroceriesPage(api: api, offline: offline)),
            ),
            menu(
              Icons.settings_outlined,
              '设置',
              () => open(
                SettingsPage(
                  api: api,
                  profile: profile,
                  onLogout: () {
                    setState(() => authenticated = false);
                  },
                  offline: offline,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 30),
      CozyCard(
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '把喜欢的味道记下来',
                  style: TextStyle(
                    fontSize: 15,
                    height: 2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(22),
              ),
              child: Image.asset(
                'assets/images/together.png',
                height: 220,
                width: 125,
                fit: BoxFit.cover,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget stat(String value, String label, [String? override]) => Expanded(
    child: Column(
      children: [
        Text(
          override ?? value,
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: muted)),
      ],
    ),
  );
  Widget menu(IconData icon, String title, VoidCallback tap) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    leading: Icon(icon, color: ink, size: 23),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    trailing: const Icon(Icons.chevron_right, color: muted, size: 20),
    onTap: tap,
  );
}

Widget empty(
  String title,
  String subtitle, {
  String? action,
  VoidCallback? onTap,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 36),
  child: Column(
    children: [
      const Icon(Icons.ramen_dining, size: 48, color: gold),
      const SizedBox(height: 16),
      Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        textAlign: TextAlign.center,
        style: const TextStyle(color: muted, fontSize: 12),
      ),
      if (action != null) ...[
        const SizedBox(height: 16),
        TextButton(onPressed: onTap, child: Text(action)),
      ],
    ],
  ),
);
