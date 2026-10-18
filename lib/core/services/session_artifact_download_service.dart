import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/session_artifact.dart';
import 'artifact_export_service.dart';
import 'connection_manager.dart';

enum SessionArtifactDownloadFailure {
  unavailable,
  expired,
  unsupportedReference,
  accessDenied,
  tooLarge,
  notFound,
  server,
}

final class SessionArtifactDownloadException implements Exception {
  final SessionArtifactDownloadFailure failure;

  const SessionArtifactDownloadException(this.failure);

  @override
  String toString() => 'session_artifact_download_${failure.name}';
}

final class SessionArtifactDownload {
  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  const SessionArtifactDownload({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });
}

/// Bytes of an artifact in a private copy the in-app viewer renders from.
///
/// [_file] lives in the app's scratch storage: nothing here is published, and
/// [SessionArtifactDownloadService.downloadAndSave] stays the only route that
/// puts an artifact in the user's own storage.
final class SessionArtifactViewerCopy {
  final File file;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  const SessionArtifactViewerCopy({
    required this.file,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });
}

typedef SessionArtifactDashboardFactory =
    DashboardClient Function(SavedConnection connection);

/// Descarga únicamente referencias que ya cruzaron el índice estructurado y
/// que se pueden traducir a la ruta oficial autenticada de Hermes Desktop.
/// Nunca abre `file://`, URLs firmadas, hosts externos ni rutas relativas.
final class SessionArtifactDownloadService {
  static const int maximumBytes = 25 * 1024 * 1024;

  final SavedConnection connection;
  final SessionArtifactDashboardFactory _dashboardFactory;
  final Future<Directory> Function() _viewerDirectory;

  SessionArtifactDownloadService({
    required this.connection,
    SessionArtifactDashboardFactory? dashboardFactory,
    Future<Directory> Function()? viewerDirectory,
  }) : _dashboardFactory = dashboardFactory ?? DashboardClient.lazy,
       _viewerDirectory = viewerDirectory ?? defaultViewerDirectory;

  /// Scratch directory for viewer copies. App-private by construction (the app
  /// cache the OS may reclaim), never the user's Downloads.
  static Future<Directory> defaultViewerDirectory() async =>
      Directory('${(await getTemporaryDirectory()).path}/console-artifacts');

  bool canDownload(SessionArtifact artifact) {
    if (artifact.availability == SessionArtifactAvailability.missing ||
        artifact.availability == SessionArtifactAvailability.expired ||
        (artifact.sizeBytes ?? 0) > maximumBytes) {
      return false;
    }
    return _downloadEndpoint(artifact.managedReference) != null;
  }

