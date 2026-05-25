import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'epub_service.dart';
import 'models.dart';

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
