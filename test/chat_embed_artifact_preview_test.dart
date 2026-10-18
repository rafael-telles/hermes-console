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
      // The chat's message list is a scrollable, so a content-sized artifact
      // is unbounded vertically there; the harness matches that.
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, child: child),
        ),
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

  testWidgets('sizes the frame to the page it loaded', (tester) async {
    // A fixed-height frame cropped the page: the chat list owns the vertical
    // drag, so the preview had no way to scroll. The frame follows the content.
    platform.javaScriptResult = 520;

    await tester.pumpWidget(_app(preview(() async => _page)));
    await tester.pumpAndSettle();
    // The height is read behind a short delay (layout settles first).
    await tester.pump(const Duration(milliseconds: 250));

    expect(platform.last.runScripts, isNotEmpty);
    expect(
      tester.getSize(find.byKey(const ValueKey('embed-card-box'))).height,
      520,
    );
    // The page fits, so there is nothing to open elsewhere.
    expect(find.byKey(const ValueKey('embed-artifact-open')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runs the artifact\'s own scripts', (tester) async {
    // Without this the resolve failed: the shared viewer configuration leaves
    // JavaScript disabled, so the page's own scripts never ran and it could
    // not report its height either.
    await tester.pumpWidget(_app(preview(() async => _page)));
    await tester.pumpAndSettle();

    expect(platform.last.javaScriptMode, JavaScriptMode.unrestricted);
    // Still no bridge to the app.
    expect(platform.last.javaScriptChannels, isEmpty);
  });

  testWidgets('a page that never reports its height offers the viewer', (
    tester,
  ) async {
    platform.javaScriptResult = 0;
    var opened = 0;

    await tester.pumpWidget(
      _app(
        EmbedCard(
          htmlSource: () async => _page,
          htmlTitle: 'render-check-v4.html',
          onOpenFull: () => opened++,
          fallback: _fallback,
          consent: consent,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The frame keeps a generous guess, and the escape hatch is on screen.
    expect(find.byKey(const ValueKey('embed-artifact-open')), findsOneWidget);
    tester
        .widget<TextButton>(find.byKey(const ValueKey('embed-artifact-open')))
        .onPressed!();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a page taller than the frame offers the viewer', (tester) async {
    platform.javaScriptResult = 9000;
    var opened = 0;

    await tester.pumpWidget(
      _app(
        EmbedCard(
          htmlSource: () async => _page,
          htmlTitle: 'render-check-v4.html',
          onOpenFull: () => opened++,
          fallback: _fallback,
          consent: consent,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final box = tester.getSize(find.byKey(const ValueKey('embed-card-box')));
    expect(box.height, lessThan(9000));
    expect(find.byKey(const ValueKey('embed-artifact-open')), findsOneWidget);

    tester
        .widget<TextButton>(find.byKey(const ValueKey('embed-artifact-open')))
        .onPressed!();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
}
