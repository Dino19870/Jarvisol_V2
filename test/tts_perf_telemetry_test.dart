import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/services/tts_perf_telemetry.dart';

void main() {
  group('PERF001 opt-in metrics: pure contracts', () {
    test('disabled unless explicitly opted in', () {
      expect(TtsPerfTelemetry.parseEnabled(null), isFalse);
      expect(TtsPerfTelemetry.parseEnabled(''), isFalse);
      expect(TtsPerfTelemetry.parseEnabled('0'), isFalse);
      expect(TtsPerfTelemetry.parseEnabled('true'), isTrue);
      expect(TtsPerfTelemetry.parseEnabled(' 1 '), isTrue);
      expect(TtsPerfTelemetry.parseEnabled('YES'), isTrue);
    });

    test('RTF is wall time divided by audio time', () {
      expect(TtsPerfTelemetry.rtf(elapsedUs: 24000000, samples: 240000), 2.4);
      expect(TtsPerfTelemetry.rtf(elapsedUs: 5000000, samples: 240000), 0.5);
      expect(TtsPerfTelemetry.rtf(elapsedUs: 1000, samples: 0), isNull);
      expect(TtsPerfTelemetry.rtf(elapsedUs: -1, samples: 10), isNull);
      expect(TtsPerfTelemetry.rtf(elapsedUs: 1, samples: 10, sampleRate: 0), isNull);
    });

    test('empty batch produces no false efficiency ratio or identifying text', () {
      final batch = TtsPerfBatch(3);
      final fields = batch.finish(route: 'chapter');
      expect(fields['lines_expected'], 3);
      expect(fields['lines_rendered'], 0);
      expect(fields['rtf_total'], isNull);
      expect(fields.keys, isNot(contains('text')));
      expect(fields.keys, isNot(contains('path')));
    });
  });
}
