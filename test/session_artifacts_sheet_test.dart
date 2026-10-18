import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/generated_artifact.dart';
import 'package:hermes_android/core/models/session_artifact.dart';
import 'package:hermes_android/core/services/generated_artifact_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_artifacts_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app({
  required List<SessionArtifact> artifacts,
  GeneratedArtifactRegistry? generatedArtifactRegistry,
  String? generatedArtifactSessionId,
  ValueChanged<String>? onOpenGeneratedArtifact,
  ValueChanged<SessionArtifactSource>? onJumpToSource,
  bool Function(SessionArtifact artifact)? canDownloadArtifact,
  Future<void> Function(SessionArtifact artifact)? onOpenArtifact,
}) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SessionArtifactsSheet(
        artifacts: artifacts,
        generatedArtifactRegistry: generatedArtifactRegistry,
        generatedArtifactSessionId: generatedArtifactSessionId,
        onOpenGeneratedArtifact: onOpenGeneratedArtifact,
        onJumpToSource: onJumpToSource,
        canDownloadArtifact: canDownloadArtifact,
        onOpenArtifact: onOpenArtifact,
      ),
    ),
  ),
);

SessionArtifact _artifact({
  required String id,
  required SessionArtifactKind kind,
  required String name,
  List<SessionArtifactSource> sources = const [
    SessionArtifactSource(messageOrdinal: 0),
  ],
  String? mimeType,
  int? sizeBytes,
  String? managedReference,
  SessionArtifactAvailability availability =
      SessionArtifactAvailability.unknown,
}) => SessionArtifact(
  id: id,
  kind: kind,
  displayName: name,
  sources: sources,
  mimeType: mimeType,
  sizeBytes: sizeBytes,
  managedReference: managedReference,
  availability: availability,
);

