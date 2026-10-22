import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/data/models.dart';
import 'package:fooddiary/ui/pages.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/exif_image.dart';

Future<void> pickPhotos(WidgetTester tester, int count) async {
  await tester.tap(find.text('选择照片'));
  for (var i = 0; i < count; i++) {
    // Native file reads and image decoding finish outside the fake test clock.
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('使用此范围').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('使用此范围'), findsOneWidget);
    await tester.tap(find.text('使用此范围'));
    await tester.pumpAndSettle();
  }
}

Future<void> finishDishes(WidgetTester tester) async {
  await tester.ensureVisible(find.text('完成'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('完成'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/image_picker');
  late Directory temp;
  late Api api;
  List<String> paths = [];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = Api(mock: true);
    await api.init();
    temp = Directory.systemTemp.createTempSync('fooddiary-photo-date-');
    paths = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickMultiImage');
          return paths;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    temp.deleteSync(recursive: true);
  });

  String photo(String name, {String? date}) {
    final file = File('${temp.path}/$name.jpg');
    file.writeAsBytesSync(exifImage(original: date));
    return file.path;
  }

  testWidgets('first EXIF date fills final step and manual edit is saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    paths = [
      photo('no-date'),
      photo('first-date', date: '2026:09:10 23:45:00'),
      photo('second-date', date: '2026:09:12 08:00:00'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(),
        initialRoute: '/record',
        routes: {
          '/record': (_) => RecordPage(api: api, initialTitle: 'EXIF 日期测试'),
        },
      ),
    );
    await tester.pumpAndSettle();
    await pickPhotos(tester, 3);
    await finishDishes(tester);
    expect(find.text('2026-09-10'), findsOneWidget);
    expect(find.text('已自动从照片中读取日期'), findsOneWidget);
    for (final description in moodDescriptions) {
      expect(find.text(description), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('2026-09-10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026-09-10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('11').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('2026-09-11'), findsOneWidget);
    expect(find.text('已自动从照片中读取日期'), findsNothing);

    await tester.ensureVisible(find.text('有点挫败'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('有点挫败'));
    await tester.ensureVisible(find.text('保存今天的日记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存今天的日记'));
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.byType(RecordPage).evaluate().isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(RecordPage), findsNothing);
    final result = await api.request('GET', '/entries');
    final entries = result['items'] as List;
    final entry = entries.singleWhere((e) => e['title'] == 'EXIF 日期测试');
    expect(entry['cooked_on'], '2026-09-11');
    expect(entry['mood'], 4);
    expect(tester.takeException(), isNull);
  });

  for (final sameDay in [false, true]) {
    testWidgets(
      'keeps date without notice when ${sameDay ? 'EXIF matches' : 'EXIF is missing'}',
      (tester) async {
        final today = DateTime.now().toIso8601String().substring(0, 10);
        paths = [
          photo(
            'photo',
            date: sameDay ? '${today.replaceAll('-', ':')} 08:00:00' : null,
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: RecordPage(api: api, initialTitle: '今天的菜'),
          ),
        );
        await tester.pumpAndSettle();
        await pickPhotos(tester, 1);
        await finishDishes(tester);
        expect(find.text(today), findsOneWidget);
        expect(find.text('已自动从照片中读取日期'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
