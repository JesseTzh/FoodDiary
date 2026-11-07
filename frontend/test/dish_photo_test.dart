import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/ui/cropped_photo.dart';
import 'package:fooddiary/ui/dish_photo.dart';
import 'package:fooddiary/ui/theme.dart';

void main() {
  test('photo tiers fit physical pixels without jumping from 384 to 1024', () {
    expect(photoVariantFor(112 * 3), 'thumbnail');
    expect(photoVariantFor(160 * 3), 'medium');
    expect(photoVariantFor(384), 'thumbnail');
    expect(photoVariantFor(640), 'medium');
    expect(photoVariantFor(440 * 3), 'preview');
    expect(
      photoVariantFor(160 * 3, crop: const Rect.fromLTWH(.2, .2, .5, .5)),
      'preview',
    );
  });
  testWidgets('scrolling a cropped photo away and back reuses decoded image', (
    tester,
  ) async {
    final api = Api(mock: true);
    final bytes = File('test/fixtures/photo.jpg').readAsBytesSync();
    final path = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    final provider = dishImageProvider(api, path);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 100,
            itemExtent: 140,
            itemBuilder: (_, index) => index == 0
                ? DishPhoto(
                    api: api,
                    path: path,
                    crop: const Rect.fromLTWH(.1, .1, .5, .5),
                    width: 112,
                    height: 112,
                  )
                : const SizedBox(height: 140),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(provider, tester.element(find.byType(DishPhoto))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CroppedPhoto), findsOneWidget);
    controller.jumpTo(3000);
    await tester.pumpAndSettle();
    expect(find.byType(CroppedPhoto), findsNothing);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
      true,
    );
    controller.jumpTo(0);
    await tester.pump();
    expect(dishImageProvider(api, path), same(provider));
    expect(
      find.descendant(
        of: find.byType(CroppedPhoto),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).pending,
      false,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('mock image providers reuse cache keys across list rebuilds', () {
    final api = Api(mock: true);
    const path = 'data:image/png;base64,AQID';
    final first = dishImageProvider(api, path);
    expect(dishImageProvider(api, path), same(first));
  });

  test(
    'list providers select stable derivatives and gallery keeps original',
    () {
      final api = Api()..base = 'https://food.example.com';
      const path = '/media/assets/photo/original';
      final first =
          dishImageProvider(api, path, variant: 'thumbnail') as NetworkImage;
      expect(
        first.url,
        'https://food.example.com/media/assets/photo/thumbnail',
      );
      expect(dishImageProvider(api, path, variant: 'thumbnail'), first);
      expect(
        (dishImageProvider(api, path, variant: 'preview') as NetworkImage).url,
        endsWith('/preview'),
      );
      expect(
        (dishImageProvider(api, path, variant: 'medium') as NetworkImage).url,
        endsWith('/medium'),
      );
      expect(
        (dishImageProvider(api, path) as NetworkImage).url,
        endsWith('/original'),
      );
    },
  );

  for (final width in [320.0, 390.0, 768.0, 1440.0]) {
    testWidgets('cover adapts to page width $width with 1:1 ratio', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageBody(
              children: [
                DishPhoto(api: Api(mock: true)),
                const SizedBox(height: 24),
                const Text('正文'),
                Align(
                  child: DishPhoto(api: Api(mock: true), width: 76, height: 76),
                ),
              ],
            ),
          ),
        ),
      );
      final cover = tester.getRect(find.byType(DishPhoto).first);
      expect(cover.width / cover.height, closeTo(1, .001));
      expect(
        tester.getRect(find.text('正文')).top,
        closeTo(cover.bottom + 24, .001),
      );
      expect(tester.getSize(find.byType(DishPhoto).last), const Size(76, 76));
      expect(tester.takeException(), isNull);
    });
  }

  test('legacy crop expands around its center using the uploaded image', () {
    final crop = squarePhotoCrop(
      const Rect.fromLTWH(.1, .2, .8, .3),
      const Size(1000, 1200),
    );
    expect(crop.width * 1000, closeTo(800, .001));
    expect(crop.height * 1200, closeTo(800, .001));
    expect(crop.center.dx, closeTo(.5, .001));
    expect(crop.center.dy, closeTo(.35, .001));
    expect(crop.top, greaterThanOrEqualTo(0));
    expect(crop.bottom, lessThanOrEqualTo(1));
  });

  test('legacy crop remains inside the original image near an edge', () {
    final crop = squarePhotoCrop(
      const Rect.fromLTWH(.3, .8, .7, .2),
      const Size(1200, 800),
    );
    expect(crop.width * 1200 / (crop.height * 800), closeTo(1, .001));
    expect(crop.right, lessThanOrEqualTo(1));
    expect(crop.bottom, closeTo(1, .001));
  });

  testWidgets('cover renders the selected region of the original image', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.red, BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(50, 0, 50, 100),
      Paint()..color = Colors.green,
    );
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(100, 100));
    final bytes = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    image!.dispose();
    picture.dispose();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DishPhoto(
            api: Api(mock: true),
            path:
                'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}',
            crop: const Rect.fromLTWH(.5, 0, .5, .5),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        MemoryImage(bytes.buffer.asUint8List()),
        tester.element(find.byType(DishPhoto)),
      );
    });
    await tester.pumpAndSettle();
    final paint = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(CroppedPhoto),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    final outputRecorder = ui.PictureRecorder();
    paint.paint(Canvas(outputRecorder), const Size(160, 90));
    final outputPicture = outputRecorder.endRecording();
    final raster = await tester.runAsync(() => outputPicture.toImage(160, 90));
    final pixels = await tester.runAsync(
      () => raster!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    for (final x in [10, 80, 150]) {
      final offset = (45 * 160 + x) * 4;
      expect(pixels!.buffer.asUint8List().sublist(offset, offset + 4), [
        76,
        175,
        80,
        255,
      ]);
    }
    raster!.dispose();
    outputPicture.dispose();
    expect(tester.takeException(), isNull);
  });
}
