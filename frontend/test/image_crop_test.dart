import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/ui/image_upload.dart';

void main() {
  for (final size in [const Size(1200, 800), const Size(800, 1200)]) {
    testWidgets('crop stays 16:9 and inside a $size image after dragging', (
      tester,
    ) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.green, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(2, 2));
      final bytes = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      image!.dispose();
      picture.dispose();
      Rect? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  selected = await showDialog<Rect>(
                    context: context,
                    builder: (_) => ImageCropDialog(
                      bytes: bytes!.buffer.asUint8List(),
                      imageSize: size,
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final frame = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).border != null,
      );
      final rect = tester.getRect(frame);
      expect(rect.width / rect.height, closeTo(16 / 9, .001));
      final preview = find.byType(Image);
      expect(
        tester.getSize(preview).aspectRatio,
        closeTo(size.aspectRatio, .001),
      );

      // Paint over an existing image: the selection must preserve its pixels.
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere(
            (w) =>
                w.painter != null &&
                w.painter.runtimeType.toString() == '_CropPainter',
          )
          .painter!;
      final overlayRecorder = ui.PictureRecorder();
      final canvas = Canvas(overlayRecorder);
      canvas.drawColor(Colors.green, BlendMode.src);
      paint.paint(canvas, const Size(100, 100));
      final overlayPicture = overlayRecorder.endRecording();
      final raster = await tester.runAsync(
        () => overlayPicture.toImage(100, 100),
      );
      final pixels = await tester.runAsync(
        () => raster!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final rgba = Uint8List.view(pixels!.buffer);
      expect(rgba.sublist((50 * 100 + 50) * 4, (50 * 100 + 50) * 4 + 4), [
        76,
        175,
        80,
        255,
      ]);
      expect(rgba[1], lessThan(175));
      raster!.dispose();
      overlayPicture.dispose();

      await tester.drag(frame, const Offset(1000, 1000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用此范围'));
      await tester.pumpAndSettle();
      expect(selected, isNotNull);
      expect(
        selected!.width * size.width / (selected!.height * size.height),
        closeTo(16 / 9, .001),
      );
      expect(selected!.left, greaterThanOrEqualTo(0));
      expect(selected!.top, greaterThanOrEqualTo(0));
      expect(selected!.right, lessThanOrEqualTo(1));
      expect(selected!.bottom, closeTo(1, .001));
      expect(selected!.right, closeTo(1, .001));
      expect(tester.takeException(), isNull);
    });
  }
}
