import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// CSS the Console injects into a guest artifact document.
///
/// A page authored for Hermes Desktop reads `--foreground`, `--accent`,
/// `--border`, `--card` … off the host frame; the Console's WebView has no such
/// frame, so the same file renders unstyled here. These values come from the
/// live app theme, so the preview matches the app the user is looking at.
///
/// The block is injected BEFORE the document's own `<style>`, so a page that
/// declares `:root { … }` itself wins on equal specificity: these are fallback
/// defaults, never an override.
String artifactThemeCss(
  HermesThemeColors colors, {
  required bool dark,
  String? fontFamily,
}) {
  final vars = <String, String>{
    '--background': _hex(colors.background),
    '--foreground': _hex(colors.textPrimary),
    '--card': _hex(colors.surface),
    '--card-foreground': _hex(colors.textPrimary),
    '--popover': _hex(colors.surfaceVariant),
    '--popover-foreground': _hex(colors.textPrimary),
    '--muted': _hex(colors.surfaceVariant),
    '--muted-foreground': _hex(colors.textSecondary),
    '--dim-foreground': _hex(colors.textTertiary),
    '--border': _hex(colors.divider),
    '--input': _hex(colors.divider),
    '--accent': _hex(colors.accent),
    '--accent-foreground': _hex(colors.onAccent),
    '--primary': _hex(colors.accent),
    '--primary-foreground': _hex(colors.onAccent),
    '--success': _hex(colors.success),
    '--warning': _hex(colors.warning),
    '--danger': _hex(colors.error),
    '--radius': '12px',
    if (fontFamily != null && fontFamily.trim().isNotEmpty)
      '--font-sans': fontFamily.trim(),
  };

  final declarations = vars.entries
      .map((entry) => '${entry.key}:${entry.value}')
      .join(';');

  return 'color-scheme:${dark ? 'dark' : 'light'};'
      'html{color-scheme:${dark ? 'dark' : 'light'};'
      'background:var(--background);}'
      'body{color:var(--foreground);}'
      ':root{$declarations;}';
}

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
