import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../hermes_premium_ui.dart' show showHermesFloatingSurface;
import '../../artifact_viewer/artifact_html_policy.dart';
import '../../artifact_viewer/artifact_theme_css.dart';
import 'embed_consent_store.dart';
import 'embed_detector.dart';
import 'svg_sanitizer.dart';

/// Only one media WebView lives at a time: loading a second one puts the
/// previous card back to its placeholder instead of keeping both decoded.
final class EmbedLiveRegistry {
  EmbedLiveRegistry._();

  static final EmbedLiveRegistry instance = EmbedLiveRegistry._();

  Object? _owner;
  VoidCallback? _release;

  Object? get owner => _owner;

  void claim(Object owner, VoidCallback release) {
    if (!identical(_owner, owner)) _release?.call();
    _owner = owner;
    _release = release;
  }

  void drop(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _release = null;
  }
}

/// A consent-gated embed: a placeholder of the final size until the user
/// agrees, then a single sandboxed WebView. [fallback] is what the message
/// showed before embeds existed (the link or the code block); it is shown
/// whenever the embed cannot be created.
class EmbedCard extends StatefulWidget {
  /// Link embed, or null for an SVG fence or an inline artifact preview.
  final EmbedDescriptor? descriptor;

  /// Source of an ```svg fence when this is not a link embed.
  final String? svgSource;

  /// Inline preview of a generated HTML artifact: reads the page's markup —
  /// the file card already downloaded it — and renders it in the same locked
  /// WebView the artifact viewer uses.
  ///
  /// Not consent-gated: nothing is fetched from a third party here, and the
  /// download that produced the markup was the user's own action.
  final Future<String> Function()? htmlSource;

  /// Header label of an [htmlSource] preview, i.e. the artifact's file name.
  final String? htmlTitle;

  final Widget fallback;
  final EmbedConsentStore? consent;

  @visibleForTesting
  final Future<bool> Function(Uri uri)? launchExternal;

  @visibleForTesting
  final ArtifactWebViewSettingsFactory settingsFor;

  const EmbedCard({
    required this.fallback,
    this.descriptor,
    this.svgSource,
    this.htmlSource,
    this.htmlTitle,
    this.consent,
    this.launchExternal,
    this.settingsFor = defaultArtifactWebViewSettings,
    super.key,
  }) : assert(
         (descriptor != null ? 1 : 0) +
                 (svgSource != null ? 1 : 0) +
                 (htmlSource != null ? 1 : 0) ==
             1,
         'Exactly one embed source is required',
       );

  @override
  State<EmbedCard> createState() => _EmbedCardState();
}

class _EmbedCardState extends State<EmbedCard> {
  WebViewController? _controller;
  ArtifactHtmlNavigationPolicy? _policy;
  bool _live = false;
  bool _failed = false;
  bool _visible = true;
  bool _covered = false;
  ScrollPosition? _position;
  String? _sanitizedSvg;

  /// Bumped whenever the card leaves its live state or starts a load, so a
  /// load that was already awaiting something can tell it is stale.
  int _generation = 0;

  EmbedConsentStore get _consent => widget.consent ?? EmbedConsentStore.shared;

  EmbedType get _type => widget.descriptor?.provider ?? EmbedType.svg;

  String get _label => widget.descriptor?.label ?? EmbedType.svg.label;

  /// An artifact preview is not consent-gated: its bytes came from the user's
  /// own host through the file card they already tapped.
  bool get _previewsArtifact => widget.htmlSource != null;

  bool get _allowed =>
      _previewsArtifact || _consent.modeFor(_type) != EmbedMode.off;

