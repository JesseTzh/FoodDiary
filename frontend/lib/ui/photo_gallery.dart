import 'package:flutter/material.dart';

import '../data/api.dart';
import 'dish_photo.dart';
import 'theme.dart';

/// Square covers share the exact same crop as list cards and editor previews.
class PhotoGallery extends StatefulWidget {
  final Api api;
  final List<String> paths;
  final List<Rect?> crops;
  final int initialIndex;
  const PhotoGallery({
    super.key,
    required this.api,
    required this.paths,
    required this.crops,
    this.initialIndex = 0,
  });

  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  late final PageController controller;
  late int index;

  @override
  void initState() {
    super.initState();
    index = widget.paths.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.paths.length - 1);
    controller = PageController(initialPage: index);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: widget.paths.isEmpty
                ? DishPhoto(api: widget.api)
                : Stack(
                    children: [
                      PageView.builder(
                        controller: controller,
                        itemCount: widget.paths.length,
                        onPageChanged: (value) => setState(() => index = value),
                        itemBuilder: (context, i) => Semantics(
                          label: '查看第 ${i + 1} 张完整照片',
                          button: true,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => _FullPhotos(
                                  api: widget.api,
                                  paths: widget.paths,
                                  initialIndex: i,
                                ),
                              ),
                            ),
                            child: DishPhoto(
                              api: widget.api,
                              path: widget.paths[i],
                              crop: widget.crops.length > i
                                  ? widget.crops[i]
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      if (widget.paths.length > 1)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '${index + 1} / ${widget.paths.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          if (widget.paths.length > 1) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 68,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.paths.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Semantics(
                  label: '第 ${i + 1} 张照片',
                  selected: i == index,
                  child: InkWell(
                    onTap: () => controller.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: i == index ? orange : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: DishPhoto(
                        api: widget.api,
                        path: widget.paths[i],
                        crop: widget.crops.length > i ? widget.crops[i] : null,
                        width: 60,
                        height: 60,
                        radius: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _FullPhotos extends StatefulWidget {
  final Api api;
  final List<String> paths;
  final int initialIndex;
  const _FullPhotos({
    required this.api,
    required this.paths,
    required this.initialIndex,
  });

  @override
  State<_FullPhotos> createState() => _FullPhotosState();
}

class _FullPhotosState extends State<_FullPhotos> {
  late final controller = PageController(initialPage: widget.initialIndex);
  late int index = widget.initialIndex;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(
        '${index + 1} / ${widget.paths.length}',
        style: const TextStyle(color: Colors.white),
      ),
    ),
    body: SafeArea(
      child: PageView.builder(
        controller: controller,
        itemCount: widget.paths.length,
        onPageChanged: (value) => setState(() => index = value),
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image(
              image: dishImageProvider(widget.api, widget.paths[i]),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Text('照片暂时无法加载', style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    ),
  );
}
