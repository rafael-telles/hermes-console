/// Server-reported identity of a managed file: the `(size, mtime)` pair the
/// private media cache is keyed by.
///
/// A transcript directive (`MEDIA:<path>` / `::preview{file="…"}`) carries no
/// metadata, so without this the cache key degenerates to the bare server path
/// and a file rewritten in place is never re-fetched: the app keeps serving the
/// bytes of the previous revision.
class ManagedFileStat {
  final int sizeBytes;
  final DateTime? modifiedAt;

  const ManagedFileStat({required this.sizeBytes, this.modifiedAt});
}

/// Resolves a managed file's `(size, mtime)` from the directory listing the
/// host already exposes (`GET /api/files?path=<dir>` — one metadata request,
/// no body bytes).
///
/// Fails soft by design: a missing entry, an unreadable parent, a refused path
/// or a payload in an unexpected shape all return `null`, and the caller keeps
/// today's behaviour (serve the cached copy). Nothing here may turn a download
/// that works into a failure, so every error is swallowed, never rethrown.
class ManagedFileStatService {
  const ManagedFileStatService._();

  static Future<ManagedFileStat?> resolve({
    required Future<Map<String, dynamic>> Function(String endpoint) apiGet,
    required String path,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    // A bare name has no parent to list, and an unsafe guess is worse than
    // falling back to the cached copy.
    if (slash < 0) return null;
    final parent = slash == 0 ? '/' : trimmed.substring(0, slash);
    final name = trimmed.substring(slash + 1);
    if (name.isEmpty || name == '.' || name == '..') return null;

    final Map<String, dynamic> payload;
    try {
      payload = await apiGet('files?path=${Uri.encodeQueryComponent(parent)}');
    } catch (_) {
      return null;
    }

    final entries = payload['entries'];
    if (entries is! List) return null;
    for (final entry in entries) {
      if (entry is! Map) continue;
      if (entry['name']?.toString() != name) continue;
      if (entry['is_directory'] == true) return null;
      final size = entry['size'];
      if (size is! num || size.isNegative) return null;
      final mtime = entry['mtime'];
      return ManagedFileStat(
        sizeBytes: size.toInt(),
        modifiedAt: mtime is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (mtime * 1000).round(),
                isUtc: true,
              )
            : null,
      );
    }
    return null;
  }
}
