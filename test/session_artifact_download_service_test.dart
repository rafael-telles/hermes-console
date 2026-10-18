import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session_artifact.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_artifact_download_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SavedConnection _connection() => SavedConnection(
  id: 'artifact-download',
  label: 'QA',
  host: 'gateway.private',
  port: 8642,
  apiKey: 'gateway-key',
  useHttps: true,
  dashboardUrl: 'https://gateway.private:9119',
);

SessionArtifact _artifact(
  String? reference, {
  SessionArtifactAvailability availability = SessionArtifactAvailability.ready,
  int? sizeBytes,
}) => SessionArtifact(
  id: 'artifact-1',
  kind: SessionArtifactKind.document,
  displayName: '../../report.pdf',
  sources: const [SessionArtifactSource(messageOrdinal: 2)],
  mimeType: 'application/pdf',
  sizeBytes: sizeBytes,
  managedReference: reference,
  availability: availability,
);

void main() {
  test('descarga solo por Dashboard autenticado y ruta oficial', () async {
    late http.Request captured;
    final dashboard = DashboardClient(
      host: 'gateway.private',
      port: 9119,
      useHttps: true,
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode('pdf-bytes'),
          200,
          headers: {'content-type': 'application/pdf; charset=binary'},
        );
      }),
    );
    final service = SessionArtifactDownloadService(
      connection: _connection(),
      dashboardFactory: (_) => dashboard,
    );

    final result = await service.download(_artifact('/home/hermes/report.pdf'));

    expect(captured.url.path, '/api/files/download');
    expect(captured.url.queryParameters, {'path': '/home/hermes/report.pdf'});
    expect(captured.headers['X-Hermes-Session-Token'], 'session-token');
    expect(utf8.decode(result.bytes), 'pdf-bytes');
    expect(result.fileName, 'report.pdf');
    expect(result.mimeType, 'application/pdf');
  });

  test('rechaza hosts, credenciales, file URI y traversal antes de red', () {
    final service = SessionArtifactDownloadService(connection: _connection());

    for (final reference in const [
      'file:///home/hermes/report.pdf',
      'https://evil.example/api/files/download?path=/home/report.pdf',
      'https://user:secret@gateway.private:9119/api/files/download?path=/home/report.pdf',
      'https://gateway.private:9119/api/files/download?path=/home/report.pdf&token=secret',
      'https://gateway.private:9119/api/files/download?path=/one&path=/two',
      '/home/hermes/../secret.txt',
      '/home/hermes/%2e%2e/secret.txt',
      '/home/hermes/report.pdf?token=secret',
      '/home/hermes//report.pdf',
      r'/home/hermes\..\secret.txt',
      'relative/report.pdf',
    ]) {
      expect(
        service.canDownload(_artifact(reference)),
        isFalse,
        reason: reference,
      );
    }
  });

  test(
    'caducados y respuestas demasiado grandes fallan de forma tipada',
    () async {
      final service = SessionArtifactDownloadService(connection: _connection());

      await expectLater(
        service.download(
          _artifact(
            '/home/hermes/old.pdf',
            availability: SessionArtifactAvailability.expired,
          ),
        ),
        throwsA(
          isA<SessionArtifactDownloadException>().having(
            (error) => error.failure,
            'failure',
            SessionArtifactDownloadFailure.expired,
          ),
        ),
      );
      await expectLater(
        service.download(
          _artifact(
            '/home/hermes/huge.bin',
            sizeBytes: SessionArtifactDownloadService.maximumBytes + 1,
          ),
        ),
        throwsA(
          isA<SessionArtifactDownloadException>().having(
            (error) => error.failure,
            'failure',
            SessionArtifactDownloadFailure.tooLarge,
          ),
        ),
      );
    },
  );

  test('materialize escribe una copia privada con nombre estable', () async {
    final directory = await Directory.systemTemp.createTemp('artifact-viewer-');
    addTearDown(() => directory.delete(recursive: true));
    var requests = 0;
    // The service closes the client it borrowed, so each download needs a new
    // one — same contract as production, where the factory builds it lazily.
    DashboardClient fetch() => DashboardClient(
      host: 'gateway.private',
      port: 9119,
      useHttps: true,
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests += 1;
        return http.Response.bytes(
          utf8.encode('<main>panel</main>'),
          200,
          headers: {'content-type': 'text/html'},
        );
      }),
    );
    final service = SessionArtifactDownloadService(
      connection: _connection(),
      dashboardFactory: (_) => fetch(),
      viewerDirectory: () async => directory,
    );

    final copy = await service.materialize(
      _artifact('/home/hermes/report.pdf'),
    );

    expect(copy.file.parent.path, directory.path);
    expect(copy.fileName, 'report.pdf');
    expect(copy.mimeType, 'text/html');
    expect(copy.sizeBytes, 18);
    expect(await copy.file.readAsString(), '<main>panel</main>');
    expect(directory.listSync().map((entry) => entry.path.split('/').last), [
      copy.file.path.split('/').last,
    ]);

    // Reopening the same artifact reuses the copy: one write, one file.
    final again = await service.materialize(
      _artifact('/home/hermes/report.pdf'),
    );
    expect(again.file.path, copy.file.path);
    expect(directory.listSync(), hasLength(1));
    expect(requests, 2);
  });

  test('materialize no deja copia cuando el servidor rechaza', () async {
    final directory = await Directory.systemTemp.createTemp('artifact-viewer-');
    addTearDown(() => directory.delete(recursive: true));
    final service = SessionArtifactDownloadService(
      connection: _connection(),
      dashboardFactory: (_) => DashboardClient(
        host: 'gateway.private',
        port: 9119,
        useHttps: true,
        manualToken: 'session-token',
        httpClientOverride: MockClient(
          (_) async => http.Response('denied', 403),
        ),
      ),
      viewerDirectory: () async => directory,
    );

    await expectLater(
      service.materialize(_artifact('/home/hermes/secret.pdf')),
      throwsA(
        isA<SessionArtifactDownloadException>().having(
          (error) => error.failure,
          'failure',
          SessionArtifactDownloadFailure.accessDenied,
        ),
      ),
    );
    expect(directory.listSync(), isEmpty);
  });
}
