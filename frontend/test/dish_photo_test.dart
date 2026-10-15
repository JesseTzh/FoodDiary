import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/ui/cropped_photo.dart';
import 'package:fooddiary/ui/pages.dart';
import 'package:fooddiary/ui/theme.dart';

void main() {
  for (final width in [320.0, 390.0, 768.0, 1440.0]) {
    testWidgets('cover adapts to page width $width with 16:9 ratio', (
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
      expect(cover.width / cover.height, closeTo(16 / 9, .001));
      expect(
        tester.getRect(find.text('正文')).top,
        closeTo(cover.bottom + 24, .001),
      );
      expect(tester.getSize(find.byType(DishPhoto).last), const Size(76, 76));
      expect(tester.takeException(), isNull);
    });
  }

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
            crop: const Rect.fromLTWH(.5, 0, .5, 1),
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
