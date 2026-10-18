import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/services/managed_file_stat_service.dart';

/// A directive reference: exactly what `MEDIA:<path>` / `::preview{file="…"}`
/// produces — a server path with no size/mtime.
const _directive = GeneratedMediaReference(
  source: '/home/hermes/out/artefato-teste.html',
  kind: GeneratedMediaKind.file,
  sourceKind: GeneratedMediaSourceKind.serverPath,
  displayName: 'artefato-teste.html',
  mimeType: 'text/html',
  htmlPreview: true,
);

/// An MP4-shaped body of [size] bytes: the cache validates the leading bytes
/// before it reuses a copy.
List<int> _body(int size) {
  final bytes = <int>[
    0,
    0,
    0,
    24,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6f,
    0x6d,
  ];
  while (bytes.length < size) {
    bytes.add(0x20);
  }
  return bytes;
}

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('generated_media_stat');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test(
    're-fetches when the host reports a new identity for the same path',
    () async {
      var fetches = 0;
      var revision = 0;
      Future<void> fetch(String path, File destination) async {
        fetches++;
        await destination.writeAsBytes(_body(revision == 0 ? 12 : 24));
      }

      Future<ManagedFileStat?> stat(String path) async => ManagedFileStat(
        sizeBytes: revision == 0 ? 12 : 24,
        modifiedAt: DateTime.utc(2026, 10, 18, 13, revision),
      );

      final first = await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        statServerPath: stat,
        baseDir: temporary,
      );
      final firstLength = await first.length();

      revision = 1;
      final second = await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        statServerPath: stat,
        baseDir: temporary,
      );
      final secondLength = await second.length();

      expect(firstLength, 12);
      expect(secondLength, 24);
      expect(fetches, 2);

      // The revision the host keeps reporting stays cached.
      final third = await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        statServerPath: stat,
        baseDir: temporary,
      );
      expect(await third.length(), 24);
      expect(fetches, 2);
    },
  );

  test(
    'keeps the cached copy when the host cannot report an identity',
    () async {
      var fetches = 0;
      Future<void> fetch(String path, File destination) async {
        fetches++;
        await destination.writeAsBytes(_body(12));
      }

      await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        statServerPath: (_) async => null,
        baseDir: temporary,
      );
      final second = await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        statServerPath: (_) async => throw const SocketException('host down'),
        baseDir: temporary,
      );

      expect(fetches, 1);
      expect(await second.length(), 12);
    },
  );

  test(
    'does not ask the host when the reference already carries identity',
    () async {
      var statCalls = 0;
      var fetches = 0;
      final identified = GeneratedMediaReference(
        source: '/home/hermes/out/artefato-teste.html',
        kind: GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.serverPath,
        mimeType: 'text/html',
        sizeBytes: 12,
        modifiedAt: DateTime.utc(2026, 10, 18, 13, 40),
      );

      await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        identified,
        fetchServerPathToFile: (path, destination) async {
          fetches++;
          await destination.writeAsBytes(_body(12));
        },
        statServerPath: (_) async {
          statCalls++;
          return const ManagedFileStat(sizeBytes: 12);
        },
        baseDir: temporary,
      );

      expect(statCalls, 0);
      expect(fetches, 1);
    },
  );

  test('a size without an mtime still revalidates', () async {
    // A same-length rewrite is invisible to a size-only identity, so the host
    // is asked whenever either half of the pair is missing.
    var statCalls = 0;
    const sizeOnly = GeneratedMediaReference(
      source: '/home/hermes/out/artefato-teste.html',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      mimeType: 'text/html',
      sizeBytes: 12,
    );

    await GeneratedMediaService.ensureDownloaded(
      'connection-a',
      sizeOnly,
      fetchServerPathToFile: (path, destination) async {
        await destination.writeAsBytes(_body(12));
      },
      statServerPath: (_) async {
        statCalls++;
        return ManagedFileStat(
          sizeBytes: 12,
          modifiedAt: DateTime.utc(2026, 10, 18, 13, 40),
        );
      },
      baseDir: temporary,
    );

    expect(statCalls, 1);
  });

  test(
    'without a stat fetcher nothing changes: cache by path still wins',
    () async {
      var fetches = 0;
      Future<void> fetch(String path, File destination) async {
        fetches++;
        await destination.writeAsBytes(_body(12));
      }

      await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        baseDir: temporary,
      );
      await GeneratedMediaService.ensureDownloaded(
        'connection-a',
        _directive,
        fetchServerPathToFile: fetch,
        baseDir: temporary,
      );

      expect(fetches, 1);
    },
  );
}
