import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/ui/theme.dart';

void main() {
  testWidgets('web history back restores the previous page in one frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: kitchenTheme(web: true).copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('详情页')),
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
    final route = ModalRoute.of(tester.element(find.text('详情页')))!;
    expect(route.reverseTransitionDuration, Duration.zero);
    // Flutter must leave Web's edge gesture to the browser history layer.
    await tester.dragFrom(const Offset(5, 300), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('详情页'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('native iOS keeps the standard Cupertino page transition', () {
    final native = kitchenTheme(web: false);
    expect(
      native.pageTransitionsTheme.builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
  });
}
