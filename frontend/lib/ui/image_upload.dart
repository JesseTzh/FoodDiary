import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// An image and a normalized rectangle describing the part used as its cover.
class SelectedImage {
  final XFile file;
  final Uint8List bytes;
  final Rect crop;
  const SelectedImage(this.file, this.bytes, this.crop);
}

/// Shared image picker used by diary and recipe editors.
class ImageUpload {
  static Future<List<SelectedImage>> pick(
    BuildContext context, {
    required ImageSource source,
    bool multiple = true,
    int max = 9,
  }) async {
    final picker = ImagePicker();
    final files = source == ImageSource.camera
        ? [
            await picker.pickImage(
              source: source,
              maxWidth: 1600,
              imageQuality: 85,
            ),
          ]
        : (multiple
              ? await picker.pickMultiImage(maxWidth: 1600, imageQuality: 85)
              : [
                  await picker.pickImage(
                    source: source,
                    maxWidth: 1600,
                    imageQuality: 85,
                  ),
                ]);
    final result = <SelectedImage>[];
    for (final file in files.whereType<XFile>().take(max)) {
      final bytes = await file.readAsBytes();
      if (!context.mounted) break;
      if (bytes.length > 20 * 1024 * 1024) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('单张照片不能超过 20 MB')));
        continue;
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final imageSize = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
      if (!context.mounted) break;
      final crop = await showDialog<Rect>(
        context: context,
        builder: (_) => ImageCropDialog(bytes: bytes, imageSize: imageSize),
      );
      if (crop != null) result.add(SelectedImage(file, bytes, crop));
    }
    return result;
  }
}

class ImageCropDialog extends StatefulWidget {
  final Uint8List bytes;
  final Size imageSize;
  const ImageCropDialog({
    super.key,
    required this.bytes,
    required this.imageSize,
  });
  @override
  State<ImageCropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<ImageCropDialog> {
  // The cover is a 16:9 frame; coordinates stay normalized so the original
  // file remains untouched and the same selection works on every viewport.
  late Rect crop;

  @override
  void initState() {
    super.initState();
    final aspect = widget.imageSize.aspectRatio;
    const coverAspect = 16 / 9;
    final width = aspect > coverAspect ? .9 * coverAspect / aspect : .9;
    final height = aspect > coverAspect ? .9 : .9 * aspect / coverAspect;
    crop = Rect.fromLTWH((1 - width) / 2, (1 - height) / 2, width, height);
  }

  Offset? down;
  Rect? start;

  void move(DragUpdateDetails details, Size size) {
    if (down == null || start == null) return;
    final dx = (details.localPosition.dx - down!.dx) / size.width;
    final dy = (details.localPosition.dy - down!.dy) / size.height;
    final left = (start!.left + dx).clamp(0.0, 1.0 - start!.width);
    final top = (start!.top + dy).clamp(0.0, 1.0 - start!.height);
    setState(
      () => crop = Rect.fromLTWH(left, top, start!.width, start!.height),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整头图范围'),
    content: SizedBox(
      width: 320,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = applyBoxFit(
            BoxFit.contain,
            widget.imageSize,
            Size(constraints.maxWidth, MediaQuery.sizeOf(context).height * .45),
          ).destination;
          return Center(
            heightFactor: 1,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: GestureDetector(
                onPanStart: (d) {
                  down = d.localPosition;
                  start = crop;
                },
                onPanUpdate: (d) => move(d, size),
                onPanEnd: (_) {
                  down = null;
                  start = null;
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(widget.bytes, fit: BoxFit.contain),
                    CustomPaint(painter: _CropPainter(crop)),
                    Positioned.fromRect(
                      rect: Rect.fromLTWH(
                        crop.left * size.width,
                        crop.top * size.height,
                        crop.width * size.width,
                        crop.height * size.height,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, crop),
        child: const Text('使用此范围'),
      ),
    ],
  );
}

class _CropPainter extends CustomPainter {
  final Rect crop;
  const _CropPainter(this.crop);
  @override
  void paint(Canvas canvas, Size size) {
    final hole = Rect.fromLTWH(
      crop.left * size.width,
      crop.top * size.height,
      crop.width * size.width,
      crop.height * size.height,
    );
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(hole);
    canvas.drawPath(outside, Paint()..color = Colors.black54);
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.crop != crop;
}
