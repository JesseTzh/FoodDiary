import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fooddiary/data/api.dart';
import 'package:fooddiary/ui/app_update.dart';

class _AndroidApi extends Api {
  _AndroidApi({super.client});
  @override
  bool get canConfigureServer => true;
}

final commit = 'a' * 40;
final digest = 'b' * 64;

Map<String, dynamic> release({int code = 42}) => {
  'enabled': true,
  'release': {
    'commit': commit,
    'version': 'Ver:server',
    'version_code': code,
    'sha256': digest,
    'size': 1024 * 1024,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var installedCode = 41;
  Future<Object?> native(MethodCall call) async {
    calls.add(call);
    if (call.method == 'installedVersion') {
      return {'versionCode': installedCode};
    }
    return null;
  }

  setUp(() {
    calls.clear();
    installedCode = 41;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdater.channel, native);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdater.channel, null);
  });

  Api apiWith(Object data, {int status = 200}) => _AndroidApi(
    client: MockClient((request) async {
      expect(
        request.url.toString(),
        'https://food.example/api/v1/updates/android',
      );
      expect(request.headers['Authorization'], isNull);
      return http.Response(jsonEncode({'data': data}), status);
    }),
  )..base = 'https://food.example';

  test('matches full commit and installed package code', () async {
    installedCode = 42;
    final updater = AppUpdater(apiWith(release()), currentCommit: commit);
    expect(await updater.check(), isNull);
    installedCode = 41;
    expect(await updater.check(), isNotNull);
    installedCode = 42;
    expect(
      await AppUpdater(apiWith(release()), currentCommit: 'c' * 40).check(),
      isNotNull,
    );
    expect(calls.every((call) => call.method == 'installedVersion'), true);
  });

  test(
    'disabled updates and older server do not trigger installation',
    () async {
      expect(await AppUpdater(apiWith({'enabled': false})).check(), isNull);
      final update = await AppUpdater(apiWith(release(code: 40))).check();
      expect(update!.canInstall, false);
    },
  );

  test('rejects corrupt metadata and upstream errors', () async {
    final invalid = release();
    (invalid['release'] as Map)['sha256'] = '../bad';
    await expectLater(
      AppUpdater(apiWith(invalid)).check(),
      throwsFormatException,
    );
    await expectLater(
      AppUpdater(apiWith({}, status: 503)).check(),
      throwsException,
    );
  });

  testWidgets('automatic check prompts, decline does not download', (
    tester,
  ) async {
    final api = apiWith(release());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () =>
                    checkForAppUpdate(context, api, automatic: true),
                child: const Text('check'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(find.text('发现应用更新'), findsOneWidget);
    expect(calls.map((c) => c.method), ['installedVersion']);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
    expect(calls.map((c) => c.method), ['installedVersion']);
  });

  testWidgets('download waits for consent and installs through backend URL', (
    tester,
  ) async {
    final api = apiWith(release());
    final updater = AppUpdater(api);
    final update = (await updater.check())!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateDialog(updater: updater, update: update),
        ),
      ),
    );
    expect(calls.any((c) => c.method == 'download'), false);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    final download = calls.firstWhere((c) => c.method == 'download');
    expect(
      download.arguments['url'],
      'https://food.example/api/v1/updates/android/download?sha256=$digest',
    );
    expect(download.arguments['sha256'], digest);
    expect(download.arguments['versionCode'], 42);
    expect(calls.last.method, 'install');
    // Cancelling the system installer permits reopening without downloading again.
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'download').length, 1);
    expect(calls.where((c) => c.method == 'install').length, 2);
  });

  testWidgets('download failure enables retry and cannot install partial APK', (
    tester,
  ) async {
    final updater = AppUpdater(apiWith(release()));
    final update = (await updater.check())!;
    var fail = true;
    final download = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdater.channel, (call) async {
          calls.add(call);
          if (call.method == 'download') {
            if (fail) {
              throw PlatformException(code: 'UPDATE_DOWNLOAD', message: '校验失败');
            }
            await download.future;
          }
          return null;
        });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateDialog(updater: updater, update: update),
        ),
      ),
    );
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('校验失败'), findsOneWidget);
    expect(calls.any((c) => c.method == 'install'), false);
    fail = false;
    await tester.tap(find.text('重试下载'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '暂不更新'))
          .onPressed,
      isNull,
    );
    download.complete();
    await tester.pumpAndSettle();
    expect(calls.last.method, 'install');
  });

  testWidgets('a cleaned installation cache permits downloading again', (
    tester,
  ) async {
    final updater = AppUpdater(apiWith(release()));
    final update = (await updater.check())!;
    var missing = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdater.channel, (call) async {
          calls.add(call);
          if (call.method == 'install' && missing) {
            missing = false;
            throw PlatformException(
              code: 'UPDATE_MISSING',
              message: '安装包已清理，请重新下载',
            );
          }
          return null;
        });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateDialog(updater: updater, update: update),
        ),
      ),
    );
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    missing = true;
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(find.text('安装包已清理，请重新下载'), findsOneWidget);
    await tester.tap(find.text('重试下载'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'download').length, 2);
    expect(find.text('安装更新'), findsOneWidget);
  });

  testWidgets('automatic failures stay quiet and manual failures are visible', (
    tester,
  ) async {
    final api = apiWith({}, status: 503);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () =>
                        checkForAppUpdate(context, api, automatic: true),
                    child: const Text('auto'),
                  ),
                  TextButton(
                    onPressed: () => checkForAppUpdate(context, api),
                    child: const Text('manual'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('auto'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('manual'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败，请检查网络或稍后重试'), findsOneWidget);
  });
}