  @override
  void initState() {
    super.initState();
    final svg = widget.svgSource;
    if (svg != null) {
      _sanitizedSvg = sanitizeSvgForEmbed(svg);
      _failed = _sanitizedSvg == null;
    } else if (!_previewsArtifact &&
        !isAllowedEmbedFrameUrl(widget.descriptor!.embedUrl)) {
      _failed = true;
    }
    _consent.addListener(_onConsentChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      if (covered) _release();
    }
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_checkVisibility);
      _position = position?..addListener(_checkVisibility);
    }
    _maybeAutoLoad();
  }

  @override
  void dispose() {
    _generation++;
    _consent.removeListener(_onConsentChanged);
    _position?.removeListener(_checkVisibility);
    EmbedLiveRegistry.instance.drop(this);
    super.dispose();
  }

  void _onConsentChanged() {
    if (!mounted) return;
    if (!_allowed) _release();
    setState(() {});
    _maybeAutoLoad();
  }

  void _maybeAutoLoad() {
    if (_live || _failed || _covered || !_visible) return;
    if (!_previewsArtifact && _consent.modeFor(_type) != EmbedMode.always) {
      return;
    }
    if (EmbedLiveRegistry.instance.owner != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _live || _covered || !_visible) return;
      if (!_previewsArtifact && _consent.modeFor(_type) != EmbedMode.always) {
        return;
      }
      _load();
    });
  }

  /// Back to the placeholder: scrolled away, route covered, another embed took
  /// the single live slot, or consent was withdrawn. Never reloads by itself.
  void _release() {
    _generation++;
    EmbedLiveRegistry.instance.drop(this);
    if (!_live && _controller == null) return;
    _controller = null;
    _policy = null;
    if (mounted) setState(() => _live = false);
  }

  void _checkVisibility() {
    if (!mounted) return;
    final box = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    final visible = bottom > 0 && top < viewport.size.height;
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) _release();
  }

  /// Whether a load started under [generation] may still touch the WebView:
  /// the card is mounted, was not released or reloaded since, still holds the
  /// single live slot, is visible and uncovered, and consent is not off.
  bool _stillWanted(int generation) =>
      mounted &&
      generation == _generation &&
      identical(EmbedLiveRegistry.instance.owner, this) &&
      _visible &&
      !_covered &&
      _allowed;

  Future<void> _load() async {
    if (_live || _failed) return;
    if (!_visible || _covered || !_allowed) {
      return;
    }
    final generation = ++_generation;
    final policy = ArtifactHtmlNavigationPolicy(
      launchExternal: widget.launchExternal,
    );
    // Read the theme before the awaits: BuildContext must not cross them.
    final isArtifactPreview = _previewsArtifact;
    final themeCss = isArtifactPreview
        ? artifactThemeCss(
            Theme.of(context).hermes,
            dark: Theme.of(context).brightness == Brightness.dark,
            fontFamily: DefaultTextStyle.of(context).style.fontFamily,
          )
        : null;
    final controller = WebViewController(
      onPermissionRequest: denyArtifactPermissionRequest,
    );
    _policy = policy;
    _controller = controller;
    EmbedLiveRegistry.instance.claim(this, _release);
    setState(() => _live = true);
    try {
      await configureArtifactWebView(
        controller,
        policy: policy,
        settingsFor: widget.settingsFor,
      );
      if (!_stillWanted(generation)) return;
      final htmlSource = widget.htmlSource;
      final svg = _sanitizedSvg;
      if (htmlSource != null) {
        // Same locked WebView as the viewer: inline styles and scripts run,
        // nothing can be fetched, no JS channel and no way out of the document.
        final html = await htmlSource();
        if (!_stillWanted(generation)) return;
        await controller.loadHtmlString(
          buildGuardedArtifactHtml(
            html,
            scriptsEnabled: true,
            themeCss: themeCss,
          ),
        );
      } else if (svg != null) {
        await controller.loadHtmlString(buildGuardedSvgHtml(svg));
      } else {
        // The page itself needs scripts; it still gets no JavaScript channel,
        // no file access, no window.open and cannot navigate anywhere.
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        if (!_stillWanted(generation)) {
          unawaited(controller.setJavaScriptMode(JavaScriptMode.disabled));
          return;
        }
        await controller.loadRequest(Uri.parse(widget.descriptor!.embedUrl!));
      }
    } catch (_) {
      if (!_stillWanted(generation)) return;
      EmbedLiveRegistry.instance.drop(this);
      setState(() {
        _failed = true;
        _live = false;
        _controller = null;
      });
    }
  }

  Future<void> _chooseMode() async {
    final s = Strings.of(context);
    final choice = await showHermesFloatingSurface<EmbedMode>(
      context: context,
      maxWidth: 420,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('embed-load-once'),
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text(s.embedLoadOnce),
              onTap: () => Navigator.pop(ctx, EmbedMode.ask),
            ),
            ListTile(
              key: const ValueKey('embed-always-allow'),
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(s.embedAlwaysAllow(_label)),
              onTap: () => Navigator.pop(ctx, EmbedMode.always),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == EmbedMode.always) {
      await _consent.setMode(_type, EmbedMode.always);
    }
    await _load();
  }

  double _heightFor(double width) {
    final d = widget.descriptor;
    final screen = MediaQuery.sizeOf(context).height;
    if (widget.htmlSource != null) {
      // An artifact page has no declared aspect ratio: give it a phone-shaped
      // frame it can scroll inside, never taller than roughly half the screen.
      return (width * 1.02).clamp(200.0, screen / 2);
    }
    if (d == null) {
      final aspect = _svgAspect(_sanitizedSvg ?? '');
      return (width / aspect).clamp(48.0, screen / 3);
    }
    if (d.aspectRatio != null) return width / d.aspectRatio!;
    return d.height ?? width * 0.56;
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed || _failed) return widget.fallback;
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final maxWidth =
        widget.descriptor?.maxWidth ?? (_previewsArtifact ? 720.0 : 640.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth.clamp(0.0, maxWidth)
                : maxWidth;
            final height = _heightFor(width);
            final controller = _controller;
            return SizedBox(
              key: const ValueKey('embed-card-box'),
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _live && controller != null
                    ? Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerUp: (_) => _policy?.registerUserTap(),
                        child: WebViewWidget(
                          key: const ValueKey('embed-webview'),
                          controller: controller,
                        ),
                      )
                    : Material(
                        color: colors.surfaceVariant.withValues(alpha: 0.3),
                        child: InkWell(
                          key: const ValueKey('embed-placeholder'),
                          onTap: _load,
                          // An artifact preview has no consent choice to offer.
                          onLongPress: _previewsArtifact ? null : _chooseMode,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _previewsArtifact
                                        ? Icons.web_asset_outlined
                                        : Icons.play_circle_outline_rounded,
                                    color: colors.textSecondary,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _previewsArtifact
                                        ? widget.htmlTitle ?? _label
                                        : _type == EmbedType.svg
                                        ? s.embedSvgLabel
                                        : s.embedLoad(_label),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  if (!_previewsArtifact &&
                                      _type != EmbedType.svg) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      s.embedLoadNote(_label),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Aspect ratio (width / height) of an SVG from its `viewBox`, else 1.5.
double _svgAspect(String svg) {
  final box = RegExp(
    r'viewBox\s*=\s*"\s*[-\d.]+[ ,]+[-\d.]+[ ,]+([\d.]+)[ ,]+([\d.]+)',
  ).firstMatch(svg);
  final w = double.tryParse(box?.group(1) ?? '');
  final h = double.tryParse(box?.group(2) ?? '');
  if (w == null || h == null || w <= 0 || h <= 0) return 1.5;
  return (w / h).clamp(0.2, 8.0);
}