  Future<SessionArtifactDownload> download(SessionArtifact artifact) async {
    if (artifact.availability == SessionArtifactAvailability.expired) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.expired,
      );
    }
    if (artifact.availability == SessionArtifactAvailability.missing) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.unavailable,
      );
    }
    if ((artifact.sizeBytes ?? 0) > maximumBytes) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.tooLarge,
      );
    }
    final endpoint = _downloadEndpoint(artifact.managedReference);
    if (endpoint == null) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.unsupportedReference,
      );
    }

    final dashboard = _dashboardFactory(connection);
    try {
      final response = await dashboard.apiDownload(
        endpoint,
        maxBytes: maximumBytes,
      );
      if (response.bytes.isEmpty) {
        throw const SessionArtifactDownloadException(
          SessionArtifactDownloadFailure.unavailable,
        );
      }
      final contentType = response.contentType
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      return SessionArtifactDownload(
        bytes: response.bytes,
        fileName: PlatformArtifactExportActions.sanitizeFileName(
          artifact.displayName,
        ),
        mimeType: contentType?.isNotEmpty == true
            ? contentType!
            : artifact.mimeType ?? 'application/octet-stream',
      );
    } on DashboardHttpException catch (error) {
      throw SessionArtifactDownloadException(switch (error.statusCode) {
        401 || 403 => SessionArtifactDownloadFailure.accessDenied,
        404 => SessionArtifactDownloadFailure.notFound,
        410 => SessionArtifactDownloadFailure.expired,
        413 => SessionArtifactDownloadFailure.tooLarge,
        _ => SessionArtifactDownloadFailure.server,
      });
    } on StateError {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.tooLarge,
      );
    } finally {
      dashboard.close();
    }
  }

  Future<ArtifactSaveResult> downloadAndSave(
    SessionArtifact artifact,
    ArtifactExportActions exporter,
  ) async {
    final result = await download(artifact);
    return exporter.saveBytes(fileName: result.fileName, bytes: result.bytes);
  }

  /// [artifact]'s bytes in a private copy the in-app viewer reads.
  ///
  /// Same validation and typed failures as [download]. The copy is named from
  /// the artifact id, so reopening the same artifact reuses one file instead of
  /// piling scratch up, and it never reaches the share sheet.
  Future<SessionArtifactViewerCopy> materialize(
    SessionArtifact artifact,
  ) async {
    final result = await download(artifact);
    final directory = await _viewerDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/${_viewerCopyName(artifact)}');
    if (!file.existsSync() || file.lengthSync() != result.bytes.length) {
      await file.writeAsBytes(result.bytes, flush: true);
    }
    return SessionArtifactViewerCopy(
      file: file,
      fileName: result.fileName,
      mimeType: result.mimeType,
      sizeBytes: result.bytes.length,
    );
  }

  static String _viewerCopyName(SessionArtifact artifact) {
    final safeId = _truncate(
      artifact.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
      64,
    );
    final safeName = _truncate(
      PlatformArtifactExportActions.sanitizeFileName(artifact.displayName),
      96,
    );
    return '${safeId.isEmpty ? 'artifact' : safeId}-$safeName';
  }

  static String _truncate(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);

  String? _downloadEndpoint(String? rawReference) {
    final reference = rawReference?.trim() ?? '';
    if (reference.isEmpty ||
        reference.length > 2048 ||
        _hasControl(reference)) {
      return null;
    }

    if (reference.startsWith('/')) {
      return _managedPathEndpoint(reference);
    }

    final uri = Uri.tryParse(reference);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path != '/api/files/download') {
      return null;
    }
    final query = uri.queryParametersAll;
    final pathValues = query['path'];
    final dashboard = Uri.parse(
      '${connection.dashboardUseHttps ? 'https' : 'http'}://'
      '${connection.dashboardHost}:${connection.dashboardPort}',
    );
    if (uri.scheme.toLowerCase() != dashboard.scheme ||
        uri.host.toLowerCase() != dashboard.host.toLowerCase() ||
        uri.port != dashboard.port ||
        query.length != 1 ||
        pathValues == null ||
        pathValues.length != 1) {
      return null;
    }
    return _managedPathEndpoint(pathValues.single);
  }

  static String? _managedPathEndpoint(String? rawPath) {
    final path = rawPath?.trim() ?? '';
    if (!_safeManagedPath(path)) return null;
    final query = Uri(queryParameters: {'path': path}).query;
    return 'files/download?$query';
  }

  static bool _safeManagedPath(String path) {
    if (path.isEmpty ||
        path == '/' ||
        path.length > 2048 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('//') ||
        path.contains(r'\') ||
        _hasControl(path)) {
      return false;
    }
    for (final rawSegment in path.split('/').skip(1)) {
      if (rawSegment.isEmpty) return false;
      late final String decoded;
      try {
        decoded = Uri.decodeComponent(rawSegment);
      } on FormatException {
        return false;
      }
      if (decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains(r'\') ||
          _hasControl(decoded)) {
        return false;
      }
    }
    final uri = Uri.tryParse(path);
    return uri != null &&
        !uri.hasScheme &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        !uri.pathSegments.any((segment) => segment == '.' || segment == '..');
  }

  static bool _hasControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}
