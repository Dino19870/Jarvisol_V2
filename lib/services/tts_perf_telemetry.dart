// PERF001 -- opt-in measurements only. Does not alter TTS inference.
// Intentionally no generated text, voice IDs or full file paths in fields.
import 'dart:io';

class TtsPerfTelemetry {
  TtsPerfTelemetry._();

  /// Enables PERF001 when the experimental Windows process is launched with
  /// JARVISOL_PERF_TTS=1. The production release does not contain this patch.
  static bool get enabled => parseEnabled(Platform.environment['JARVISOL_PERF_TTS']);

  static bool parseEnabled(String? value) {
    final v = value?.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }

  /// Ratio of processing wall time to playable audio time. Smaller is faster.
  static double? rtf({required int elapsedUs, required int samples, int sampleRate = 24000}) {
    if (elapsedUs < 0 || samples <= 0 || sampleRate <= 0) return null;
    return elapsedUs * sampleRate / (samples * 1000000.0);
  }

  static double ms(int us) => double.parse((us / 1000.0).toStringAsFixed(2));
}

/// Aggregates one audiobook render. Callers keep their original processing
/// order, error handling and PCM operations unchanged.
class TtsPerfBatch {
  TtsPerfBatch(this.expectedLines) : _total = Stopwatch()..start();

  final int expectedLines;
  final Stopwatch _total;
  int attempted = 0;
  int rendered = 0;
  int failures = 0;
  int outputSamples = 0;
  int prepareUs = 0;
  int synthUs = 0;
  int appendUs = 0;
  int encodeUs = 0;
  int writeUs = 0;

  Stopwatch begin() => Stopwatch()..start();

  int _stop(Stopwatch? s) {
    if (s == null) return 0;
    s.stop();
    return s.elapsedMicroseconds;
  }

  void prepared(Stopwatch? s) => prepareUs += _stop(s);
  void synthesized(Stopwatch? s) => synthUs += _stop(s);
  void appended(Stopwatch? s) => appendUs += _stop(s);
  void encoded(Stopwatch? s) => encodeUs += _stop(s);
  void written(Stopwatch? s) => writeUs += _stop(s);

  Map<String, Object?> finish({required String route}) {
    _total.stop();
    final rtf = TtsPerfTelemetry.rtf(
      elapsedUs: _total.elapsedMicroseconds,
      samples: outputSamples,
    );
    return <String, Object?>{
      'route': route,
      'lines_expected': expectedLines,
      'lines_attempted': attempted,
      'lines_rendered': rendered,
      'lines_failed': failures,
      'audio_seconds': double.parse((outputSamples / 24000.0).toStringAsFixed(2)),
      'total_ms': TtsPerfTelemetry.ms(_total.elapsedMicroseconds),
      'prepare_ms': TtsPerfTelemetry.ms(prepareUs),
      'synthesize_ms': TtsPerfTelemetry.ms(synthUs),
      'append_ms': TtsPerfTelemetry.ms(appendUs),
      'encode_ms': TtsPerfTelemetry.ms(encodeUs),
      'write_ms': TtsPerfTelemetry.ms(writeUs),
      'rtf_total': rtf == null ? null : double.parse(rtf.toStringAsFixed(3)),
    };
  }
}
