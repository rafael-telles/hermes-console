import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_card.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

const _fallbackKey = ValueKey('embed-fallback');
const _fallback = Text('artefato render-check-v4.html', key: _fallbackKey);
const _placeholderKey = ValueKey('embed-placeholder');
const _page =
    '<!doctype html><html><head><style>body{margin:0}</style></head>'
    '<body><h1 id="marca">Artefato de teste</h1></body></html>';

Widget _app(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(size: size),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, height: size.height, child: child),
      ),
    ),
  ),
);

void main() {
  late FakeWebViewPlatform platform;
  late EmbedConsentStore consent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    consent = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    final owner = EmbedLiveRegistry.instance.owner;
    if (owner != null) EmbedLiveRegistry.instance.drop(owner);
  });

  Widget preview(Future<String> Function() source, {String? title}) =>
      EmbedCard(
        htmlSource: source,
        htmlTitle: title ?? 'render-check-v4.html',
        fallback: _fallback,
        consent: consent,
      );

  testWidgets('previews an artifact even where every embed type is off', (
    tester,
  ) async {
    // Consent gates third-party loads. An artifact preview reads a file the
    // user already downloaded from their own host, so it must not be gated.
    for (final type in EmbedType.values) {
      await consent.setMode(type, EmbedMode.off);
    }

    await tester.pumpWidget(_app(preview(() async => _page)));
    await tester.pumpAndSettle();

    expect(find.byKey(_fallbackKey), findsNothing);
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    expect(platform.controllers, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads the guarded page with the host theme variables', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      _app(
        preview(() async {
          reads++;
          return _page;
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(reads, 1);
    final html = platform.last.loadedHtml.single;
    expect(html, contains("default-src 'none'"));
    expect(html, contains('id="hermes-artifact-theme"'));
    expect(html, contains('--foreground:'));
    expect(html, contains('--accent:'));
    // The guest page's own styles come after the injected defaults.
    expect(
      html.indexOf('hermes-artifact-theme'),
      lessThan(html.indexOf('body{margin:0}')),
    );
    expect(html, contains('id="marca"'));
    // Still a locked document: no JavaScript channel, no navigation.
    expect(platform.last.javaScriptChannels, isEmpty);
    expect(find.byKey(const ValueKey('embed-webview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('falls back to the file row when the page cannot be read', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(preview(() async => throw const FileSystemException('gone'))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_fallbackKey), findsOneWidget);
    expect(find.byKey(const ValueKey('embed-webview')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers no consent choice for an artifact preview', (
    tester,
  ) async {
    await tester.pumpWidget(_app(preview(() async => _page)));
    await tester.pumpAndSettle();

    // Nothing to approve: the bytes are already local, so there is no
    // long-press surface that would write a consent mode for a provider.
    expect(find.byKey(_placeholderKey), findsNothing);
    expect(find.textContaining('Always allow'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
