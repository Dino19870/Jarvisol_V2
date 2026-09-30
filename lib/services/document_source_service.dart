import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'image_ocr_service.dart';
import '../main.dart' show transcriptionServiceProvider;
import 'settings_service.dart' show settingsServiceProvider, SettingsService;
import 'transcription_service.dart' show TranscriptionService;

class DocumentSourceItem {
  final String name;
  final String path;
  final String type; // 'text', 'doc', 'sheet', 'slide', 'pdf', 'image', 'audio', 'clipboard', 'manual'
  final String textContent;
  final Uint8List? bytes;
  final int sizeBytes;
  final DateTime importedAt;

  DocumentSourceItem({
    required this.name,
    required this.path,
    required this.type,
    required this.textContent,
    this.bytes,
    required this.sizeBytes,
    required this.importedAt,
  });

  bool get isImage => type == 'image';
  bool get isAudio => type == 'audio';
}

final documentSourceServiceProvider = Provider<DocumentSourceService>((ref) {
  final tx = ref.watch(transcriptionServiceProvider);
  final settings = ref.watch(settingsServiceProvider);
  return DocumentSourceService(
    transcriptionService: tx,
    settingsService: settings,
  );
});

class DocumentSourceService {
  final TranscriptionService? _transcriptionService;
  final SettingsService? _settingsService;

