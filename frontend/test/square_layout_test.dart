import 'dart:convert';

import 'package:fooddiary/data/mock_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/main.dart';
import 'package:fooddiary/ui/pages.dart';
import 'package:fooddiary/ui/photo_gallery.dart';
import 'package:fooddiary/ui/theme.dart';

void main() {
  for (final width in [320.0, 390.0, 768.0, 1440.0]) {
    testWidgets('list and detail covers stay square at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        MockStore.storageKey: jsonEncode({
          'seed_version': 2,
          'next_id': 100,
          'authenticated': true,
          'profile': {'name': '厨师', 'bio': ''},
          'entries': [
            {
              'id': 'entry-square',
              'title': '今天做了一顿很丰盛的晚饭和家人一起分享',
              'cooked_on': '2026-10-23',
              'notes': '番茄炒蛋配米饭，简单又好吃。',
              'mood': 0,
              'tags': ['家常菜'],
              'version': 1,
              'media': [
                {
                  'id': 'photo-square',
                  'url': 'asset:assets/images/tomato-scrambled-eggs.png',
                  'crop_x': .1,
                  'crop_y': .1,
                  'crop_width': .8,
                  'crop_height': .8,
                },
              ],
            },
          ],
          'recipes': [
            {
              'id': 'recipe-square',
              'title': '家常番茄炒蛋配一碗香喷喷的大米饭',
              'category': '家常菜',
              'description': '酸甜开胃，简单好做。',
              'image': '',
              'ingredients': ['番茄', '鸡蛋'],
              'steps': ['炒熟'],
              'favorite': false,
              'custom': true,
              'cover_media_id': 'photo-square',
              'photos': [
                {
                  'id': 'photo-square',
                  'url': 'asset:assets/images/tomato-scrambled-eggs.png',
                  'crop_x': .1,
                  'crop_y': .1,
                  'crop_width': .8,
                  'crop_height': .8,
                },
                {
                  'id': 'photo-second',
                  'url': 'asset:assets/images/hero-sharing-meal.png',
                },
              ],
            },
          ],
        }),
      });
      final api = Api(mock: true);
      await api.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: kitchenTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Kitchen(api: api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('日记').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final entry = find
          .byWidgetPredicate((w) => w is TestId && w.value == 'diary-entry')
          .first;
      final entryPhoto = find
          .descendant(of: entry, matching: find.byType(DishPhoto))
          .first;
      expect(tester.getSize(entryPhoto).aspectRatio, closeTo(1, .001));
      await tester.ensureVisible(entry);
      await tester.tap(entryPhoto);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('菜谱').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final element in find.byType(DishPhoto).evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).aspectRatio,
          closeTo(1, .001),
        );
      }
      await tester.tap(find.byType(DishPhoto).first);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('管理照片'));
      await tester.pumpAndSettle();
      expect(find.text('点击照片设为封面'), findsOneWidget);
      expect(find.text('上传菜谱图片'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('设为封面').last);
      await tester.pumpAndSettle();
      final recipes = await api.request('GET', '/recipes') as List;
      expect(recipes.first['cover_media_id'], 'photo-second');
      Navigator.of(tester.element(find.text('菜谱照片'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
