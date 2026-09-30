import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:jarvisol/services/ai_knowledge_service.dart';
import 'package:jarvisol/services/document_rag_service.dart';
import 'package:jarvisol/services/document_source_service.dart';
import 'package:jarvisol/services/embedding_provider.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/services/startup_recovery_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FIX6 — safety and regression gates', () {
    test('RAG custom folder never deletes or quarantines foreign JSON; audio/image cache persists', () async {
      final dir = Directory.systemTemp.createTempSync('jarvisol_fix6_rag_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.ragCacheDirectory = dir.path;

      final foreign = File(p.join(dir.path, 'foreign.json'))
        ..writeAsStringSync('{ not valid json');
      final unrelated = File(p.join(dir.path, 'notes.json'))
        ..writeAsStringSync(jsonEncode({'hello': 'world'}));

      final rag = DocumentRagService();
      const cfg = EmbeddingProviderConfig(
        provider: EmbeddingProvider.lmStudio,
        modelId: 'fix6-model',
        dimension: 3,
        endpoint: 'http://127.0.0.1:1234/v1',
      );

      Future<void> save(String source, String content) async {
        final chunks = [
          DocumentChunk(
            id: '$source-0',
            sourceName: source,
            sourceType: source.endsWith('.wav') ? 'audio' : 'image',
            text: content,
            wordCount: content.split(' ').length,
            embedding: const [0.1, 0.2, 0.3],
          ),
        ];
        await rag.saveChunksToCache(
          sourceName: source,
          content: content,
          embConfig: cfg,
          chunks: chunks,
          settings: settings,
        );
      }

      await save('fixture.wav', 'transcription audio marqueur FIX6 AUDIO');
      await save('fixture.png', 'texte OCR marqueur FIX6 IMAGE');

      final listed = await rag.listCachedDocuments(settings);
      expect(listed.length, 2);
      expect(foreign.existsSync(), isTrue);
      expect(File('${foreign.path}.corrupt').existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);

      final deleted = await rag.clearCache(settings);
      expect(deleted, 2);
      expect(foreign.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
    });

    test('AI Knowledge purge only removes Jarvisol records from a custom folder', () async {
      final dir = Directory.systemTemp.createTempSync('jarvisol_fix6_ai_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      PortablePreferences.resetForTesting();
      final prefs = await PortablePreferences.getInstance();
      final settings = SettingsService(prefs);
      settings.aiKnowledgeDirectory = dir.path;

      final container = ProviderContainer(overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ]);
      addTearDown(container.dispose);

      final foreign = File(p.join(dir.path, 'foreign.json'))
        ..writeAsStringSync(jsonEncode({'external': true}));
      final service = container.read(aiKnowledgeServiceProvider);
      await service.saveRecord(
        title: 'FIX6',
        rawTranscript: 'JARVISOL FIX6 KNOWLEDGE',
      );

      expect((await service.listRecords()).length, 1);
      final deleted = await service.clearAllRecords();
      expect(deleted, 1);
      expect(foreign.existsSync(), isTrue);
      expect((await service.listRecords()).isEmpty, isTrue);
    });

    test('legacy .doc binary text is extracted and corrupt PDF fails instead of becoming a fake source', () async {
      final service = DocumentSourceService();
      final fixture = File('test/fixtures/fix6_legacy_word.doc');
      expect(fixture.existsSync(), isTrue);

      final doc = await service.parseFile(fixture.path);
      expect(doc.type, 'doc');
      expect(doc.textContent, contains('JARVISOL_IMPORT_DOC_001'));
      expect(doc.textContent, contains('phrase temoin'));

      final badPdf = File('${Directory.systemTemp.path}/jarvisol_fix6_bad.pdf')
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 0x2D, 0x42, 0x41, 0x44]);
      addTearDown(() {
        if (badPdf.existsSync()) badPdf.deleteSync();
      });

      await expectLater(
        service.parseFile(badPdf.path),
        throwsA(anything),
      );
    });

    test('interrupted preferences swap is restored before normal startup continues', () async {
      final dir = Directory.systemTemp.createTempSync('jarvisol_fix6_recovery_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final swap = File(p.join(dir.path, StartupRecoveryService.recoverySwapFileName));
      swap.writeAsStringSync('{"keep":"original"}');
      final prefs = File(p.join(dir.path, StartupRecoveryService.preferencesFileName));
      expect(prefs.existsSync(), isFalse);

      final result = await StartupRecoveryService.checkAndRecover(targetDataDir: dir);
      expect(result.status, StartupRecoveryStatus.noRecoveryNeeded);
      expect(prefs.readAsStringSync(), '{"keep":"original"}');
      expect(swap.existsSync(), isFalse);
    });
  });
}
