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
    final photo = path == null ? placeholder() : _photo();
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

  Widget _photo() {
    final provider = dishImageProvider(api, path!);
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

ImageProvider dishImageProvider(Api api, String path) {
  final ImageProvider provider;
  if (api.mock && path.startsWith('asset:')) {
    provider = AssetImage(path.substring(6));
  } else if (api.mock && path.startsWith('data:')) {
    provider = MemoryImage(base64Decode(path.split(',').last));
  } else {
    provider = NetworkImage(
      api.url(path),
      headers: kIsWeb ? null : api.headers,
    );
  }
  return provider;
}
