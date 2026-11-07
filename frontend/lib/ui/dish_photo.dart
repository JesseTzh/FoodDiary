import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/api.dart';
import 'cropped_photo.dart';

class DishPhoto extends StatelessWidget {
  final Api api;
  final String? path;
  final double? width;
  final double? height;
  final Rect? crop;
  final double radius;
  const DishPhoto({
    super.key,
    required this.api,
    this.path,
    this.width,
    this.height,
    this.crop,
    this.radius = 18,
  });
  @override
  Widget build(BuildContext context) {
    final photo = path == null
        ? placeholder()
        : LayoutBuilder(
            builder: (context, constraints) {
              final logicalWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : 440.0;
              final logicalHeight = constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : logicalWidth;
              final pixels =
                  (logicalWidth > logicalHeight
                      ? logicalWidth
                      : logicalHeight) *
                  MediaQuery.devicePixelRatioOf(context);
              return _photo(pixels <= 384 ? 'thumbnail' : 'preview');
            },
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        child: height == null
            ? AspectRatio(aspectRatio: 1, child: photo)
            : SizedBox(height: height, child: photo),
      ),
    );
  }

  Widget _photo(String variant) {
    final provider = dishImageProvider(api, path!, variant: variant);
    final selection = crop;
    if (selection != null &&
        (selection.width < .99 || selection.height < .99)) {
      return CroppedPhoto(
        image: provider,
        crop: selection,
        placeholder: (_) => placeholder(),
      );
    }
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder(),
      frameBuilder: (_, child, frame, synchronous) =>
          synchronous || frame != null ? child : placeholder(),
    );
  }

  Widget placeholder() => Container(
    color: const Color(0xFFFFEFD9),
    child: const Center(
      child: Icon(
        Icons.ramen_dining_rounded,
        color: Color(0xFFDBAC76),
        size: 40,
      ),
    ),
  );
}

Rect? cropFromMedia(dynamic media) {
  if (media is! Map) return null;
  final w = (media['crop_width'] as num?)?.toDouble() ?? 1;
  final h = (media['crop_height'] as num?)?.toDouble() ?? 1;
  if (w >= .99 && h >= .99) return null;
  return Rect.fromLTWH(
    (media['crop_x'] as num?)?.toDouble() ?? 0,
    (media['crop_y'] as num?)?.toDouble() ?? 0,
    w,
    h,
  );
}

// Scope mock byte caches to the API instance and bound retained bytes. Repeated
// base64 decoding used to give MemoryImage a different cache key every build.
final _memoryImages = Expando<_MemoryImages>();

class _MemoryImages {
  final images = <String, MemoryImage>{};
  int bytes = 0;
  MemoryImage get(String path) {
    final cached = images.remove(path);
    if (cached != null) {
      images[path] = cached;
      return cached;
    }
    final image = MemoryImage(base64Decode(path.split(',').last));
    const limit = 24 * 1024 * 1024;
    if (image.bytes.lengthInBytes > limit) return image;
    while (images.isNotEmpty &&
        (bytes + image.bytes.lengthInBytes > limit || images.length >= 64)) {
      bytes -= images.remove(images.keys.first)!.bytes.lengthInBytes;
    }
    images[path] = image;
    bytes += image.bytes.lengthInBytes;
    return image;
  }
}

ImageProvider dishImageProvider(Api api, String path, {String? variant}) {
  final ImageProvider provider;
  if (api.mock && path.startsWith('asset:')) {
    provider = AssetImage(path.substring(6));
  } else if (api.mock && path.startsWith('data:')) {
    provider = (_memoryImages[api] ??= _MemoryImages()).get(path);
  } else {
    if (variant != null) {
      final uri = Uri.parse(path);
      if (RegExp(r'^/media/assets/[^/]+/original$').hasMatch(uri.path)) {
        path = uri
            .replace(
              path: uri.path.replaceFirst(RegExp(r'/original$'), '/$variant'),
            )
            .toString();
      }
    }
    provider = NetworkImage(
      api.url(path),
      headers: kIsWeb ? null : api.headers,
    );
  }
  return provider;
}
