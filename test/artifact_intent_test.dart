import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_intent.dart';

void main() {
  group('artifactIntentScript', () {
    test('exposes the documented surface and the declarative attribute', () {
      final script = artifactIntentScript();

      expect(script, contains('window.hermes={send:send,maxLength:500}'));
      expect(script, contains('data-hermes-send'));
      expect(script, startsWith('<script>'));
      expect(script, endsWith('</script>'));
      // The one door out is the channel, and it posts JSON.
      expect(script, contains('window.$artifactIntentChannel'));
      expect(script, contains('JSON.stringify({id:id,prompt:p})'));
      // Ack path the app answers through.
      expect(script, contains('window.__hermesAck='));
    });

    test(
      'never truncates: the cap is refused by the app, not trimmed here',
      () {
        expect(artifactIntentScript(), isNot(contains('substring')));
      },
    );
  });

  group('evaluateArtifactIntent', () {
    ArtifactIntent decide(
      Object? data, {
      int nowMs = 10000,
      int lastAcceptedAtMs = 0,
    }) => evaluateArtifactIntent(
      data,
      nowMs: nowMs,
      lastAcceptedAtMs: lastAcceptedAtMs,
    );

    test('accepts a prompt, trimmed, carrying the call id', () {
      final decision = decide({'id': 7, 'prompt': '  get-price eth  '});

      expect(decision, isA<ArtifactIntentAccept>());
      final accept = decision as ArtifactIntentAccept;
      expect(accept.id, 7);
      expect(accept.prompt, 'get-price eth');
    });

    test('accepts a prompt exactly at the cap untouched', () {
      final prompt = 'p' * maxArtifactIntentLength;
      final decision = decide({'id': 1, 'prompt': prompt});

      expect((decision as ArtifactIntentAccept).prompt, prompt);
      expect(decision.prompt.length, maxArtifactIntentLength);
    });

    test('refuses an over-length prompt instead of truncating it', () {
      final decision = decide({
        'id': 2,
        'prompt': 'p' * (maxArtifactIntentLength + 1),
      });

      expect(decision, isA<ArtifactIntentReject>());
      final reject = decision as ArtifactIntentReject;
      expect(reject.ack['error'], 'too_long');
      expect(reject.ack['maxLength'], maxArtifactIntentLength);
      expect(reject.ack['ok'], isFalse);
    });

    test('refuses a throttled prompt with a retry hint', () {
      final decision = decide(
        {'id': 3, 'prompt': 'de novo'},
        nowMs: 10400,
        lastAcceptedAtMs: 10000,
      );

      expect(decision, isA<ArtifactIntentReject>());
      final reject = decision as ArtifactIntentReject;
      expect(reject.ack['error'], 'throttled');
      expect(reject.ack['retryAfterMs'], 600);
    });

    test('accepts again once the second has passed', () {
      final decision = decide(
        {'id': 4, 'prompt': 'outra vez'},
        nowMs: 11000,
        lastAcceptedAtMs: 10000,
      );

      expect(decision, isA<ArtifactIntentAccept>());
    });

    test('refuses an empty or non-string prompt as invalid', () {
      for (final data in <Object?>[
        {'id': 5, 'prompt': '   '},
        {'id': 5},
        {'id': 5, 'prompt': 42},
        'nope',
        null,
      ]) {
        final decision = decide(data);
        expect(decision, isA<ArtifactIntentReject>(), reason: '$data');
        expect((decision as ArtifactIntentReject).ack['error'], 'invalid');
      }
    });

    test('drops a non-integer id so an ack cannot be aimed with it', () {
      final decision = decide({'id': '7', 'prompt': 'oi'});

      expect((decision as ArtifactIntentAccept).id, isNull);
    });
  });

  group('acks', () {
    test('an id-less ack is still valid JavaScript', () {
      final script = artifactIntentAckScript(null, const {'ok': true});

      expect(script, contains('window.__hermesAck&&window.__hermesAck(null,'));
      expect(script, contains('{"ok":true}'));
    });

    test('carries the error payload through', () {
      final script = artifactIntentAckScript(9, artifactIntentUndeliveredAck());

      expect(script, contains('9'));
      expect(script, contains('"error":"undelivered"'));
    });
  });

  test('decodeArtifactIntent ignores anything that is not JSON', () {
    expect(decodeArtifactIntent('{"id":1,"prompt":"a"}'), isA<Map>());
    expect(decodeArtifactIntent('not json'), isNull);
  });
}
