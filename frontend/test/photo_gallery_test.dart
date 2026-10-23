import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/ui/dish_photo.dart';
import 'package:fooddiary/ui/photo_gallery.dart';

void main() {
  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets('gallery caps square cover and switches photos at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                PhotoGallery(
                  api: Api(mock: true),
                  paths: const [
                    'asset:assets/images/tomato-scrambled-eggs.png',
                    'asset:assets/images/hero-sharing-meal.png',
                  ],
                  crops: const [Rect.fromLTWH(.2, .2, .6, .6), null],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cover = find.byType(PageView).first;
      final size = tester.getSize(cover);
      expect(size.width, lessThanOrEqualTo(440));
      expect(size.aspectRatio, closeTo(1, .001));
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.drag(cover, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('第 1 张照片'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(cover);
      await tester.pumpAndSettle();
      final fullImage = tester.widget<Image>(find.byType(Image).last);
      expect(fullImage.fit, BoxFit.contain);
      expect(find.byType(InteractiveViewer), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DishPhoto), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty gallery has a stable square placeholder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoGallery(
            api: Api(mock: true),
            paths: const [],
            crops: const [],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(DishPhoto)).aspectRatio,
      closeTo(1, .001),
    );
    expect(tester.takeException(), isNull);
  });
}
