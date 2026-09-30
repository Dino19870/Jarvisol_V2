// Minimal libc setenv() FFI bridge for the handful of CrispASR env
// vars that gate compute-graph backend pinning. Dart's
// `Platform.environment` is read-only and reads from a cache taken
// at process start, so any var we want the native side to see must
// be installed via the actual libc `setenv()` call. Do that for the
// kokoro F0Ntrain / decoder-body Metal workaround at app boot —
// CrispASR reads these via `env_bool(...)` inside
// `kokoro_init_from_file`, so they have to be set BEFORE the first
// kokoro session opens.
//
// Apple platforms (macOS, iOS, iPadOS) only. The Metal regression
// doesn't affect Linux / Windows GPU paths (CUDA / Vulkan); pinning
// the stages there would just slow them down for no win.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'log_service.dart';
import '../utils/platform_utils.dart' as plat;

/// Set `name=value` in the current process's native C-runtime environment.
///
/// POSIX uses libc `setenv(name, value, overwrite=1)`. Windows uses the UCRT
/// `_putenv_s(name, value)` entry point so native libraries calling
/// `std::getenv()` (including CrispASR) see changes made after process start.
///
/// Dart's [Platform.environment] is a read-only startup snapshot; it is not
/// suitable for installing a runtime knob that C/C++ code must read.
bool setEnv(String name, String value) {
  final namePtr = name.toNativeUtf8();
  final valuePtr = value.toNativeUtf8();
  try {
    if (plat.isWindows) {
      final ucrt = DynamicLibrary.open('ucrtbase.dll');
      final putenvS = ucrt.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)>('_putenv_s');
      final rc = putenvS(namePtr, valuePtr);
      if (rc != 0) {
        Log.instance.w(
          'env',
          '_putenv_s returned non-zero',
          fields: {'name': name, 'rc': rc},
        );
        return false;
      }
      Log.instance.d(
        'env',
        'set',
        fields: {'name': name, 'value': value, 'api': '_putenv_s'},
      );
      return true;
    }

    if (!(plat.isMacOS || plat.isIOS || plat.isLinux || plat.isAndroid)) {
      return false;
    }

    final libc = DynamicLibrary.process();
    final setenv = libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
    final rc = setenv(namePtr, valuePtr, 1);
    if (rc != 0) {
      Log.instance.w(
        'env',
        'setenv returned non-zero',
        fields: {'name': name, 'rc': rc},
      );
      return false;
    }
    Log.instance.d(
      'env',
      'set',
      fields: {'name': name, 'value': value, 'api': 'setenv'},
    );
    return true;
  } catch (e, st) {
    Log.instance.w(
      'env',
      'native environment update failed',
      error: e,
      stack: st,
      fields: {'name': name},
    );
    return false;
  } finally {
    calloc.free(namePtr);
    calloc.free(valuePtr);
  }
}

/// Pin the kokoro F0Ntrain + decoder-body compute graphs to CPU on
/// Apple Silicon Metal. Workaround for the AdainResBlk1d divergence
/// localised by the upstream CrispASR bisect (2026-05-17). The text
/// encoder, BERT, predictor duration LSTM, and iSTFTNet generator
/// still run on Metal — only the two known-bad stages are pinned.
///
/// Drop this once upstream lands a real Metal fix for AdainResBlk1d
/// (see `handover-prompts/crispasr-kokoro-gpu-metal-regression.md`).
void applyKokoroMetalWorkaround() {
  // Apple platforms only — the bug is in ggml-metal, not in the
  // CUDA / Vulkan / CPU paths.
  if (!(plat.isMacOS || plat.isIOS)) return;
  setEnv('KOKORO_F0N_FORCE_CPU', '1');
  setEnv('KOKORO_DEC_FORCE_CPU', '1');
}

/// Point libespeak-ng at the bundled `espeak-ng-data/` so kokoro's
/// in-process phonemizer (`espeak_Initialize`) finds its data files
/// on platforms where the user's system doesn't have espeak-ng
/// pre-installed. Reads `CRISPASR_ESPEAK_DATA_PATH` inside CrispASR;
/// see `phonemize_espeak_lib` in src/kokoro.cpp.
///
/// Layouts per platform (relative to `Platform.resolvedExecutable`):
///   * macOS .app   — `../Resources/espeak-ng-data`
///   * Linux bundle — `lib/espeak-ng-data` (sibling to libwhisper.so)
///   * Windows bundle — `data/espeak-ng-data` or `espeak-ng-data` next to
///                      runner.exe
///   * Android — caller is expected to extract the assets dir to a
///               writable location first and pass [explicitOverride].
void applyKokoroEspeakDataPath({String? explicitOverride}) {
  String? candidate = explicitOverride;
  if (candidate == null) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates;
    if (plat.isMacOS) {
      // exeDir = .../crisper_weaver.app/Contents/MacOS
      candidates = ['$exeDir/../Resources/espeak-ng-data'];
    } else if (plat.isLinux) {
      candidates = ['$exeDir/lib/espeak-ng-data', '$exeDir/espeak-ng-data'];
    } else if (plat.isWindows) {
      candidates = ['$exeDir/data/espeak-ng-data', '$exeDir/espeak-ng-data'];
    } else {
      // iOS / Android — caller must provide the extracted-asset path.
      return;
    }
    for (final c in candidates) {
      if (Directory(c).existsSync()) {
        candidate = c;
        break;
      }
    }
  }
  if (candidate == null) {
    Log.instance.d('env',
        'bundled espeak-ng-data not found; kokoro will use system espeak-ng if available');
    return;
  }
  setEnv('CRISPASR_ESPEAK_DATA_PATH', candidate);
  Log.instance
      .i('env', 'pointed CRISPASR_ESPEAK_DATA_PATH at bundled data dir',
          fields: {'path': candidate});
}
