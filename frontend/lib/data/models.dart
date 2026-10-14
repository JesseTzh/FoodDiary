import 'dart:ui' show Rect;

class Diary {
  final String id, title, date, notes, category;
  final List<String> tags, photos;
  final List<Rect?> photoCrops;
  final int mood, version, rating;
  final bool favorite;
  final List<Map<String, String>> dishes;
  Diary(Map<String, dynamic> j)
    : id = j['id'],
      title = j['title'],
      date = j['cooked_on'],
      notes = j['notes'] ?? '',
      category = j['category'] ?? '家常菜',
      tags = List<String>.from(j['tags'] ?? []),
      photos = (j['media'] as List? ?? [])
          .map((m) => m['url'] as String)
          .toList(),
      photoCrops = (j['media'] as List? ?? []).map<Rect?>((m) {
        final w = (m['crop_width'] as num?)?.toDouble() ?? 1;
        final h = (m['crop_height'] as num?)?.toDouble() ?? 1;
        return w >= .99 && h >= .99
            ? null
            : Rect.fromLTWH(
                (m['crop_x'] as num?)?.toDouble() ?? 0,
                (m['crop_y'] as num?)?.toDouble() ?? 0,
                w,
                h,
              );
      }).toList(),
      mood = j['mood'] ?? 0,
      rating = j['rating'] ?? 0,
      version = j['version'] ?? 1,
      favorite = j['favorite'] ?? false,
      dishes = (j['dishes'] as List? ?? [])
          .map(
            (d) => {
              'id': '${d['id'] ?? ''}',
              'title': '${d['title'] ?? ''}',
              'notes': '${d['notes'] ?? ''}',
              'rating': '${d['rating'] ?? 0}',
            },
          )
          .toList();
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cooked_on': date,
    'notes': notes,
    'category': category,
    'tags': tags,
    'mood': mood,
    'rating': rating == 0 ? null : rating,
    'version': version,
    'favorite': favorite,
    'dishes': dishes,
  };
}

class Recipe {
  final String id, title, category, description, image;
  final List<String> ingredients, steps;
  final bool favorite, custom;
  final String? coverMediaId;
  final List<dynamic> photos;
  Recipe(Map<String, dynamic> j)
    : id = j['id'],
      title = j['title'],
      category = j['category'],
      description = j['description'],
      image = j['image'],
      ingredients = List<String>.from(j['ingredients'] ?? []),
      steps = List<String>.from(j['steps'] ?? []),
      favorite = j['favorite'],
      custom = j['custom'],
      coverMediaId = j['cover_media_id'],
      photos = List<dynamic>.from(j['photos'] ?? []);
}

const moods = ['😋', '🥰', '😊', '🤩', '😣'];
const categories = ['全部', '家常菜', '素菜', '肉类', '汤类', '主食', '甜品'];
const diaryTags = ['家常菜', '甜品', '汤类', '小吃', '聚餐', '快手菜'];
