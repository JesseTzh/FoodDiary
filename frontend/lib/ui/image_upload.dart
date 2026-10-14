import 'dart:typed_data';

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
      final crop = await showDialog<Rect>(
        context: context,
        builder: (_) => _CropDialog(bytes: bytes),
      );
      if (crop != null) result.add(SelectedImage(file, bytes, crop));
    }
    return result;
  }
}

class _CropDialog extends StatefulWidget {
  final Uint8List bytes;
  const _CropDialog({required this.bytes});
  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  // The cover is a 16:9 frame; coordinates stay normalized so the original
  // file remains untouched and the same selection works on every viewport.
  Rect crop = const Rect.fromLTWH(.05, .247, .9, .506);
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
    content: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxWidth * .68);
        return SizedBox(
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
                Image.memory(widget.bytes, fit: BoxFit.cover),
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
        );
      },
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
    canvas.drawColor(Colors.black54, BlendMode.srcOver);
    canvas.save();
    canvas.clipRect(hole);
    canvas.drawColor(Colors.transparent, BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.crop != crop;
}
