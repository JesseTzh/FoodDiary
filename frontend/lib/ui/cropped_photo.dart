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
    final selection = Rect.fromLTWH(
      crop.left * image.width,
      crop.top * image.height,
      crop.width * image.width,
      crop.height * image.height,
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