  DocumentSourceService({
    TranscriptionService? transcriptionService,
    SettingsService? settingsService,
  })  : _transcriptionService = transcriptionService,
        _settingsService = settingsService;
  /// Extracts text and metadata from a local file path.
  Future<DocumentSourceItem> parseFile(String filePath, {Uint8List? fileBytes}) async {
    final bytes = fileBytes ?? await File(filePath).readAsBytes();
    final ext = p.extension(filePath).toLowerCase();
    final name = p.basename(filePath);
    final size = bytes.length;
    final now = DateTime.now();

    // 1. Text & Code files
    if (['.txt', '.md', '.markdown', '.json', '.csv', '.log', '.xml', '.html', '.dart', '.py', '.js', '.ts', '.yaml', '.yml', '.ini', '.env'].contains(ext)) {
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = latin1.decode(bytes);
      }
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'text',
        textContent: content,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 2. Legacy Word binary (.doc)
    if (ext == '.doc') {
      final text = _extractLegacyDoc(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'doc',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 3. Word OpenXML (.docx)
    if (ext == '.docx') {
      final text = _extractDocx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'doc',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 4. PowerPoint (.pptx)
    if (ext == '.pptx') {
      final text = _extractPptx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'slide',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 5. Excel (.xlsx)
    if (ext == '.xlsx') {
      final text = _extractXlsx(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'sheet',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 6. PDF (.pdf)
    if (ext == '.pdf') {
      final text = _extractPdfText(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'pdf',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 7. E-Book (.epub)
    if (ext == '.epub') {
      final text = _extractEpub(bytes);
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'book',
        textContent: text,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 8. Images (Automated native OCR extraction)
    if (['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'].contains(ext)) {
      final ocrService = ImageOcrService();
      final ocrText = await ocrService.extractText(filePath, bytes: bytes);
      if (ocrText.trim().isEmpty) {
        throw FormatException(
          'Aucun texte exploitable n\'a été extrait de l\'image "$name".',
        );
      }
      final formattedContent =
          '[Contenu textuel extrait par OCR de l\'image "$name"] :\n---\n${ocrText.trim()}\n---';

      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'image',
        textContent: formattedContent,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // 9. Audio
    if (['.mp3', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.flac', '.webm', '.amr', '.wma'].contains(ext)) {
      if (_transcriptionService == null) {
        throw Exception('Service de transcription ASR indisponible pour le fichier audio "$name".');
      }

      final tx = _transcriptionService;
      if (tx.currentEngine == null) {
        await tx.initialize(preferredEngine: _settingsService?.preferredEngine);
      }
      if (tx.currentEngine?.currentModelId == null) {
        final modelToLoad = _settingsService?.defaultModel ?? 'large-v3-turbo';
        await tx.loadModel(modelToLoad);
      }

      File targetAudioFile;
      bool isTemp = false;
      if (File(filePath).existsSync()) {
        targetAudioFile = File(filePath);
      } else {
        final tempDir = Directory.systemTemp;
        targetAudioFile = File(p.join(tempDir.path, 'cw_doc_audio_${now.millisecondsSinceEpoch}$ext'));
        await targetAudioFile.writeAsBytes(bytes);
        isTemp = true;
      }

      String transcribedText = '';
      try {
        final lang = _settingsService?.defaultLanguage;
        final segments = await tx.transcribeFile(
          targetAudioFile,
          language: (lang != null && lang != 'auto') ? lang : null,
        );
        transcribedText = segments
            .map((s) => s.text.trim())
            .where((t) => t.isNotEmpty)
            .join(' ');
      } finally {
        if (isTemp && targetAudioFile.existsSync()) {
          try {
            await targetAudioFile.delete();
          } catch (_) {}
        }
      }

      if (transcribedText.trim().isEmpty) {
        throw Exception('Impossible d\'extraire la transcription audio ou fichier audio silencieux/invalide : $name');
      }

      final formattedContent = '[Transcription audio de "$name"] :\n---\n$transcribedText\n---';

      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'audio',
        textContent: formattedContent,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    }

    // Fallback: accept genuinely textual unknown extensions, but never create a
    // fake "binary source" that would then be indexed as if extraction had
    // succeeded.
    try {
      final content = utf8.decode(bytes);
      if (content.trim().isEmpty) {
        throw const FormatException('Fichier texte vide');
      }
      return DocumentSourceItem(
        name: name,
        path: filePath,
        type: 'text',
        textContent: content,
        bytes: bytes,
        sizeBytes: size,
        importedAt: now,
      );
    } catch (_) {
      throw UnsupportedError(
        'Format binaire non pris en charge ou contenu inexploitable : $name',
      );
    }
  }

  /// Creates a source item from clipboard or direct user text input.
  DocumentSourceItem createFromText({required String title, required String text, String type = 'manual'}) {
    final bytes = utf8.encode(text);
    return DocumentSourceItem(
      name: title,
      path: '',
      type: type,
      textContent: text,
      bytes: Uint8List.fromList(bytes),
      sizeBytes: bytes.length,
      importedAt: DateTime.now(),
    );
  }

  /// Extracts text from a classic OLE2 Word `.doc` file.
  ///
  /// This is a portable, dependency-free reader for the Word 97-2003 piece
  /// table. It intentionally extracts text only; formatting/macros/objects are
  /// ignored. Unsupported/encrypted/corrupt files fail explicitly instead of
  /// becoming a fake source.
  String _extractLegacyDoc(Uint8List bytes) {
    const oleSignature = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if (bytes.length < 512) {
      throw const FormatException('Fichier .doc trop court');
    }
    for (var i = 0; i < oleSignature.length; i++) {
      if (bytes[i] != oleSignature[i]) {
        throw const FormatException(
          'Le fichier .doc n\'est pas un document OLE Word 97-2003 valide',
        );
      }
    }

    final streams = _readOleCompoundStreams(
      bytes,
      const {'WordDocument', '0Table', '1Table'},
    );
    final word = streams['WordDocument'];
    if (word == null || word.length < 32) {
      throw const FormatException('Flux WordDocument absent ou invalide');
    }

    // FIB flags: fEncrypted is bit 8. Refuse encrypted documents rather than
    // returning gibberish.
    final fibFlags = _u16(word, 0x0A);
    if ((fibFlags & 0x0100) != 0) {
      throw const FormatException('Document Word .doc chiffré non pris en charge');
    }

    final prefers1Table = (fibFlags & 0x0200) != 0;
    final candidates = <Uint8List>[];
    final first = streams[prefers1Table ? '1Table' : '0Table'];
    final second = streams[prefers1Table ? '0Table' : '1Table'];
    if (first != null) candidates.add(first);
    if (second != null) candidates.add(second);

    String? best;
    double bestScore = -1;
    for (final table in candidates) {
      final extracted = _extractWordPieceTableText(word, table);
      if (extracted == null) continue;
      final normalized = _normalizeLegacyWordText(extracted);
      if (normalized.trim().isEmpty) continue;
      final score = _textQualityScore(normalized);
      if (score > bestScore) {
        bestScore = score;
        best = normalized;
      }
    }

    if (best == null || best.trim().length < 3 || bestScore < 0.55) {
      throw const FormatException(
        'Impossible d\'extraire un texte fiable du document Word .doc',
      );
    }
    return best.trim();
  }

  Map<String, Uint8List> _readOleCompoundStreams(
    Uint8List bytes,
    Set<String> wantedNames,
  ) {
    const freeSect = 0xFFFFFFFF;
    const endOfChain = 0xFFFFFFFE;
    const fatSect = 0xFFFFFFFD;
    const difSect = 0xFFFFFFFC;

    final majorVersion = _u16(bytes, 0x1A);
    final sectorShift = _u16(bytes, 0x1E);
    final miniSectorShift = _u16(bytes, 0x20);
    final sectorSize = 1 << sectorShift;
    final miniSectorSize = 1 << miniSectorShift;
    if ((sectorSize != 512 && sectorSize != 4096) ||
        miniSectorSize != 64) {
      throw const FormatException('Taille de secteur OLE non prise en charge');
    }

    final firstDirSector = _u32(bytes, 0x30);
    final miniCutoff = _u32(bytes, 0x38);
    final firstMiniFatSector = _u32(bytes, 0x3C);
    final numMiniFatSectors = _u32(bytes, 0x40);
    final firstDifatSector = _u32(bytes, 0x44);
    final numDifatSectors = _u32(bytes, 0x48);

    bool validSid(int sid) =>
        sid >= 0 && sid < 0xFFFFFFFA && ((sid + 1) * sectorSize) < bytes.length;

    Uint8List sector(int sid) {
      if (!validSid(sid)) {
        throw FormatException('Secteur OLE invalide: $sid');
      }
      final start = (sid + 1) * sectorSize;
      final end = math.min(start + sectorSize, bytes.length);
      return Uint8List.sublistView(bytes, start, end);
    }

    final fatSectorIds = <int>[];
    for (var i = 0; i < 109; i++) {
      final sid = _u32(bytes, 0x4C + i * 4);
      if (sid != freeSect && sid != endOfChain && sid != fatSect && sid != difSect) {
        fatSectorIds.add(sid);
      }
    }

    var difSid = firstDifatSector;
    final difVisited = <int>{};
    for (var d = 0;
        d < numDifatSectors && validSid(difSid) && difVisited.add(difSid);
        d++) {
      final data = sector(difSid);
      final entries = sectorSize ~/ 4;
      for (var i = 0; i < entries - 1; i++) {
        final sid = _u32(data, i * 4);
        if (sid != freeSect &&
            sid != endOfChain &&
            sid != fatSect &&
            sid != difSect) {
          fatSectorIds.add(sid);
        }
      }
      difSid = _u32(data, (entries - 1) * 4);
    }

    if (fatSectorIds.isEmpty) {
      throw const FormatException('Table FAT OLE absente');
    }

    final fat = <int>[];
    for (final sid in fatSectorIds) {
      final data = sector(sid);
      for (var i = 0; i + 4 <= data.length; i += 4) {
        fat.add(_u32(data, i));
      }
    }

    Uint8List readRegularChain(int startSid, {int? expectedSize}) {
      if (startSid == endOfChain || startSid == freeSect) return Uint8List(0);
      final out = BytesBuilder(copy: false);
      final visited = <int>{};
      var sid = startSid;
      while (sid != endOfChain && sid != freeSect) {
        if (sid < 0 || sid >= fat.length || !validSid(sid) || !visited.add(sid)) {
          throw const FormatException('Chaîne de secteurs OLE corrompue');
        }
        out.add(sector(sid));
        sid = fat[sid];
      }
      final data = out.takeBytes();
      if (expectedSize != null && expectedSize >= 0 && data.length > expectedSize) {
        return Uint8List.sublistView(data, 0, expectedSize);
      }
      return data;
    }

    final directoryBytes = readRegularChain(firstDirSector);
    final entries = <String, Map<String, int>>{};
    Map<String, int>? rootEntry;

    for (var off = 0; off + 128 <= directoryBytes.length; off += 128) {
      final nameLen = _u16(directoryBytes, off + 64);
      if (nameLen < 2 || nameLen > 64) continue;
      final type = directoryBytes[off + 66];
      final nameBytes = Uint8List.sublistView(
        directoryBytes,
        off,
        off + nameLen - 2,
      );
      final name = _decodeUtf16Le(nameBytes);
      final startSid = _u32(directoryBytes, off + 116);
      final sizeLow = _u32(directoryBytes, off + 120);
      final sizeHigh = majorVersion >= 4 ? _u32(directoryBytes, off + 124) : 0;
      final size = sizeLow + sizeHigh * 0x100000000;
      final meta = <String, int>{
        'type': type,
        'start': startSid,
        'size': size,
      };
      if (type == 5) rootEntry = meta;
      if (type == 2 && wantedNames.contains(name)) {
        entries[name] = meta;
      }
    }

    final miniFat = <int>[];
    if (numMiniFatSectors > 0 &&
        firstMiniFatSector != endOfChain &&
        firstMiniFatSector != freeSect) {
      final miniFatBytes = readRegularChain(
        firstMiniFatSector,
        expectedSize: numMiniFatSectors * sectorSize,
      );
      for (var i = 0; i + 4 <= miniFatBytes.length; i += 4) {
        miniFat.add(_u32(miniFatBytes, i));
      }
    }

    Uint8List rootMiniStream = Uint8List(0);
    if (rootEntry != null && rootEntry['size']! > 0) {
      rootMiniStream = readRegularChain(
        rootEntry['start']!,
        expectedSize: rootEntry['size']!,
      );
    }

    Uint8List readMiniChain(int startMiniSid, int expectedSize) {
      if (miniFat.isEmpty || rootMiniStream.isEmpty) {
        throw const FormatException('MiniFAT OLE requise mais absente');
      }
      final out = BytesBuilder(copy: false);
      final visited = <int>{};
      var sid = startMiniSid;
      while (sid != endOfChain && sid != freeSect && out.length < expectedSize) {
        if (sid < 0 || sid >= miniFat.length || !visited.add(sid)) {
          throw const FormatException('Chaîne MiniFAT OLE corrompue');
        }
        final start = sid * miniSectorSize;
        if (start >= rootMiniStream.length) {
          throw const FormatException('Mini-secteur OLE hors limites');
        }
        final end = math.min(start + miniSectorSize, rootMiniStream.length);
        out.add(Uint8List.sublistView(rootMiniStream, start, end));
        sid = miniFat[sid];
      }
      final data = out.takeBytes();
      return data.length > expectedSize
          ? Uint8List.sublistView(data, 0, expectedSize)
          : data;
    }

    final result = <String, Uint8List>{};
    for (final entry in entries.entries) {
      final meta = entry.value;
      final size = meta['size']!;
      if (size < 0 || size > 512 * 1024 * 1024) {
        throw const FormatException('Flux OLE de taille incohérente');
      }
      result[entry.key] = size < miniCutoff
          ? readMiniChain(meta['start']!, size)
          : readRegularChain(meta['start']!, expectedSize: size);
    }
    return result;
  }

  String? _extractWordPieceTableText(Uint8List word, Uint8List table) {
    String? best;
    double bestScore = -1;

    for (var i = 0; i + 5 <= table.length; i++) {
      if (table[i] != 0x02) continue;
      final lcb = _u32(table, i + 1);
      if (lcb < 16 || (lcb - 4) % 12 != 0 || i + 5 + lcb > table.length) {
        continue;
      }

      final pieceCount = (lcb - 4) ~/ 12;
      if (pieceCount <= 0 || pieceCount > 100000) continue;

      final cpStart = i + 5;
      final pcdStart = cpStart + (pieceCount + 1) * 4;
      if (pcdStart + pieceCount * 8 > i + 5 + lcb) continue;

      final cps = <int>[];
      var monotonic = true;
      for (var n = 0; n <= pieceCount; n++) {
        final cp = _u32(table, cpStart + n * 4);
        if (cps.isNotEmpty && cp < cps.last) {
          monotonic = false;
          break;
        }
        cps.add(cp);
      }
      if (!monotonic || cps.first != 0 || cps.last <= 0) continue;

      final out = StringBuffer();
      var valid = true;
      for (var n = 0; n < pieceCount; n++) {
        final charCount = cps[n + 1] - cps[n];
        if (charCount < 0 || charCount > 100000000) {
          valid = false;
          break;
        }

        final fcRaw = _u32(table, pcdStart + n * 8 + 2);
        final compressed = (fcRaw & 0x40000000) != 0;
        var fc = fcRaw & 0x3FFFFFFF;
        if (compressed) fc ~/= 2;

        final byteCount = compressed ? charCount : charCount * 2;
        if (fc < 0 || byteCount < 0 || fc + byteCount > word.length) {
          valid = false;
          break;
        }

        final piece = Uint8List.sublistView(word, fc, fc + byteCount);
        out.write(
          compressed ? _decodeWindows1252(piece) : _decodeUtf16Le(piece),
        );
      }

      if (!valid) continue;
      final text = out.toString();
      final score = _textQualityScore(text);
      if (text.trim().length >= 3 && score > bestScore) {
        bestScore = score;
        best = text;
      }
    }

    return best;
  }

  String _normalizeLegacyWordText(String input) {
    var text = input
        .replaceAll('\r', '\n')
        .replaceAll('\u0007', '\t')
        .replaceAll('\u000B', '\n')
        .replaceAll(RegExp(r'[\x00-\x06\x08\x0E-\x1F]'), '');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  double _textQualityScore(String text) {
    if (text.isEmpty) return 0;
    var good = 0;
    for (final rune in text.runes) {
      if (rune == 9 ||
          rune == 10 ||
          rune == 13 ||
          rune == 32 ||
          rune >= 0x20 && rune != 0x7F) {
        good++;
      }
    }
    return good / text.runes.length;
  }

  String _decodeUtf16Le(Uint8List bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  String _decodeWindows1252(Uint8List bytes) {
    const specials = <int, int>{
      0x80: 0x20AC,
      0x82: 0x201A,
      0x83: 0x0192,
      0x84: 0x201E,
      0x85: 0x2026,
      0x86: 0x2020,
      0x87: 0x2021,
      0x88: 0x02C6,
      0x89: 0x2030,
      0x8A: 0x0160,
      0x8B: 0x2039,
      0x8C: 0x0152,
      0x8E: 0x017D,
      0x91: 0x2018,
      0x92: 0x2019,
      0x93: 0x201C,
      0x94: 0x201D,
      0x95: 0x2022,
      0x96: 0x2013,
      0x97: 0x2014,
      0x98: 0x02DC,
      0x99: 0x2122,
      0x9A: 0x0161,
      0x9B: 0x203A,
      0x9C: 0x0153,
      0x9E: 0x017E,
      0x9F: 0x0178,
    };
    return String.fromCharCodes(
      bytes.map((b) => specials[b] ?? b),
    );
  }

  int _u16(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 2 > bytes.length) {
      throw const FormatException('Lecture binaire hors limites');
    }
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  int _u32(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) {
      throw const FormatException('Lecture binaire hors limites');
    }
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  /// Extracts text from a .docx ZIP archive.
  String _extractDocx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final docFile = archive.findFile('word/document.xml');
      if (docFile == null) {
        throw const FormatException('word/document.xml absent');
      }

      final xmlContent = utf8.decode(docFile.content as List<int>);
      final text = _extractXmlText(xmlContent).trim();
      if (text.isEmpty) {
        throw const FormatException('Document Word sans texte extractible');
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Lecture du document Word .docx impossible: $e');
    }
  }

  /// Extracts text from a .pptx ZIP archive.
  String _extractPptx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final buffer = StringBuffer();
      int slideIndex = 1;

      for (final file in archive.files) {
        if (file.name.startsWith('ppt/slides/slide') && file.name.endsWith('.xml')) {
          final xmlContent = utf8.decode(file.content as List<int>);
          final slideText = _extractXmlText(xmlContent);
          if (slideText.trim().isNotEmpty) {
            buffer.writeln('--- Diapositive $slideIndex ---');
            buffer.writeln(slideText);
            buffer.writeln();
            slideIndex++;
          }
        }
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) {
        throw const FormatException('Présentation PowerPoint sans texte extractible');
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Lecture du fichier PowerPoint .pptx impossible: $e');
    }
  }

  /// Extracts text from an .xlsx ZIP archive.
  String _extractXlsx(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final sharedStringsFile = archive.findFile('xl/sharedStrings.xml');
      final buffer = StringBuffer();

      if (sharedStringsFile != null) {
        final xmlContent = utf8.decode(sharedStringsFile.content as List<int>);
        final strings = _extractXmlTags(xmlContent, 't');
        if (strings.isNotEmpty) {
          buffer.writeln('--- Données et Chaînes du Tableur Excel ---');
          for (final s in strings) {
            buffer.writeln(s);
          }
        }
      }

      if (buffer.isEmpty) {
        // Fallback: scan sheet xmls
        for (final file in archive.files) {
          if (file.name.startsWith('xl/worksheets/sheet') && file.name.endsWith('.xml')) {
            final xmlContent = utf8.decode(file.content as List<int>);
            final sheetText = _extractXmlText(xmlContent);
            if (sheetText.trim().isNotEmpty) {
              buffer.writeln(sheetText);
            }
          }
        }
      }

      final text = buffer.toString().trim();
      if (text.isEmpty) {
        throw const FormatException('Feuille Excel sans texte extractible');
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Lecture du fichier Excel .xlsx impossible: $e');
    }
  }

  /// Accurate text extractor from PDF documents.
  String _extractPdfText(Uint8List bytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final text = PdfTextExtractor(document).extractText();
      if (text.trim().isNotEmpty) {
        return text.trim();
      }
      throw const FormatException(
        'Ce document PDF ne contient pas de texte sélectionnable',
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Extraction du document PDF impossible: $e');
    } finally {
      document?.dispose();
    }
  }

  /// Extracts text and structure from an .epub ZIP archive.
  String _extractEpub(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final buffer = StringBuffer();
      String? bookTitle;
      String? bookAuthor;

      // 1. Locate root OPF file from META-INF/container.xml
      String? opfPath;
      final containerFile = archive.findFile('META-INF/container.xml');
      if (containerFile != null) {
        final containerXml = utf8.decode(containerFile.content as List<int>);
        final match = RegExp(r'full-path="([^"]+)"').firstMatch(containerXml);
        if (match != null) {
          opfPath = match.group(1);
        }
      }

      // Ordered list of chapter file paths
      final chapterPaths = <String>[];

      if (opfPath != null) {
        final opfFile = archive.findFile(opfPath);
        if (opfFile != null) {
          final opfXml = utf8.decode(opfFile.content as List<int>);
          final opfDir = p.dirname(opfPath);

          // Extract metadata
          final titleMatch = RegExp(r'<dc:title[^>]*>([^<]+)<\/dc:title>', caseSensitive: false).firstMatch(opfXml);
          if (titleMatch != null) bookTitle = titleMatch.group(1)?.trim();

          final authorMatch = RegExp(r'<dc:creator[^>]*>([^<]+)<\/dc:creator>', caseSensitive: false).firstMatch(opfXml);
          if (authorMatch != null) bookAuthor = authorMatch.group(1)?.trim();

          // Map manifest id -> href
          final manifestMap = <String, String>{};
          final itemMatches = RegExp(r'<item\s+[^>]*id="([^"]+)"[^>]*href="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemMatches) {
            final id = m.group(1);
            final href = m.group(2);
            if (id != null && href != null) {
              manifestMap[id] = href;
            }
          }
          // Also try inverted attributes (href before id)
          final itemMatchesInv = RegExp(r'<item\s+[^>]*href="([^"]+)"[^>]*id="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemMatchesInv) {
            final href = m.group(1);
            final id = m.group(2);
            if (id != null && href != null && !manifestMap.containsKey(id)) {
              manifestMap[id] = href;
            }
          }

          // Follow spine reading order
          final itemrefMatches = RegExp(r'<itemref\s+[^>]*idref="([^"]+)"', caseSensitive: false).allMatches(opfXml);
          for (final m in itemrefMatches) {
            final idref = m.group(1);
            if (idref != null && manifestMap.containsKey(idref)) {
              final rawHref = Uri.decodeFull(manifestMap[idref]!);
              final fullHref = opfDir == '.' || opfDir.isEmpty ? rawHref : '$opfDir/$rawHref';
              // Normalize path separators
              final normalized = fullHref.replaceAll('\\', '/');
              if (!chapterPaths.contains(normalized)) {
                chapterPaths.add(normalized);
              }
            }
          }
        }
      }

      // Fallback: if spine parsing yielded no chapters, find all (x)html files in natural order
      if (chapterPaths.isEmpty) {
        for (final file in archive.files) {
          final low = file.name.toLowerCase();
          if ((low.endsWith('.xhtml') || low.endsWith('.html') || low.endsWith('.htm')) && !low.contains('toc.')) {
            chapterPaths.add(file.name);
          }
        }
      }

      // Write Header
      if (bookTitle != null || bookAuthor != null) {
        buffer.writeln('=== LIVRE EPUB : ${bookTitle ?? 'Sans titre'} ===');
        if (bookAuthor != null) buffer.writeln('Auteur : $bookAuthor');
        buffer.writeln();
      }

      int chapterIndex = 1;
      for (final path in chapterPaths) {
        ArchiveFile? file = archive.findFile(path);
        if (file == null) {
          // Try search without base dir
          final baseName = p.basename(path);
          for (final f in archive.files) {
            if (p.basename(f.name) == baseName) {
              file = f;
              break;
            }
          }
        }

        if (file != null) {
          String html;
          try {
            html = utf8.decode(file.content as List<int>);
          } catch (_) {
            html = latin1.decode(file.content as List<int>);
          }

          final cleanText = _cleanHtml(html);
          if (cleanText.trim().isNotEmpty) {
            buffer.writeln('--- Chapitre / Section $chapterIndex ---');
            buffer.writeln(cleanText.trim());
            buffer.writeln();
            chapterIndex++;
          }
        }
      }

      final text = buffer.toString().trim();
      if (text.isEmpty) {
        throw const FormatException('Livre EPUB sans contenu textuel exploitable');
      }
      return text;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Lecture du livre EPUB impossible: $e');
    }
  }

  /// Converts HTML / XHTML strings into clean readable Markdown/Text.
  String _cleanHtml(String html) {
    String text = html;

    // Remove script, style and head tags with their contents
    text = text.replaceAll(RegExp(r'<head[\s\S]*?<\/head>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<style[\s\S]*?<\/style>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'<script[\s\S]*?<\/script>', caseSensitive: false), '');

    // Format headers
    text = text.replaceAllMapped(RegExp(r'<h[1-2][^>]*>([\s\S]*?)<\/h[1-2]>', caseSensitive: false), (m) => '\n\n## ${_stripTags(m.group(1) ?? '')}\n\n');
    text = text.replaceAllMapped(RegExp(r'<h[3-6][^>]*>([\s\S]*?)<\/h[3-6]>', caseSensitive: false), (m) => '\n\n### ${_stripTags(m.group(1) ?? '')}\n\n');

    // Paragraphs and breaks
    text = text.replaceAll(RegExp(r'<\/?(p|div|section|article|blockquote)[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    text = text.replaceAll(RegExp(r'<\/li>', caseSensitive: false), '\n');

    // Strip remaining tags
    text = _stripTags(text);

    // Unescape common HTML & XML entities
    text = _decodeHtmlEntities(text);

    // Normalize whitespaces and blank lines
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return text.trim();
  }

  String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '');

  String _decodeHtmlEntities(String input) {
    var out = input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&laquo;', '«')
        .replaceAll('&raquo;', '»')
        .replaceAll('&hellip;', '...')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&eacute;', 'é')
        .replaceAll('&Eacute;', 'É')
        .replaceAll('&egrave;', 'è')
        .replaceAll('&Egrave;', 'È')
        .replaceAll('&agrave;', 'à')
        .replaceAll('&Agrave;', 'À')
        .replaceAll('&ccedil;', 'ç')
        .replaceAll('&Ccedil;', 'Ç')
        .replaceAll('&ecirc;', 'ê')
        .replaceAll('&Ecirc;', 'Ê')
        .replaceAll('&icirc;', 'î')
        .replaceAll('&Icirc;', 'Î')
        .replaceAll('&ocirc;', 'ô')
        .replaceAll('&Ocirc;', 'Ô')
        .replaceAll('&ucirc;', 'û')
        .replaceAll('&Ucirc;', 'Û')
        .replaceAll('&euml;', 'ë')
        .replaceAll('&Euml;', 'Ë')
        .replaceAll('&iuml;', 'ï')
        .replaceAll('&Iuml;', 'Ï')
        .replaceAll('&uuml;', 'ü')
        .replaceAll('&Uuml;', 'Ü')
        .replaceAll('&deg;', '°')
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®');

    // Numeric decimal entities &#123;
    out = out.replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    // Numeric hex entities &#x1F600;
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });

    return out;
  }

  /// Strips XML tags and joins textual content with clean linebreaks.
  String _extractXmlText(String xml) {
    final textTags = RegExp(r'<[^>]+>([^<]+)<\/[^>]+>');
    final buffer = StringBuffer();
    final matches = textTags.allMatches(xml);

    for (final match in matches) {
      final text = match.group(1)?.trim();
      if (text != null && text.isNotEmpty) {
        buffer.write('$text ');
      }
    }
    return buffer.toString().trim();
  }

  /// Extracts content of specific XML tag names.
  List<String> _extractXmlTags(String xml, String tagName) {
    final regex = RegExp('<(?:[a-zA-Z0-9_]+:)?$tagName(?:\\s+[^>]*)?>([\\s\\S]*?)<\\/(?:[a-zA-Z0-9_]+:)?$tagName>');
    return regex.allMatches(xml).map((m) => m.group(1)?.trim() ?? '').where((s) => s.isNotEmpty).toList();
  }
}

