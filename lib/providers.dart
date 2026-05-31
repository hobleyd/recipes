import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'epub_service.dart';
import 'models.dart';
import 'ocr_service.dart';

class EpubPathNotifier extends AsyncNotifier<String?> {
  static const _key = 'epub_path';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, path);
    state = AsyncValue.data(path);
  }

  Future<void> clearPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    state = const AsyncValue.data(null);
  }
}

final epubPathProvider =
    AsyncNotifierProvider<EpubPathNotifier, String?>(() => EpubPathNotifier());

final epubPagesProvider = FutureProvider<List<EpubPage>>((ref) async {
  final path = await ref.watch(epubPathProvider.future);
  if (path == null) return [];
  return EpubService(path).loadPages();
});

class OcrSettingsNotifier extends AsyncNotifier<OcrSettings> {
  @override
  Future<OcrSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return OcrSettings(
      claudeApiKey: prefs.getString('ocr_claude_key') ?? '',
      ollamaUrl:
          prefs.getString('ocr_ollama_url') ?? 'http://localhost:11434',
      ollamaModel:
          prefs.getString('ocr_ollama_model') ?? 'llama3.2-vision',
      preferred: OcrBackend.values.firstWhere(
        (b) => b.name == (prefs.getString('ocr_preferred') ?? ''),
        orElse: () => OcrBackend.ollama,
      ),
    );
  }

  Future<void> save(OcrSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ocr_claude_key', settings.claudeApiKey);
    await prefs.setString('ocr_ollama_url', settings.ollamaUrl);
    await prefs.setString('ocr_ollama_model', settings.ollamaModel);
    await prefs.setString('ocr_preferred', settings.preferred.name);
    state = AsyncValue.data(settings);
  }
}

final ocrSettingsProvider =
    AsyncNotifierProvider<OcrSettingsNotifier, OcrSettings>(
        () => OcrSettingsNotifier());
