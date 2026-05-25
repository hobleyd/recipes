import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epub_service.dart';
import 'models.dart';

final epubPagesProvider = FutureProvider<List<EpubPage>>((ref) {
  return EpubService().loadPages();
});
