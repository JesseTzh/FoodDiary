import 'package:flutter/material.dart';

/// Renders a normalized selection from the original image before fitting it.
class CroppedPhoto extends StatefulWidget {
  final ImageProvider image;
  final Rect crop;
  final WidgetBuilder placeholder;

  const CroppedPhoto({
    super.key,
    required this.image,
    required this.crop,
    required this.placeholder,
  });

  @override
  State<CroppedPhoto> createState() => _CroppedPhotoState();
}

class _CroppedPhotoState extends State<CroppedPhoto> {
  ImageStream? _stream;
  ImageInfo? _info;
  late final _listener = ImageStreamListener(
    (info, _) {
      final previous = _info;
      setState(() => _info = info);
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    },
    onError: (Object error, StackTrace? stack) {
      final previous = _info;
      setState(() => _info = null);
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(CroppedPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _stream?.removeListener(_listener);
    _info?.dispose();
    _info = null;
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return widget.placeholder(context);
    return CustomPaint(painter: _CropPainter(info, widget.crop));
  }
}

class _CropPainter extends CustomPainter {
  final ImageInfo info;
  final Rect crop;
  _CropPainter(this.info, this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final image = info.image;
    final square = squarePhotoCrop(
      crop,
      Size(image.width.toDouble(), image.height.toDouble()),
    );
    final selection = Rect.fromLTWH(
      square.left * image.width,
      square.top * image.height,
      square.width * image.width,
      square.height * image.height,
    );
    final fitted = applyBoxFit(BoxFit.cover, selection.size, size);
    final source = Alignment.center.inscribe(fitted.source, selection);
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      info != oldDelegate.info || crop != oldDelegate.crop;
}

/// Keeps a square selection intact and expands legacy landscape crops using
/// pixels from the uploaded image, without changing the stored coordinates.
Rect squarePhotoCrop(Rect crop, Size image) {
  final pixelWidth = crop.width * image.width;
  final pixelHeight = crop.height * image.height;
  final side = (pixelWidth > pixelHeight ? pixelWidth : pixelHeight).clamp(
    1.0,
    image.shortestSide,
  );
  final width = side / image.width;
  final height = side / image.height;
  return Rect.fromLTWH(
    (crop.center.dx - width / 2).clamp(0.0, 1.0 - width),
    (crop.center.dy - height / 2).clamp(0.0, 1.0 - height),
    width,
    height,
  );
}
