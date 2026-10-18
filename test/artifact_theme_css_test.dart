import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_theme_css.dart';

HermesThemeColors _colors(Brightness brightness) => AppTheme.fromId(
  brightness == Brightness.dark ? 'dark' : 'light',
).extension<HermesThemeColors>()!;

void main() {
  group('artifactThemeCss', () {
    test('carries the app palette as the host variables', () {
      final colors = _colors(Brightness.dark);
      final css = artifactThemeCss(colors, dark: true);

      String hex(Color color) =>
          '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

      expect(css, contains('--foreground:${hex(colors.textPrimary)}'));
      expect(css, contains('--background:${hex(colors.background)}'));
      expect(css, contains('--card:${hex(colors.surface)}'));
      expect(css, contains('--border:${hex(colors.divider)}'));
      expect(css, contains('--accent:${hex(colors.accent)}'));
      expect(css, contains('--muted-foreground:${hex(colors.textSecondary)}'));
      expect(css, contains('color-scheme:dark'));
    });

    test('reports the light scheme and an optional font', () {
      final css = artifactThemeCss(
        _colors(Brightness.light),
        dark: false,
        fontFamily: 'Roboto',
      );

      expect(css, contains('color-scheme:light'));
      expect(css, contains('--font-sans:Roboto'));
    });

    test('omits the font variable when there is none', () {
      final css = artifactThemeCss(
        _colors(Brightness.dark),
        dark: true,
        fontFamily: '   ',
      );

      expect(css, isNot(contains('--font-sans')));
    });
  });

  group('buildGuardedArtifactHtml with host theme', () {
    test('keeps doctype first and the guest styles winning the cascade', () {
      const html =
          '<!doctype html><html><head><style>:root{--accent:red}</style>'
          '</head><body>oi</body></html>';

      final guarded = buildGuardedArtifactHtml(
        html,
        scriptsEnabled: true,
        themeCss: ':root{--accent:#123456}',
      );

      expect(guarded.startsWith('<!doctype html>'), isTrue);
      final csp = guarded.indexOf('Content-Security-Policy');
      final theme = guarded.indexOf('hermes-artifact-theme');
      final guest = guarded.indexOf(':root{--accent:red}');
      expect(csp, greaterThan(0));
      expect(theme, greaterThan(csp));
      expect(
        guest,
        greaterThan(theme),
        reason: 'the artifact declares its own :root later, so it wins',
      );
    });

    test('injects nothing when no theme is given', () {
      final guarded = buildGuardedArtifactHtml(
        '<!doctype html><html><body>x</body></html>',
        scriptsEnabled: true,
      );

      expect(guarded, isNot(contains('hermes-artifact-theme')));
    });

    test('ignores a blank theme', () {
      final guarded = buildGuardedArtifactHtml(
        '<!doctype html><html><body>x</body></html>',
        scriptsEnabled: false,
        themeCss: '   ',
      );

      expect(guarded, isNot(contains('hermes-artifact-theme')));
      expect(guarded, contains("script-src 'none'"));
    });

    test('still guards a document without a doctype', () {
      final guarded = buildGuardedArtifactHtml(
        '<html><body>x</body></html>',
        scriptsEnabled: true,
        themeCss: ':root{--accent:#123456}',
      );

      expect(guarded, contains('Content-Security-Policy'));
      expect(guarded, contains('hermes-artifact-theme'));
      expect(guarded, contains('<html><body>x</body></html>'));
    });
  });
}
