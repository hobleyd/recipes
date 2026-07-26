import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recipe_manager/epub_service.dart';
import 'package:recipe_manager/models.dart';

// Rewrites a navPoint's id in toc.ncx to a UUID-style id, mimicking a recipe
// originally imported from Calibre rather than added through this app.
Future<void> _givePageAUuidNavId(String path, String filename) async {
  final bytes = await File(path).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final fileMap = <String, List<int>>{};
  for (final f in archive.files) {
    if (f.isFile) fileMap[f.name] = f.content as List<int>;
  }

  var toc = utf8.decode(fileMap['OEBPS/toc.ncx']!);
  toc = toc.replaceFirst(
      'id="u$filename"', 'id="u6efa6a91-633f-48f4-80b1-08913623279d"');
  fileMap['OEBPS/toc.ncx'] = utf8.encode(toc);

  final newArchive = Archive();
  final mimetypeBytes = fileMap.remove('mimetype');
  if (mimetypeBytes != null) {
    final mf = ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
    mf.compression = CompressionType.none;
    newArchive.addFile(mf);
  }
  for (final entry in fileMap.entries) {
    newArchive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  await File(path).writeAsBytes(ZipEncoder().encode(newArchive)!);
}

void main() {
  group('EpubService.updateRecipe', () {
    late Directory tempDir;
    late String path;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_service_test');
      path = '${tempDir.path}/cookbook.epub';
      await EpubService.createCookbook(path: path, title: 'Test Cookbook');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('renames the recipe in the page list when the navPoint id is filename-based', () async {
      final pages = await EpubService(path).loadPages();
      final indexPage = pages.firstWhere((p) => p.title == 'Contents');

      await EpubService(path).saveRecipe(
        title: 'Old Title',
        description: '<p>desc</p>',
        ingredientSections: [
          IngredientSection(label: '', ingredients: [Ingredient(name: 'x')])
        ],
        method: '<p>method</p>',
        footnote: '',
        insertAfterPage: indexPage,
      );

      final saved = await EpubService(path).loadPages();
      final recipePage = saved.firstWhere((p) => p.title == 'Old Title');

      await EpubService(path).updateRecipe(
        page: recipePage,
        title: 'New Title',
        description: '<p>desc</p>',
        ingredientSections: [
          IngredientSection(label: '', ingredients: [Ingredient(name: 'x')])
        ],
        method: '<p>method</p>',
        footnote: '',
      );

      final reloaded = await EpubService(path).loadPages();
      expect(reloaded.any((p) => p.title == 'New Title'), isTrue);
      expect(reloaded.any((p) => p.title == 'Old Title'), isFalse);
    });

    test('renames the recipe in the page list when the navPoint id is a Calibre-style UUID', () async {
      // Regression test: recipes imported from Calibre keep their original
      // UUID navPoint id rather than the "u$filename" id this app assigns to
      // recipes it creates. Renaming such a recipe must still update its
      // toc.ncx entry — otherwise the app's own recipe list (built from
      // toc.ncx) keeps showing the old title even though the recipe's own
      // content page was updated.
      final pages = await EpubService(path).loadPages();
      final indexPage = pages.firstWhere((p) => p.title == 'Contents');

      await EpubService(path).saveRecipe(
        title: 'Beef Burger',
        description: '<p>desc</p>',
        ingredientSections: [
          IngredientSection(label: '', ingredients: [Ingredient(name: 'x')])
        ],
        method: '<p>method</p>',
        footnote: '',
        insertAfterPage: indexPage,
      );

      await _givePageAUuidNavId(path, 'beefburger');

      final saved = await EpubService(path).loadPages();
      final recipePage = saved.firstWhere((p) => p.title == 'Beef Burger');

      await EpubService(path).updateRecipe(
        page: recipePage,
        title: 'Beef Burgers',
        description: '<p>desc</p>',
        ingredientSections: [
          IngredientSection(label: '', ingredients: [Ingredient(name: 'x')])
        ],
        method: '<p>method</p>',
        footnote: '',
      );

      final reloaded = await EpubService(path).loadPages();
      expect(reloaded.any((p) => p.title == 'Beef Burgers'), isTrue);
      expect(reloaded.any((p) => p.title == 'Beef Burger'), isFalse);
    });
  });
}
