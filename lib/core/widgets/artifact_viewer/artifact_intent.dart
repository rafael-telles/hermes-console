import 'dart:convert';

/// The one voice an artifact page has: `window.hermes.send(prompt)` (or
/// declarative `data-hermes-send` on any clickable element) hands a prompt to
/// the agent, exactly like the Desktop preview frame does.
///
/// Mirrors Desktop's `inline-preview-directive.tsx`: same length cap, same
/// one-per-second human-speed gate, same ack vocabulary, so a page written for
/// Desktop behaves identically here.

/// Longest prompt a page may hand over; longer ones are refused with
/// `too_long` and never truncated.
const int maxArtifactIntentLength = 500;

/// One intent per page per second: clicks are human-speed.
const int artifactIntentThrottleMs = 1000;

/// How long `hermes.send()` waits for the app's ack before resolving
/// `undelivered` (the ack is synchronous; this only fires if the app is gone).
const int artifactIntentAckTimeoutMs = 5000;

/// JavaScript channel the shim posts to. The page gets no other bridge.
const String artifactIntentChannel = 'hermesIntent';

/// The shim injected into a guest document. It is the ONLY script the app adds:
/// it posts `{id, prompt}` up the channel, the app validates and answers
/// through [artifactIntentAckScript], and `send()` resolves to that ack — so a
/// page can tell "saved" from "refused" instead of assuming.
String artifactIntentScript() =>
    '<script>(function(){var n=0,w={};'
    'window.__hermesAck=function(id,ack){var r=w[id];if(!r)return;delete w[id];r(ack)};'
    'function send(p){'
    'if(typeof p!=="string"||!p.trim())return Promise.resolve({ok:false,error:"invalid"});'
    'var id=++n;return new Promise(function(res){'
    'var done=function(a){clearTimeout(k);res(a)};'
    'var k=setTimeout(function(){if(w[id]){delete w[id];'
    'res({ok:false,error:"undelivered"})}},'
    '$artifactIntentAckTimeoutMs);'
    'w[id]=done;'
    'var c=window.$artifactIntentChannel;'
    'if(!c||typeof c.postMessage!=="function"){delete w[id];'
    'res({ok:false,error:"undelivered"});return}'
    'c.postMessage(JSON.stringify({id:id,prompt:p}))})}'
    'window.hermes={send:send,maxLength:$maxArtifactIntentLength};'
    'document.addEventListener("click",function(e){'
    'var el=e.target&&e.target.closest?e.target.closest("[data-hermes-send]"):null;'
    'if(el)send(el.getAttribute("data-hermes-send")||"")},true)'
    '})()</script>';

/// What the page asked for, already validated.
sealed class ArtifactIntent {
  const ArtifactIntent();
}

/// A prompt the app will hand to the composer, with the id to ack.
class ArtifactIntentAccept extends ArtifactIntent {
  final int? id;
  final String prompt;

  const ArtifactIntentAccept({required this.id, required this.prompt});
}

/// A refusal: [ack] is what the page's `send()` resolves to.
class ArtifactIntentReject extends ArtifactIntent {
  final int? id;
  final Map<String, Object?> ack;

  const ArtifactIntentReject({required this.id, required this.ack});
}

/// Decodes a channel message: the shim posts JSON, anything else is ignored.
Object? decodeArtifactIntent(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

/// The intent gate. Mirrors Desktop's `evaluateIntent`: every message from our
/// own channel gets an explicit answer, and an accepted intent becomes a user
/// turn — so nothing else may ever look like one.
ArtifactIntent evaluateArtifactIntent(
  Object? data, {
  required int nowMs,
  required int lastAcceptedAtMs,
}) {
  if (data is! Map) {
    return const ArtifactIntentReject(
      id: null,
      ack: {'ok': false, 'error': 'invalid'},
    );
  }
  final rawId = data['id'];
  final id = rawId is int ? rawId : null;
  final rawPrompt = data['prompt'];
  final prompt = rawPrompt is String ? rawPrompt.trim() : '';

  if (prompt.isEmpty) {
    return ArtifactIntentReject(
      id: id,
      ack: const {'ok': false, 'error': 'invalid'},
    );
  }
  if (prompt.length > maxArtifactIntentLength) {
    return ArtifactIntentReject(
      id: id,
      ack: const {
        'ok': false,
        'error': 'too_long',
        'maxLength': maxArtifactIntentLength,
      },
    );
  }
  final elapsed = nowMs - lastAcceptedAtMs;
  if (lastAcceptedAtMs > 0 && elapsed < artifactIntentThrottleMs) {
    return ArtifactIntentReject(
      id: id,
      ack: {
        'ok': false,
        'error': 'throttled',
        'retryAfterMs': artifactIntentThrottleMs - elapsed,
      },
    );
  }
  return ArtifactIntentAccept(id: id, prompt: prompt);
}

/// The call that resolves the page's pending `send()` promise with [ack].
String artifactIntentAckScript(int? id, Map<String, Object?> ack) =>
    'window.__hermesAck&&window.__hermesAck('
    '${jsonEncode(id)},${jsonEncode(ack)});';

/// Whether the page should be told "undelivered" instead of "ok".
Map<String, Object?> artifactIntentUndeliveredAck() => const {
  'ok': false,
  'error': 'undelivered',
};
