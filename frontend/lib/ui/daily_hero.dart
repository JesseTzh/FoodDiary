import 'dart:math';

const dailyHeroAssets = [
  'assets/images/hero-playful-kitchen.png',
  'assets/images/hero-cooking-together.png',
  'assets/images/hero-sharing-meal.png',
];

/// A date-seeded selection stays stable across refreshes and devices that day.
String dailyHeroAsset(DateTime date) {
  final seed = date.year * 10000 + date.month * 100 + date.day;
  return dailyHeroAssets[Random(seed).nextInt(dailyHeroAssets.length)];
}
