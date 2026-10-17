/// Categorías estables de la biblioteca publicadas por Hermes Desktop 0.20.
///
/// El filtro de la lista es una preferencia de vista de este dispositivo: se
/// recuerda entre aperturas y nunca viaja al servidor.
enum SessionCategory {
  /// Conversaciones: todo lo que no es una automatización.
  chats('chats'),

  /// Sesiones de cron, kanban, subagente, webhook y one-shot.
  automation('automation'),

  /// Las dos anteriores.
  all('all');

  /// Lo que se guarda en las preferencias y lo que entiende el servidor.
  final String wire;
  const SessionCategory(this.wire);

  /// Un valor ausente o desconocido se lee como [chats], el alcance original
  /// de la lista.
  static SessionCategory fromWire(Object? value) {
    for (final category in values) {
      if (category.wire == value) return category;
    }
    return chats;
  }
}

/// Fuentes que Hermes Agent 0.20 considera automatización.
///
/// El orden es canónico porque también se usa al serializar `sources` y
/// `exclude_sources`; no se añaden heurísticas por nombre o prefijo.
abstract final class AutomationSessionSources {
  static const List<String> values = <String>[
    'cron',
    'kanban',
    'subagent',
    'tool',
    'acp',
    'hermes_flow',
    'vulcan_delegate',
    'webhook',
    // `hermes -z` / `chat -q` one-shot runs (Desktop SIDEBAR_EXCLUDED_SOURCES).
    'oneshot',
  ];

  static const Set<String> _set = <String>{
    'cron',
    'kanban',
    'subagent',
    'tool',
    'acp',
    'hermes_flow',
    'vulcan_delegate',
    'webhook',
    'oneshot',
  };

  static bool contains(String source) => _set.contains(source.trim());
}

extension SessionCategoryScope on SessionCategory {
  List<String> get sources => switch (this) {
    SessionCategory.automation => AutomationSessionSources.values,
    SessionCategory.chats || SessionCategory.all => const <String>[],
  };

  List<String> get excludeSources => switch (this) {
    SessionCategory.chats => AutomationSessionSources.values,
    SessionCategory.automation || SessionCategory.all => const <String>[],
  };

  bool includesSource(String source) => switch (this) {
    SessionCategory.chats => !AutomationSessionSources.contains(source),
    SessionCategory.automation => AutomationSessionSources.contains(source),
    SessionCategory.all => true,
  };
}
