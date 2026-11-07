import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/data/models.dart';
import 'package:fooddiary/ui/pages.dart';

class RecipeApi extends Api {
  RecipeApi() : super(mock: true);
  final recipe = <String, dynamic>{
    'id': 'recipe',
    'title': '炒蛋',
    'category': '',
    'description': '',
    'image': '',
    'ingredients': <String>[],
    'steps': <String>[],
    'tags': ['少油'],
    'favorite': false,
    'custom': true,
    'photos': [
      {'url': 'asset:assets/images/tomato-scrambled-eggs.png'},
    ],
  };
  Map<String, dynamic>? saved;
  @override
  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (method == 'PATCH') {
      saved = Map<String, dynamic>.from(body as Map);
      recipe.addAll(saved!);
      return recipe;
    }
    return [recipe];
  }
}

void main() {
  testWidgets('recipe saves with only title and existing photo', (
    tester,
  ) async {
    final api = RecipeApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      NewRecipePage(api: api, recipe: Recipe(api.recipe)),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存菜谱'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存菜谱'));
    await tester.pumpAndSettle();
    expect(api.saved, isNotNull);
    expect(api.saved!['ingredients'], isEmpty);
    expect(api.saved!['steps'], isEmpty);
    expect(api.saved!['description'], '');
    expect(api.saved!['category'], '');
    expect(api.saved!['tags'], ['少油']);
    expect(find.byType(NewRecipePage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
