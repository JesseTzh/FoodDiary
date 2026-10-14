class Diary {
  final String id, title, date, meal, notes, category;
  final List<String> tags, photos;
  final int mood, version;
  final bool favorite;
  final List<Map<String, String>> dishes;
  Diary(Map<String, dynamic> j)
    : id = j['id'],
      title = j['title'],
      date = j['cooked_on'],
      meal = j['meal'] ?? '晚餐',
      notes = j['notes'] ?? '',
      category = j['category'] ?? '家常菜',
      tags = List<String>.from(j['tags'] ?? []),
      photos = (j['media'] as List? ?? [])
          .map((m) => m['url'] as String)
          .toList(),
      mood = j['mood'] ?? 0,
      version = j['version'] ?? 1,
      favorite = j['favorite'] ?? false,
      dishes = (j['dishes'] as List? ?? [])
          .map(
            (d) => {'id': '${d['id'] ?? ''}', 'title': '${d['title'] ?? ''}'},
          )
          .toList();
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cooked_on': date,
    'meal': meal,
    'notes': notes,
    'category': category,
    'tags': tags,
    'mood': mood,
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
const diaryTags = ['家常菜', '早餐', '午餐', '晚餐', '甜品', '汤类', '小吃'];
