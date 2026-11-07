import 'package:flutter/foundation.dart';

// Only release builds passed through scripts/optimize-web.py enable this.
// Native builds and flutter run continue using the original assets.
const _optimizedAssets = bool.fromEnvironment('WEB_OPTIMIZED_ASSETS');
const _webImages = {
  'app-logo',
  'hero-cooking-together',
  'hero-playful-kitchen',
  'hero-sharing-meal',
  'mascot',
  'tomato-scrambled-eggs',
};

String webAssetName(String asset) {
  if (!kIsWeb || !_optimizedAssets) return asset;
  for (final name in _webImages) {
    if (asset == 'assets/images/$name.png') {
      return 'assets/images/$name.webp';
    }
  }
  return asset;
}