void main() {
  testWidgets('muestra un estado vacío claro', (tester) async {
    await tester.pumpWidget(_app(artifacts: const []));

    expect(find.text('Artefactos de la sesión'), findsOneWidget);
    expect(find.text('0 elementos'), findsOneWidget);
    expect(find.text('Todavía no hay artefactos'), findsOneWidget);
    expect(
      find.textContaining('imágenes, documentos y resultados generados'),
      findsOneWidget,
    );
  });

  testWidgets('agrupa por tipo y conserva el orden dentro del grupo', (
    tester,
  ) async {
    final artifacts = [
      _artifact(
        id: 'file-a',
        kind: SessionArtifactKind.file,
        name: 'primero.zip',
      ),
      _artifact(
        id: 'image-a',
        kind: SessionArtifactKind.image,
        name: 'captura.png',
        mimeType: 'image/png',
        sizeBytes: 1536,
        availability: SessionArtifactAvailability.ready,
      ),
      _artifact(
        id: 'file-b',
        kind: SessionArtifactKind.file,
        name: 'segundo.txt',
      ),
    ];

    await tester.pumpWidget(_app(artifacts: artifacts));

    expect(find.text('Imágenes · 1'), findsOneWidget);
    expect(find.text('Archivos · 2'), findsOneWidget);
    expect(find.text('image/png'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.text('DISPONIBLE'), findsOneWidget);

    final firstFileY = tester.getTopLeft(find.text('primero.zip')).dy;
    final secondFileY = tester.getTopLeft(find.text('segundo.txt')).dy;
    expect(firstFileY, lessThan(secondFileY));
  });

  testWidgets('devuelve la fuente primaria estable sin exponer su ruta', (
    tester,
  ) async {
    const primary = SessionArtifactSource(
      messageId: 'message-stable-42',
      messageOrdinal: 7,
    );
    const secondary = SessionArtifactSource(
      messageId: 'message-stable-99',
      messageOrdinal: 11,
    );
    SessionArtifactSource? selected;
    final artifact = _artifact(
      id: 'generated-a',
      kind: SessionArtifactKind.generated,
      name: 'informe.pdf',
      sources: const [primary, secondary],
      managedReference: '/private/server/session/informe.pdf',
    );

    await tester.pumpWidget(
      _app(
        artifacts: [artifact],
        onJumpToSource: (source) => selected = source,
      ),
    );

    expect(find.text('Origen: mensaje 8 · 2 referencias'), findsOneWidget);
    expect(find.textContaining('/private/server'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('session-artifact-generated-a')),
    );
    await tester.pump();

    expect(selected, primary);
    expect(selected?.messageId, 'message-stable-42');
    expect(selected?.messageOrdinal, 7);
  });

  testWidgets('un artefacto sin fuente no ofrece salto', (tester) async {
    var callbackCount = 0;
    final artifact = _artifact(
      id: 'orphan',
      kind: SessionArtifactKind.unknown,
      name: 'sin-origen',
      sources: const [],
    );

    await tester.pumpWidget(
      _app(artifacts: [artifact], onJumpToSource: (_) => callbackCount++),
    );

    await tester.tap(find.text('sin-origen'));
    await tester.pump();
    expect(callbackCount, 0);
    expect(find.byTooltip('Ir al mensaje de origen'), findsNothing);
  });

  testWidgets('muestra artifacts generados y abre su visor por id estable', (
    tester,
  ) async {
    final registry = GeneratedArtifactRegistry();
    final generated = registry.upsert(
      'connection:session',
      const GeneratedArtifactDetection(
        kind: GeneratedArtifactKind.html,
        language: 'html',
        title: 'panel.html',
      ),
      '<main>Panel seguro</main>',
    )!;
    String? openedArtifactId;

    await tester.pumpWidget(
      _app(
        artifacts: const [],
        generatedArtifactRegistry: registry,
        generatedArtifactSessionId: 'connection:session',
        onOpenGeneratedArtifact: (id) => openedArtifactId = id,
      ),
    );

    expect(find.text('1 elemento'), findsOneWidget);
    expect(find.textContaining('Artefactos generados'), findsOneWidget);
    expect(find.text('panel.html'), findsOneWidget);
    expect(find.text('FUENTE HTML'), findsOneWidget);
    expect(find.text('1 VERSIÓN'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey('generated-artifact-${generated.artifactId}')),
    );
    await tester.pump();

    expect(openedArtifactId, generated.artifactId);
  });

  testWidgets('tocar un artefacto con bytes lo abre en vez de saltar', (
    tester,
  ) async {
    var opened = 0;
    var jumped = 0;
    final artifact = _artifact(
      id: 'widget',
      kind: SessionArtifactKind.generated,
      name: 'widget.html',
      mimeType: 'text/html',
      managedReference: '/srv/out/widget.html',
    );

    await tester.pumpWidget(
      _app(
        artifacts: [artifact],
        canDownloadArtifact: (_) => true,
        onOpenArtifact: (artifact) async => opened++,
        onJumpToSource: (_) => jumped++,
      ),
    );

    expect(find.text('widget.html'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-artifact-widget')));
    await tester.pump();

    expect(opened, 1);
    expect(jumped, 0);
  });

  testWidgets('el botón de la fila sigue saltando a la fuente', (tester) async {
    var opened = 0;
    var jumped = 0;
    final artifact = _artifact(
      id: 'widget',
      kind: SessionArtifactKind.generated,
      name: 'widget.html',
      managedReference: '/srv/out/widget.html',
    );

    await tester.pumpWidget(
      _app(
        artifacts: [artifact],
        canDownloadArtifact: (_) => true,
        onOpenArtifact: (artifact) async => opened++,
        onJumpToSource: (_) => jumped++,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('artifact-jump-widget')));
    await tester.pump();

    expect(jumped, 1);
    expect(opened, 0);
  });

  testWidgets('sin bytes alcanzables el toque mantiene el salto', (
    tester,
  ) async {
    var opened = 0;
    var jumped = 0;
    final artifact = _artifact(
      id: 'missing',
      kind: SessionArtifactKind.file,
      name: 'perdido.bin',
      availability: SessionArtifactAvailability.missing,
    );

    await tester.pumpWidget(
      _app(
        artifacts: [artifact],
        canDownloadArtifact: (_) => false,
        onOpenArtifact: (artifact) async => opened++,
        onJumpToSource: (_) => jumped++,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('session-artifact-missing')));
    await tester.pump();

    expect(jumped, 1);
    expect(opened, 0);
  });

  testWidgets('la fila muestra progreso mientras llegan los bytes', (
    tester,
  ) async {
    final gate = Completer<void>();
    final artifact = _artifact(
      id: 'slow',
      kind: SessionArtifactKind.generated,
      name: 'lento.html',
      managedReference: '/srv/out/lento.html',
    );

    await tester.pumpWidget(
      _app(
        artifacts: [artifact],
        canDownloadArtifact: (_) => true,
        onOpenArtifact: (artifact) => gate.future,
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('session-artifact-slow')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('virtualiza 500 artefactos y construye filas al desplazarse', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final artifacts = List.generate(
      500,
      (index) => _artifact(
        id: 'bulk-$index',
        kind: SessionArtifactKind.file,
        name: 'archivo-$index.txt',
        sources: [SessionArtifactSource(messageOrdinal: index)],
      ),
    );

    await tester.pumpWidget(_app(artifacts: artifacts));

    final builtRows = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return widget is InkWell &&
          key is ValueKey<String> &&
          key.value.startsWith('session-artifact-');
    });
    expect(
      find.byKey(const ValueKey('session-artifact-bulk-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('session-artifact-bulk-499')),
      findsNothing,
    );
    expect(builtRows.evaluate().length, lessThan(100));

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('session-artifacts-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('session-artifact-bulk-499')),
      2000,
      scrollable: scrollable,
      maxScrolls: 50,
    );

    expect(
      find.byKey(const ValueKey('session-artifact-bulk-499')),
      findsOneWidget,
    );
    expect(builtRows.evaluate().length, lessThan(100));
  });
}
