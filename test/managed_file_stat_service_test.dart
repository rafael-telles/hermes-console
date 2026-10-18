import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/managed_file_stat_service.dart';

void main() {
  List<String> requested = <String>[];

  Map<String, dynamic> listing(List<Map<String, dynamic>> entries) =>
      <String, dynamic>{'path': '/home/hermes/out', 'entries': entries};

  setUp(() => requested = <String>[]);

  Future<Map<String, dynamic>> Function(String) apiReturning(
    Map<String, dynamic> payload,
  ) => (endpoint) async {
    requested.add(endpoint);
    return payload;
  };

  test('reads size and mtime of the named entry', () async {
    final stat = await ManagedFileStatService.resolve(
      apiGet: apiReturning(
        listing([
          {
            'name': 'outro.html',
            'size': 10,
            'mtime': 100.5,
            'is_directory': false,
          },
          {
            'name': 'artefato-teste.html',
            'size': 10283,
            'mtime': 1792329000.25,
            'is_directory': false,
          },
        ]),
      ),
      path: '/home/rafael/Documents/hermes/out/artefato-teste.html',
    );

    expect(stat, isNotNull);
    expect(stat!.sizeBytes, 10283);
    expect(
      stat.modifiedAt,
      DateTime.fromMillisecondsSinceEpoch(1792329000250, isUtc: true),
    );
    expect(requested, hasLength(1));
    expect(
      requested.single,
      'files?path=${Uri.encodeQueryComponent('/home/rafael/Documents/hermes/out')}',
    );
  });

  test('never mistakes a directory with the same name for the file', () async {
    final stat = await ManagedFileStatService.resolve(
      apiGet: apiReturning(
        listing([
          {'name': 'artefato-teste.html', 'size': null, 'is_directory': true},
        ]),
      ),
      path: '/home/hermes/out/artefato-teste.html',
    );

    expect(stat, isNull);
  });

  test('fails soft on a refused or failing listing', () async {
    final stat = await ManagedFileStatService.resolve(
      apiGet: (_) async => throw const SocketException('host down'),
      path: '/home/hermes/out/artefato-teste.html',
    );

    expect(stat, isNull);
  });

  test(
    'fails soft when the entry is gone or the payload is not a listing',
    () async {
      expect(
        await ManagedFileStatService.resolve(
          apiGet: apiReturning(listing([])),
          path: '/home/hermes/out/artefato-teste.html',
        ),
        isNull,
      );
      expect(
        await ManagedFileStatService.resolve(
          apiGet: apiReturning(<String, dynamic>{'entries': 'nope'}),
          path: '/home/hermes/out/artefato-teste.html',
        ),
        isNull,
      );
      expect(
        await ManagedFileStatService.resolve(
          apiGet: apiReturning(
            listing([
              {'name': 'artefato-teste.html', 'size': -1},
            ]),
          ),
          path: '/home/hermes/out/artefato-teste.html',
        ),
        isNull,
      );
    },
  );

  test('refuses a bare name with no parent to list', () async {
    var calls = 0;
    final stat = await ManagedFileStatService.resolve(
      apiGet: (_) async {
        calls++;
        return listing([]);
      },
      path: 'artefato-teste.html',
    );

    expect(stat, isNull);
    expect(calls, 0);
  });

  test('accepts a filename without a reported mtime', () async {
    final stat = await ManagedFileStatService.resolve(
      apiGet: apiReturning(
        listing([
          {'name': 'a.html', 'size': 12, 'mtime': null, 'is_directory': false},
        ]),
      ),
      path: '/home/hermes/out/a.html',
    );

    expect(stat, isNotNull);
    expect(stat!.sizeBytes, 12);
    expect(stat.modifiedAt, isNull);
  });
}
