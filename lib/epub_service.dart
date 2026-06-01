import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'models.dart';

class EpubService {
  final String epubPath;

  EpubService(this.epubPath);

  Future<List<EpubPage>> loadPages() async {
    final bytes = await File(epubPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    return _parsePages(archive);
  }

  List<EpubPage> _parsePages(Archive archive) {
    final opfContent = _readText(archive, 'OEBPS/content.opf');

    // Manifest: id → href, and reverse href → id
    final manifestMap = <String, String>{};
    final itemRe = RegExp(
        r'<item\s[^>]*\bid="([^"]+)"[^>]*\bhref="([^"]+)"', dotAll: true);
    for (final m in itemRe.allMatches(opfContent)) {
      manifestMap[m.group(1)!] = m.group(2)!;
    }
    final hrefToId = {for (final e in manifestMap.entries) e.value: e.key};

    // Parse toc.ncx in document order
    final tocContent = _readText(archive, 'OEBPS/toc.ncx');
    final navRe = RegExp(
      r'<navPoint[^>]*>.*?<text>([^<]+)</text>.*?<content\s+src="([^"]+)"',
      dotAll: true,
    );
    final navEntries = navRe
        .allMatches(tocContent)
        .map((m) => (title: _unescXml(m.group(1)!.trim()), src: m.group(2)!))
        .toList();

    // Identify chapter markers by INDEX, not src.  Two consecutive navPoints
    // can share the same src (no fragment) when a recipe was added via
    // saveRecipe — using the index ensures only the first (the real chapter
    // header) is skipped; the second is treated as a normal recipe entry.
    final chapterMarkerAt = <int, String>{}; // navEntry index → chapter title
    for (int i = 0; i < navEntries.length - 1; i++) {
      final cur = navEntries[i].src;
      final next = navEntries[i + 1].src;
      if (!cur.contains('#') && (
          (next.contains('#') && next.split('#').first == cur) ||
          (!next.contains('#') && next == cur))) {
        chapterMarkerAt[i] = navEntries[i].title;
      }
    }

    // Build pages in toc order, tracking the current chapter.
    // Skip chapter marker entries themselves and duplicate base-file refs.
    final pages = <EpubPage>[];
    final seenHrefs = <String>{};
    String? currentChapter;

    for (int i = 0; i < navEntries.length; i++) {
      final entry = navEntries[i];
      final hasFragment = entry.src.contains('#');
      final baseSrc = hasFragment ? entry.src.split('#').first : entry.src;

      if (chapterMarkerAt.containsKey(i)) {
        currentChapter = chapterMarkerAt[i];
        continue; // chapter marker — don't add as a standalone page
      }

      if (seenHrefs.contains(baseSrc)) continue;
      seenHrefs.add(baseSrc);

      pages.add(EpubPage(
        id: hrefToId[baseSrc] ?? '',
        href: baseSrc,
        title: entry.title,
        chapter: currentChapter,
      ));
    }

    return pages;
  }

  Future<void> saveRecipe({
    required String title,
    required String description,
    required List<IngredientSection> ingredientSections,
    required String method,
    required String footnote,
    required EpubPage insertAfterPage,
  }) async {
    final file = File(epubPath);
    await file.copy('$epubPath.old');

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Load all archive files into a mutable map (name → bytes)
    final fileMap = <String, List<int>>{};
    for (final f in archive.files) {
      if (f.isFile) {
        fileMap[f.name] = f.content as List<int>;
      }
    }

    // Determine filename, handle duplicates
    var filename = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    var n = 2;
    while (fileMap.containsKey('OEBPS/Text/$filename.xhtml')) {
      filename = '${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}$n';
      n++;
    }
    final fileId = '$filename.xhtml';

    final hasFootnote = footnote.trim().isNotEmpty;
    int? footnoteNum;
    if (hasFootnote) {
      final attrContent = utf8.decode(fileMap['OEBPS/Text/attributions.xhtml']!);
      final re = RegExp(r'id="footnote-(\d+)"');
      int max = 0;
      for (final m in re.allMatches(attrContent)) {
        final v = int.tryParse(m.group(1)!) ?? 0;
        if (v > max) max = v;
      }
      footnoteNum = max + 1;
    }

    // Determine anchor number from HTML TOC
    final htmlTocRaw = utf8.decode(fileMap['OEBPS/Text/index_split_001.xhtml']!);
    final anchorRe = RegExp(r'#anchor(\d+)');
    int maxAnchor = 0;
    for (final m in anchorRe.allMatches(htmlTocRaw)) {
      final v = int.tryParse(m.group(1)!) ?? 0;
      if (v > maxAnchor) maxAnchor = v;
    }
    final anchorNum = maxAnchor + 1;

    // 1. New recipe XHTML
    fileMap['OEBPS/Text/$filename.xhtml'] = utf8.encode(_buildRecipeXhtml(
      title: title,
      description: description,
      ingredientSections: ingredientSections,
      method: method,
      footnote: hasFootnote ? footnote.trim() : null,
      filename: filename,
      footnoteNum: footnoteNum,
      anchorNum: anchorNum,
    ));

    // 2. Update content.opf
    var opf = utf8.decode(fileMap['OEBPS/content.opf']!);
    opf = opf.replaceFirst(
      '</manifest>',
      '    <item id="$fileId" href="Text/$filename.xhtml"'
          ' media-type="application/xhtml+xml"/>\n  </manifest>',
    );
    final idEsc = RegExp.escape(insertAfterPage.id);
    final itemrefRe = RegExp('<itemref\\s+idref="$idEsc"\\s*/>');
    final itemrefMatch = itemrefRe.firstMatch(opf);
    if (itemrefMatch != null) {
      opf = opf.replaceFirst(
        itemrefMatch.group(0)!,
        '${itemrefMatch.group(0)!}\n    <itemref idref="$fileId"/>',
      );
    } else {
      opf = opf.replaceFirst(
          '</spine>', '    <itemref idref="$fileId"/>\n  </spine>');
    }
    fileMap['OEBPS/content.opf'] = utf8.encode(opf);

    // 3. Update toc.ncx
    var toc = utf8.decode(fileMap['OEBPS/toc.ncx']!);
    final playOrderRe = RegExp(r'playOrder="(\d+)"');
    int maxOrder = 0;
    for (final m in playOrderRe.allMatches(toc)) {
      final v = int.tryParse(m.group(1)!) ?? 0;
      if (v > maxOrder) maxOrder = v;
    }
    final newNavPoint =
        '    <navPoint id="u$filename" playOrder="${maxOrder + 1}">\n'
        '      <navLabel>\n'
        '        <text>${_escXml(title)}</text>\n'
        '      </navLabel>\n'
        '      <content src="Text/$filename.xhtml#anchor$anchorNum"/>\n'
        '    </navPoint>';
    final insertFile = insertAfterPage.href.split('/').last;
    final lastSrcIdx = toc.lastIndexOf('src="Text/$insertFile');
    bool tocInserted = false;
    if (lastSrcIdx >= 0) {
      final closeIdx = toc.indexOf('</navPoint>', lastSrcIdx);
      if (closeIdx >= 0) {
        final pos = closeIdx + '</navPoint>'.length;
        toc = '${toc.substring(0, pos)}\n$newNavPoint${toc.substring(pos)}';
        tocInserted = true;
      }
    }
    if (!tocInserted) {
      toc = toc.replaceFirst('</navMap>', '$newNavPoint\n  </navMap>');
    }
    fileMap['OEBPS/toc.ncx'] = utf8.encode(toc);

    // 4. Update attributions.xhtml
    if (hasFootnote && footnoteNum != null) {
      var attr = utf8.decode(fileMap['OEBPS/Text/attributions.xhtml']!);
      final footnoteBody = _footnoteHtml(footnote.trim());
      final section = '\n<section>\n'
          '  <p class="footnote" id="footnote-$footnoteNum">'
          '<a href="$filename.xhtml#citation-$footnoteNum"'
          ' class="calibre8">*</a>'
          ' $footnoteBody</p>\n'
          '</section>\n';
      attr = attr.replaceFirst('</body>', '$section\n</body>');
      fileMap['OEBPS/Text/attributions.xhtml'] = utf8.encode(attr);
    }

    // 5. Update index_split_001.xhtml (HTML table of contents)
    fileMap['OEBPS/Text/index_split_001.xhtml'] = utf8.encode(
      _updateHtmlToc(
        toc: htmlTocRaw,
        title: title,
        filename: filename,
        insertAfterFilename: insertAfterPage.filename,
        anchorNum: anchorNum,
      ),
    );

    // Build new archive: mimetype first + uncompressed, rest compressed
    final newArchive = Archive();
    final mimetypeBytes = fileMap.remove('mimetype');
    if (mimetypeBytes != null) {
      final mf = ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
      mf.compress = false;
      newArchive.addFile(mf);
    }
    for (final entry in fileMap.entries) {
      newArchive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value));
    }

    final encoded = ZipEncoder().encode(newArchive)!;
    await file.writeAsBytes(encoded);
  }

  // ── XHTML generation ───────────────────────────────────────────────────────

  String _buildChapterXhtml(String title) => '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">

<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>Hobley Family Recipes</title>
  <link href="../Styles/page_styles.css" rel="stylesheet" type="text/css"/>
  <link href="../Styles/stylesheet.css" rel="stylesheet" type="text/css"/>
</head>

<body>
  <h1 class="title">${_escXml(title)}</h1>
</body>
</html>''';

  String _buildRecipeXhtml({
    required String title,
    required String description,
    required List<IngredientSection> ingredientSections,
    required String method,
    required String? footnote,
    required String filename,
    required int? footnoteNum,
    required int anchorNum,
  }) {
    final citation = (footnote != null && footnoteNum != null)
        ? '\n<sup class="calibre2"><a href="attributions.xhtml#footnote-$footnoteNum"'
            ' id="citation-$footnoteNum" class="citation">*</a></sup>'
        : '';

    final descHtml = _toParagraphs(description);
    final methodHtml = _toParagraphs(method);
    final tablesHtml = _buildTablesHtml(ingredientSections);

    return '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">

<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>Hobley Family Recipes</title>
  <link href="../Styles/page_styles.css" rel="stylesheet" type="text/css"/>
  <link href="../Styles/stylesheet.css" rel="stylesheet" type="text/css"/>
</head>

<body>
  <h2 class="recipe-title"><span id="anchor$anchorNum" class="calibre1"></span>${_escXml(title)}$citation</h2>

$descHtml$tablesHtml
$methodHtml</body>
</html>''';
  }

  String _buildTablesHtml(List<IngredientSection> sections) {
    final sb = StringBuffer();
    for (final section in sections) {
      if (section.label.isNotEmpty) {
        sb.write('  <h3 class="recipe-part">${_escXml(section.label)}</h3>\n\n');
      }
      final rows = _ingredientRows(section.ingredients);
      sb.write('  <table class="recipe-table">\n\n'
          '    <thead>\n\n'
          '      <tr>\n'
          '        <th class="col-ingredients">Ingredients</th>\n'
          '        <th class="col-measure">I</th>\n'
          '        <th class="col-measure">M</th>\n'
          '        <th class="col-ingredients">Ingredients</th>\n'
          '        <th class="col-measure">I</th>\n'
          '        <th class="col-measure">M</th>\n'
          '      </tr>\n\n'
          '    </thead>\n\n'
          '    <tbody>\n\n'
          '$rows'
          '    </tbody>\n\n'
          '  </table>\n\n');
    }
    return sb.toString();
  }

  String _toParagraphs(String text) {
    final paras = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paras.isEmpty) return '';
    return '${paras.map((p) => '  <p>${_escXml(p)}</p>').join('\n\n')}\n';
  }

  String _ingredientRows(List<Ingredient> ingredients) {
    if (ingredients.isEmpty) return '';
    final sb = StringBuffer();
    for (var i = 0; i < ingredients.length; i += 2) {
      final l = ingredients[i];
      final r = i + 1 < ingredients.length ? ingredients[i + 1] : null;
      sb.write('      <tr>\n');
      sb.write(
          '        <td class="col-ingredients">${_escXml(l.name)}</td>\n');
      sb.write(l.imperial.isNotEmpty
          ? '        <td class="col-measure">${_escXml(l.imperial)}</td>\n'
          : '        <td></td>\n');
      sb.write(l.metric.isNotEmpty
          ? '        <td class="col-measure">${_escXml(l.metric)}</td>\n'
          : '        <td></td>\n');
      if (r != null) {
        sb.write(
            '        <td class="col-ingredients">${_escXml(r.name)}</td>\n');
        sb.write(r.imperial.isNotEmpty
            ? '        <td class="col-measure">${_escXml(r.imperial)}</td>\n'
            : '        <td></td>\n');
        sb.write(r.metric.isNotEmpty
            ? '        <td class="col-measure">${_escXml(r.metric)}</td>\n'
            : '        <td></td>\n');
      } else {
        sb.write('        <td></td>\n        <td></td>\n        <td></td>\n');
      }
      sb.write('      </tr>\n\n');
    }
    return sb.toString();
  }

  // ── HTML TOC ───────────────────────────────────────────────────────────────

  String _updateHtmlToc({
    required String toc,
    required String title,
    required String filename,
    required String insertAfterFilename,
    required int anchorNum,
  }) {
    final newEntry = '\n  <p class="p-p3">'
        '<a href="$filename.xhtml#anchor$anchorNum" class="calibre1">'
        ' ${_escXml(title)}</a></p>';

    // Find the last paragraph that links to insertAfterFilename
    final searchStr = 'href="$insertAfterFilename.xhtml';
    final matchIdx = toc.lastIndexOf(searchStr);
    if (matchIdx < 0) {
      return toc.replaceFirst('</body>', '$newEntry\n</body>');
    }

    // Locate the enclosing <p> element
    final pStart = toc.lastIndexOf('<p ', matchIdx);
    final pEnd = toc.indexOf('</p>', matchIdx);
    if (pStart < 0 || pEnd < 0) {
      return toc.replaceFirst('</body>', '$newEntry\n</body>');
    }

    // Extract the existing number prefix and class
    final pText = toc.substring(pStart, pEnd + 4);
    final numMatch = RegExp(r'<p class="(p-p\d)">([\d.]*)').firstMatch(pText);
    final pClass = numMatch?.group(1) ?? 'p-p3';
    final currentNum = numMatch?.group(2) ?? '';
    final nextNum = _nextTocNumber(toc, pClass, currentNum);

    final newEntryWithNum = '\n  <p class="p-p3">$nextNum'
        '<a href="$filename.xhtml#anchor$anchorNum" class="calibre1">'
        ' ${_escXml(title)}</a></p>';

    return toc.substring(0, pEnd + 4) +
        newEntryWithNum +
        toc.substring(pEnd + 4);
  }

  String _nextTocNumber(String toc, String pClass, String currentNum) {
    if (currentNum.isEmpty) return '';
    final parts = currentNum.split('.').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';

    if (pClass == 'p-p3') {
      // Recipe entry like "6.7." → "6.8."
      final last = int.tryParse(parts.last) ?? 0;
      parts[parts.length - 1] = '${last + 1}';
      return '${parts.join('.')}.';
    } else {
      // Section entry like "6." → find max sub-number and use next
      final sectionNum = RegExp.escape(parts.first);
      final subRe = RegExp('<p class="p-p3">$sectionNum\\.(\\d+)\\.');
      int maxSub = 0;
      for (final m in subRe.allMatches(toc)) {
        final v = int.tryParse(m.group(1)!) ?? 0;
        if (v > maxSub) maxSub = v;
      }
      return '${parts.first}.${maxSub + 1}.';
    }
  }

  // ── Load / update existing recipe ─────────────────────────────────────────

  Future<RecipeData> loadRecipe(EpubPage page) async {
    final bytes = await File(epubPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final f = archive.findFile('OEBPS/${page.href}');
    if (f == null) throw Exception('OEBPS/${page.href} not found in EPUB');
    return _parseRecipeXhtml(utf8.decode(f.content as List<int>), archive: archive);
  }

  RecipeData _parseRecipeXhtml(String xhtml, {required Archive archive}) {
    final anchorNum = int.tryParse(
          RegExp(r'id="anchor(\d+)"').firstMatch(xhtml)?.group(1) ?? '') ??
        1;

    final footnoteNum = int.tryParse(
        RegExp(r'href="attributions\.xhtml#footnote-(\d+)"')
                .firstMatch(xhtml)
                ?.group(1) ??
            '');

    // Extract title: take the full h2 content, strip citation <sup>, strip all
    // tags, then decode entities and strip any entity-encoded tags from prior
    // corrupt saves (where trailing <a> anchors were captured as title text).
    final h2Match =
        RegExp(r'<h2[^>]*>(.*?)</h2>', dotAll: true).firstMatch(xhtml);
    var h2Inner = h2Match?.group(1) ?? '';
    h2Inner = h2Inner.replaceAll(
        RegExp(r'<sup[^>]*>.*?</sup>', dotAll: true), '');
    h2Inner = h2Inner.replaceAll(RegExp(r'<[^>]+>'), '');
    final decoded = _unescXml(h2Inner.trim());
    final title = decoded.replaceAll(RegExp(r'<[^>]+>'), '').trim();

    final h2End = xhtml.indexOf('</h2>');
    final bodyEnd = xhtml.lastIndexOf('</body>');
    final body = h2End >= 0 && bodyEnd > h2End
        ? xhtml.substring(h2End + 5, bodyEnd).trim()
        : '';

    final firstTableOrH3 = RegExp(r'<(?:table|h3)\b').firstMatch(body);
    final lastTableEnd = body.lastIndexOf('</table>');

    final description = _parseParagraphs(firstTableOrH3 != null
        ? body.substring(0, firstTableOrH3.start)
        : (lastTableEnd < 0 ? body : ''));

    final method = _parseParagraphs(
        lastTableEnd >= 0 ? body.substring(lastTableEnd + 8) : '');

    final sections = <IngredientSection>[];
    if (firstTableOrH3 != null && lastTableEnd >= 0) {
      final tableSection =
          body.substring(firstTableOrH3.start, lastTableEnd + 8);
      final tableRe =
          RegExp(r'<table\b[^>]*>.*?</table>', dotAll: true);
      final h3Re = RegExp(r'<h3[^>]*>(.*?)</h3>', dotAll: true);
      var pos = 0;
      for (final tm in tableRe.allMatches(tableSection)) {
        final between = tableSection.substring(pos, tm.start);
        final h3 = h3Re.allMatches(between).lastOrNull;
        final label = h3 != null ? _unescXml(h3.group(1)!.trim()) : '';
        sections.add(IngredientSection(
          label: label,
          ingredients: _parseTableIngredients(tm.group(0)!),
        ));
        pos = tm.end;
      }
    }
    if (sections.isEmpty) {
      sections.add(IngredientSection(ingredients: []));
    }

    String footnote = '';
    if (footnoteNum != null) {
      try {
        final attrContent = _readText(archive, 'OEBPS/Text/attributions.xhtml');
        final fnMatch = RegExp(
          'id="footnote-$footnoteNum"[^>]*>.*?</a>\\s*(.*?)\\s*</p>',
          dotAll: true,
        ).firstMatch(attrContent);
        if (fnMatch != null) {
          final content = fnMatch.group(1)!.trim();
          final hrefMatch = RegExp(r'<a\s+href="([^"]+)"').firstMatch(content);
          footnote = hrefMatch != null
              ? hrefMatch.group(1)!
              : _unescXml(content);
        }
      } catch (_) {}
    }

    return RecipeData(
      title: title,
      description: description,
      ingredientSections: sections,
      method: method,
      footnote: footnote,
      anchorNum: anchorNum,
      footnoteNum: footnoteNum,
    );
  }

  String _parseParagraphs(String html) {
    final paras = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true)
        .allMatches(html)
        .map((m) => _unescXml(m.group(1)!.trim()))
        .where((t) => t.isNotEmpty)
        .toList();
    return paras.join('\n\n');
  }

  List<Ingredient> _parseTableIngredients(String tableHtml) {
    final ingredients = <Ingredient>[];
    final tdRe = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true);
    final rowRe = RegExp(r'<tr\b[^>]*>(.*?)</tr>', dotAll: true);
    for (final row in rowRe.allMatches(tableHtml)) {
      final tds = tdRe
          .allMatches(row.group(1)!)
          .map((m) => _unescXml(m.group(1)!.trim()))
          .toList();
      if (tds.length < 3) continue;
      if (tds[0].isNotEmpty) {
        ingredients.add(Ingredient(
            name: tds[0],
            imperial: tds[1],
            metric: tds[2]));
      }
      if (tds.length >= 6 && tds[3].isNotEmpty) {
        ingredients.add(Ingredient(
            name: tds[3],
            imperial: tds[4],
            metric: tds[5]));
      }
    }
    return ingredients;
  }

  Future<void> updateRecipe({
    required EpubPage page,
    required String title,
    required String description,
    required List<IngredientSection> ingredientSections,
    required String method,
    required String footnote,
  }) async {
    final file = File(epubPath);
    await file.copy('$epubPath.old');

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final fileMap = <String, List<int>>{};
    for (final f in archive.files) {
      if (f.isFile) fileMap[f.name] = f.content as List<int>;
    }

    final filepath = 'OEBPS/${page.href}';
    final oldXhtml = utf8.decode(fileMap[filepath]!);

    final anchorNum = int.tryParse(
          RegExp(r'id="anchor(\d+)"').firstMatch(oldXhtml)?.group(1) ?? '') ??
        1;
    final oldFootnoteNum = int.tryParse(
        RegExp(r'href="attributions\.xhtml#footnote-(\d+)"')
                .firstMatch(oldXhtml)
                ?.group(1) ??
            '');

    final hasFootnote = footnote.trim().isNotEmpty;
    int? newFootnoteNum;
    if (hasFootnote) {
      if (oldFootnoteNum != null) {
        newFootnoteNum = oldFootnoteNum;
      } else {
        final attrContent =
            utf8.decode(fileMap['OEBPS/Text/attributions.xhtml']!);
        final re = RegExp(r'id="footnote-(\d+)"');
        int max = 0;
        for (final m in re.allMatches(attrContent)) {
          final v = int.tryParse(m.group(1)!) ?? 0;
          if (v > max) max = v;
        }
        newFootnoteNum = max + 1;
      }
    }

    fileMap[filepath] = utf8.encode(_buildRecipeXhtml(
      title: title,
      description: description,
      ingredientSections: ingredientSections,
      method: method,
      footnote: hasFootnote ? footnote.trim() : null,
      filename: page.filename,
      footnoteNum: newFootnoteNum,
      anchorNum: anchorNum,
    ));

    var attr = utf8.decode(fileMap['OEBPS/Text/attributions.xhtml']!);
    if (oldFootnoteNum != null) {
      attr = attr.replaceFirst(
        RegExp(
          r'\n<section>\n\s*<p[^>]*id="footnote-' +
              oldFootnoteNum.toString() +
              r'"[^>]*>.*?</p>\n</section>',
          dotAll: true,
        ),
        '',
      );
    }
    if (hasFootnote && newFootnoteNum != null) {
      final footnoteBody = _footnoteHtml(footnote.trim());
      attr = attr.replaceFirst(
        '</body>',
        '\n<section>\n'
            '  <p class="footnote" id="footnote-$newFootnoteNum">'
            '<a href="${page.filename}.xhtml#citation-$newFootnoteNum"'
            ' class="calibre8">*</a>'
            ' $footnoteBody</p>\n'
            '</section>\n</body>',
      );
    }
    fileMap['OEBPS/Text/attributions.xhtml'] = utf8.encode(attr);

    var toc = utf8.decode(fileMap['OEBPS/toc.ncx']!);
    final navRe = RegExp(
      'id="u${RegExp.escape(page.filename)}"[^>]*>.*?<text>([^<]*)</text>',
      dotAll: true,
    );
    final navMatch = navRe.firstMatch(toc);
    if (navMatch != null) {
      toc = toc.replaceFirst(navMatch.group(1)!, _escXml(title));
    }
    fileMap['OEBPS/toc.ncx'] = utf8.encode(toc);

    var htmlToc =
        utf8.decode(fileMap['OEBPS/Text/index_split_001.xhtml']!);
    final anchorRef =
        '${page.filename}.xhtml#anchor$anchorNum';
    final linkRe =
        RegExp('href="${RegExp.escape(anchorRef)}"[^>]*>([^<]*)');
    final linkMatch = linkRe.firstMatch(htmlToc);
    if (linkMatch != null) {
      htmlToc = htmlToc.replaceFirst(
          linkMatch.group(1)!, ' ${_escXml(title)}');
    }
    fileMap['OEBPS/Text/index_split_001.xhtml'] = utf8.encode(htmlToc);

    final newArchive = Archive();
    final mimetypeBytes = fileMap.remove('mimetype');
    if (mimetypeBytes != null) {
      final mf =
          ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
      mf.compress = false;
      newArchive.addFile(mf);
    }
    for (final entry in fileMap.entries) {
      newArchive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await file.writeAsBytes(ZipEncoder().encode(newArchive)!);
  }

  // ── Reorder pages ─────────────────────────────────────────────────────────

  Future<void> reorderPages(List<EpubChapter> chapters) async {
    final file = File(epubPath);
    await file.copy('$epubPath.old');

    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final fileMap = <String, List<int>>{};
    for (final f in archive.files) {
      if (f.isFile) fileMap[f.name] = f.content as List<int>;
    }

    var opf = utf8.decode(fileMap['OEBPS/content.opf']!);

    // Find chapter titles that already have a standalone title page (body is
    // just <h1 class="title">…</h1>), so we don't create duplicates on
    // subsequent saves.
    final existingTitleTitles = <String>{};
    for (final entry in fileMap.entries) {
      if (!entry.key.startsWith('OEBPS/Text/') ||
          !entry.key.endsWith('.xhtml')) { continue; }
      final text = utf8.decode(entry.value);
      final bodyM =
          RegExp(r'<body[^>]*>(.*?)</body>', dotAll: true).firstMatch(text);
      if (bodyM == null) continue;
      final inner = bodyM.group(1)!.trim();
      final h1M =
          RegExp(r'^<h1[^>]*>(.*?)</h1>$', dotAll: true).firstMatch(inner);
      if (h1M != null) {
        existingTitleTitles.add(_unescXml(h1M.group(1)!.trim()));
      }
    }

    // For each new chapter (no existing title page), create one and add it to
    // the manifest.  Track the new IDs/hrefs so _reorderSpine and
    // _reorderHtmlToc can reference them.
    final newTitlePageIds = <String, String>{}; // chapter title → manifest id
    final newTitlePageHrefs = <String, String>{}; // chapter title → Text/…xhtml href
    for (final ch in chapters) {
      if (ch.title == null || ch.pages.isEmpty) continue;
      if (existingTitleTitles.contains(ch.title)) continue;

      var slug = ch.title!.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (slug.isEmpty) slug = 'chapter';
      var filename = slug;
      var n = 2;
      while (fileMap.containsKey('OEBPS/Text/$filename.xhtml')) {
        filename = '${slug}_$n';
        n++;
      }
      fileMap['OEBPS/Text/$filename.xhtml'] =
          utf8.encode(_buildChapterXhtml(ch.title!));
      opf = opf.replaceFirst(
        '</manifest>',
        '    <item id="$filename.xhtml" href="Text/$filename.xhtml"'
            ' media-type="application/xhtml+xml"/>\n  </manifest>',
      );
      newTitlePageIds[ch.title!] = '$filename.xhtml';
      newTitlePageHrefs[ch.title!] = '$filename.xhtml';
    }

    opf = _reorderSpine(opf, chapters, newTitlePageIds);
    fileMap['OEBPS/content.opf'] = utf8.encode(opf);

    var toc = utf8.decode(fileMap['OEBPS/toc.ncx']!);
    toc = _reorderToc(toc, chapters);
    fileMap['OEBPS/toc.ncx'] = utf8.encode(toc);

    var htmlToc = utf8.decode(fileMap['OEBPS/Text/index_split_001.xhtml']!);
    htmlToc = _reorderHtmlToc(htmlToc, chapters, newTitlePageHrefs);
    fileMap['OEBPS/Text/index_split_001.xhtml'] = utf8.encode(htmlToc);

    final newArchive = Archive();
    final mimetypeBytes = fileMap.remove('mimetype');
    if (mimetypeBytes != null) {
      final mf =
          ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
      mf.compress = false;
      newArchive.addFile(mf);
    }
    for (final entry in fileMap.entries) {
      newArchive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await file.writeAsBytes(ZipEncoder().encode(newArchive)!);
  }

  String _reorderSpine(String opf, List<EpubChapter> chapters,
      Map<String, String> newTitlePageIds) {
    final newOrder = [
      for (final ch in chapters)
        for (final page in ch.pages)
          if (page.id.isNotEmpty) page.id,
    ];
    final newOrderSet = newOrder.toSet();

    final spineRe =
        RegExp(r'(<spine\b[^>]*>)(.*?)(</spine>)', dotAll: true);
    final spineMatch = spineRe.firstMatch(opf);
    if (spineMatch == null) return opf;

    final spineContent = spineMatch.group(2)!;
    final itemrefRe =
        RegExp(r'<itemref\b[^>]*\bidref="([^"]+)"[^>]*/>', dotAll: true);

    var newIdx = 0;
    var rebuilt = spineContent;
    int offset = 0;
    for (final m in itemrefRe.allMatches(spineContent)) {
      if (!newOrderSet.contains(m.group(1)!)) continue;
      if (newIdx >= newOrder.length) continue;
      final oldTag = m.group(0)!;
      final newId = newOrder[newIdx++];
      final newTag = '<itemref idref="$newId"/>';
      final start = m.start + offset;
      final end = m.end + offset;
      rebuilt =
          rebuilt.substring(0, start) + newTag + rebuilt.substring(end);
      offset += newTag.length - oldTag.length;
    }

    // Insert new chapter title page itemrefs before the first recipe of each
    // new chapter.
    for (final ch in chapters) {
      if (ch.title == null || ch.pages.isEmpty) continue;
      final titlePageId = newTitlePageIds[ch.title!];
      if (titlePageId == null) continue;
      final firstRecipeId = ch.pages.first.id;
      if (firstRecipeId.isEmpty) continue;
      final searchStr = 'idref="$firstRecipeId"';
      final idx = rebuilt.indexOf(searchStr);
      if (idx >= 0) {
        final tagStart = rebuilt.lastIndexOf('<itemref', idx);
        if (tagStart >= 0) {
          rebuilt = '${rebuilt.substring(0, tagStart)}'
              '<itemref idref="$titlePageId"/>\n    '
              '${rebuilt.substring(tagStart)}';
        }
      }
    }

    return opf.replaceFirst(
      spineMatch.group(0)!,
      '${spineMatch.group(1)!}$rebuilt${spineMatch.group(3)!}',
    );
  }

  String _reorderToc(String toc, List<EpubChapter> chapters) {
    final navPointRe =
        RegExp(r'<navPoint\b[^>]*>.*?</navPoint>', dotAll: true);
    final srcRe = RegExp(r'<content\s+src="([^"]+)"');
    final textRe = RegExp(r'<text>([^<]+)</text>');

    final navPoints =
        navPointRe.allMatches(toc).map((m) => m.group(0)!).toList();

    // Identify chapter markers by INDEX (same reasoning as _parsePages): when
    // two consecutive navPoints share the same no-fragment src, only the first
    // is the chapter marker — the second is a recipe whose navPoint was created
    // without a fragment (e.g. by saveRecipe).
    final markerIndices = <int>{};
    for (int i = 0; i < navPoints.length - 1; i++) {
      final cur = srcRe.firstMatch(navPoints[i])?.group(1) ?? '';
      final next = srcRe.firstMatch(navPoints[i + 1])?.group(1) ?? '';
      if (!cur.contains('#') && (
          (next.contains('#') && next.split('#').first == cur) ||
          (!next.contains('#') && next == cur))) {
        markerIndices.add(i);
      }
    }

    // Map decoded chapter title → chapter marker navPoint.
    // Keyed by title so it stays correct when recipes are reordered between
    // chapters (the marker file no longer matches the first recipe's file).
    final markerByTitle = <String, String>{};
    // Map filename (no ext) → recipe navPoint (fragment src).
    final recipeNavByFile = <String, String>{};
    // Map filename (no ext) → standalone navPoint (no fragment, not a marker).
    final standaloneNavByFile = <String, String>{};

    for (int j = 0; j < navPoints.length; j++) {
      final np = navPoints[j];
      final src = srcRe.firstMatch(np)?.group(1) ?? '';
      final base =
          src.split('#').first.split('/').last.replaceAll('.xhtml', '');
      if (markerIndices.contains(j)) {
        final title =
            _unescXml(textRe.firstMatch(np)?.group(1)?.trim() ?? '');
        markerByTitle[title] = np;
      } else if (src.contains('#')) {
        recipeNavByFile[base] = np;
      } else {
        standaloneNavByFile[base] = np;
      }
    }

    final ordered = <String>[];
    for (final chapter in chapters) {
      if (chapter.pages.isEmpty) continue;

      if (chapter.title != null) {
        final marker = markerByTitle[chapter.title];
        if (marker != null && !ordered.contains(marker)) {
          ordered.add(marker);
        } else if (marker == null) {
          // New chapter — synthesise a marker from the first recipe.
          final firstPage = chapter.pages.first;
          final firstNav = recipeNavByFile[firstPage.filename] ??
              standaloneNavByFile[firstPage.filename];
          if (firstNav != null) {
            final firstSrc = srcRe.firstMatch(firstNav)?.group(1) ?? '';
            if (firstSrc.isNotEmpty) {
              final baseSrc = firstSrc.split('#').first;
              final escapedTitle = _escXml(chapter.title!);
              final newMarker = '<navPoint id="uchapter_${firstPage.filename}"'
                  ' playOrder="0">\n'
                  '      <navLabel><text>$escapedTitle</text></navLabel>\n'
                  '      <content src="$baseSrc"/>\n'
                  '    </navPoint>';
              ordered.add(newMarker);
            }
          }
        }
      }

      for (final page in chapter.pages) {
        final nav =
            recipeNavByFile[page.filename] ?? standaloneNavByFile[page.filename];
        if (nav != null && !ordered.contains(nav)) ordered.add(nav);
      }
    }

    int playOrder = 1;
    final reordered = ordered
        .map((np) => np.replaceFirst(
            RegExp(r'playOrder="\d+"'), 'playOrder="${playOrder++}"'))
        .join('\n    ');

    final navMapRe =
        RegExp(r'(<navMap\b[^>]*>).*?(</navMap>)', dotAll: true);
    return toc.replaceFirstMapped(
      navMapRe,
      (m) => '${m.group(1)!}\n    $reordered\n  ${m.group(2)!}',
    );
  }

  String _reorderHtmlToc(String htmlToc, List<EpubChapter> chapters,
      Map<String, String> newTitlePageHrefs) {
    final bodyStartIdx = htmlToc.indexOf('<body');
    if (bodyStartIdx < 0) return htmlToc;
    final bodyContentStart = htmlToc.indexOf('>', bodyStartIdx) + 1;
    final bodyEnd = htmlToc.lastIndexOf('</body>');
    if (bodyEnd < 0) return htmlToc;

    final bodyContent = htmlToc.substring(bodyContentStart, bodyEnd);
    // Keyed by decoded link text so it matches chapter.title regardless of
    // which recipe is currently first in the chapter.
    final p2ByTitle = <String, String>{};
    final p3ByFilename = <String, String>{};
    String? p1Element;

    final pRe = RegExp(
        r'<p\b[^>]*class="(p-p[123])"[^>]*>(.*?)</p>', dotAll: true);
    final linkTextRe = RegExp(r'<a[^>]*>\s*(.*?)\s*</a>', dotAll: true);

    for (final m in pRe.allMatches(bodyContent)) {
      final full = m.group(0)!;
      final cls = m.group(1)!;
      final inner = m.group(2)!;
      if (cls == 'p-p1') {
        p1Element = full;
        continue;
      }
      if (cls == 'p-p2') {
        final title =
            _unescXml(linkTextRe.firstMatch(inner)?.group(1)?.trim() ?? '');
        if (title.isNotEmpty) p2ByTitle[title] = full;
      } else {
        final hrefMatch = RegExp(r'href="([^"#]+)').firstMatch(inner);
        if (hrefMatch == null) continue;
        final file = hrefMatch.group(1)!.replaceAll('.xhtml', '');
        p3ByFilename[file] = full;
      }
    }

    final sb = StringBuffer('\n');
    if (p1Element != null) sb.writeln('  $p1Element');

    int chapterNum = 1;
    for (final chapter in chapters) {
      if (chapter.pages.isEmpty) continue;

      if (chapter.title != null) {
        final currentChapterNum = chapterNum++;

        final p2 = p2ByTitle[chapter.title];
        if (p2 != null) {
          sb.writeln(
              '  ${_updateTocEntryNumber(p2, '$currentChapterNum.')}');
        } else if (chapter.pages.isNotEmpty) {
          // New chapter — link to the dedicated title page if we created one,
          // otherwise fall back to the first recipe's href.
          final titleHref = newTitlePageHrefs[chapter.title!];
          if (titleHref != null) {
            sb.writeln('  <p class="p-p2">$currentChapterNum.'
                '<a href="$titleHref" class="calibre1">'
                ' ${_escXml(chapter.title!)}</a></p>');
          } else {
            final p3 = p3ByFilename[chapter.pages.first.filename];
            if (p3 != null) {
              final hrefMatch = RegExp(r'href="([^"]+)"').firstMatch(p3);
              if (hrefMatch != null) {
                sb.writeln('  <p class="p-p2">$currentChapterNum.'
                    '<a href="${hrefMatch.group(1)!}" class="calibre1">'
                    ' ${_escXml(chapter.title!)}</a></p>');
              }
            }
          }
        }

        int recipeNum = 1;
        for (final page in chapter.pages) {
          final p3 = p3ByFilename[page.filename];
          if (p3 != null) {
            sb.writeln('  ${_updateTocEntryNumber(p3, '$currentChapterNum.$recipeNum.')}');
            recipeNum++;
          }
        }
      } else {
        for (final page in chapter.pages) {
          final p3 = p3ByFilename[page.filename];
          if (p3 != null) sb.writeln('  $p3');
        }
      }
    }

    sb.write('  <p>&#160;</p>\n');
    return htmlToc.substring(0, bodyContentStart) +
        sb.toString() +
        htmlToc.substring(bodyEnd);
  }

  String _updateTocEntryNumber(String element, String newNum) =>
      element.replaceFirst(RegExp(r'>([\d.]*)<a'), '>$newNum<a');

  // ── helpers ────────────────────────────────────────────────────────────────

  String _readText(Archive archive, String name) {
    final f = archive.findFile(name);
    if (f == null) throw Exception('$name not found in EPUB');
    return utf8.decode(f.content as List<int>);
  }

  String _footnoteHtml(String text) {
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return '<a href="${_escXml(text)}">${_escXml(text)}</a>';
    }
    return _escXml(text);
  }

  static String _escXml(String t) => t
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _unescXml(String t) => t
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"');

  // ── Create new cookbook ────────────────────────────────────────────────────

  static Future<void> createCookbook({
    required String path,
    required String title,
    String? coverImagePath,
  }) async {
    final uuid = _generateUuid();
    final titleEsc = _escXml(title);
    final fileMap = <String, List<int>>{};

    String? imageHref;
    String? imageMimeType;
    if (coverImagePath != null) {
      final ext = coverImagePath.split('.').last.toLowerCase();
      final safeExt = ext == 'jpeg' ? 'jpg' : ext;
      imageMimeType = safeExt == 'png' ? 'image/png' : 'image/jpeg';
      imageHref = 'Images/cover.$safeExt';
      fileMap['OEBPS/$imageHref'] = await File(coverImagePath).readAsBytes();
    }

    fileMap['META-INF/container.xml'] = utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0" xmlns="urn:oasis:schemas:container">\n'
      '  <rootfiles>\n'
      '    <rootfile full-path="OEBPS/content.opf"'
      ' media-type="application/oebps-package+xml"/>\n'
      '  </rootfiles>\n'
      '</container>',
    );

    final imageManifestItem = imageHref != null
        ? '    <item id="cover_image" href="$imageHref"'
            ' media-type="$imageMimeType"/>\n'
        : '';

    fileMap['OEBPS/content.opf'] = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<package xmlns="http://www.idpf.org/2007/opf" version="2.0"'
      ' unique-identifier="bookid">\n'
      '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"'
      ' xmlns:opf="http://www.idpf.org/2007/opf">\n'
      '    <dc:title>$titleEsc</dc:title>\n'
      '    <dc:language>en</dc:language>\n'
      '    <dc:identifier id="bookid">urn:uuid:$uuid</dc:identifier>\n'
      '  </metadata>\n'
      '  <manifest>\n'
      '    <item id="ncx" href="toc.ncx"'
      ' media-type="application/x-dtbncx+xml"/>\n'
      '    <item id="page_styles.css" href="Styles/page_styles.css"'
      ' media-type="text/css"/>\n'
      '    <item id="stylesheet.css" href="Styles/stylesheet.css"'
      ' media-type="text/css"/>\n'
      '    <item id="titlepage.xhtml" href="Text/titlepage.xhtml"'
      ' media-type="application/xhtml+xml"/>\n'
      '    <item id="index_split_001.xhtml"'
      ' href="Text/index_split_001.xhtml"'
      ' media-type="application/xhtml+xml"/>\n'
      '    <item id="attributions.xhtml" href="Text/attributions.xhtml"'
      ' media-type="application/xhtml+xml"/>\n'
      '$imageManifestItem'
      '  </manifest>\n'
      '  <spine toc="ncx">\n'
      '    <itemref idref="titlepage.xhtml"/>\n'
      '    <itemref idref="index_split_001.xhtml"/>\n'
      '    <itemref idref="attributions.xhtml"/>\n'
      '  </spine>\n'
      '</package>',
    );

    fileMap['OEBPS/toc.ncx'] = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"\n'
      '  "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">\n'
      '<ncx version="2005-1"'
      ' xmlns="http://www.daisy.org/z3986/2005/ncx/">\n'
      '  <head>\n'
      '    <meta name="dtb:uid" content="urn:uuid:$uuid"/>\n'
      '    <meta name="dtb:depth" content="1"/>\n'
      '    <meta name="dtb:totalPageCount" content="0"/>\n'
      '    <meta name="dtb:maxPageNumber" content="0"/>\n'
      '  </head>\n'
      '  <docTitle><text>$titleEsc</text></docTitle>\n'
      '  <navMap>\n'
      '    <navPoint id="utitlepage" playOrder="1">\n'
      '      <navLabel><text>$titleEsc</text></navLabel>\n'
      '      <content src="Text/titlepage.xhtml"/>\n'
      '    </navPoint>\n'
      '    <navPoint id="uindex" playOrder="2">\n'
      '      <navLabel><text>Contents</text></navLabel>\n'
      '      <content src="Text/index_split_001.xhtml"/>\n'
      '    </navPoint>\n'
      '  </navMap>\n'
      '</ncx>',
    );

    final titlepageBody = imageHref != null
        ? '  <div class="title-page">\n'
            '    <img src="../$imageHref" alt="$titleEsc"'
            ' class="cover-image"/>\n'
            '  </div>'
        : '  <h1 class="title">$titleEsc</h1>';

    fileMap['OEBPS/Text/titlepage.xhtml'] = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"\n'
      '  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
      '<html xmlns="http://www.w3.org/1999/xhtml">\n'
      '<head>\n'
      '  <title>$titleEsc</title>\n'
      '  <link href="../Styles/page_styles.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '  <link href="../Styles/stylesheet.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '</head>\n'
      '<body>\n'
      '$titlepageBody\n'
      '</body>\n'
      '</html>',
    );

    fileMap['OEBPS/Text/index_split_001.xhtml'] = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"\n'
      '  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
      '<html xmlns="http://www.w3.org/1999/xhtml">\n'
      '<head>\n'
      '  <title>$titleEsc</title>\n'
      '  <link href="../Styles/page_styles.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '  <link href="../Styles/stylesheet.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '</head>\n'
      '<body>\n'
      '  <p class="p-p1"><b>$titleEsc</b></p>\n'
      '  <p>&#160;</p>\n'
      '</body>\n'
      '</html>',
    );

    fileMap['OEBPS/Text/attributions.xhtml'] = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"\n'
      '  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
      '<html xmlns="http://www.w3.org/1999/xhtml">\n'
      '<head>\n'
      '  <title>Sources</title>\n'
      '  <link href="../Styles/page_styles.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '  <link href="../Styles/stylesheet.css" rel="stylesheet"'
      ' type="text/css"/>\n'
      '</head>\n'
      '<body>\n'
      '  <h2 class="recipe-title">Sources</h2>\n'
      '</body>\n'
      '</html>',
    );

    fileMap['OEBPS/Styles/page_styles.css'] = utf8.encode(
      '@charset "utf-8";\n\n'
      'body {\n'
      '  font-family: Georgia, serif;\n'
      '  margin: 5%;\n'
      '  font-size: 1em;\n'
      '  line-height: 1.5;\n'
      '}\n',
    );

    fileMap['OEBPS/Styles/stylesheet.css'] = utf8.encode(
      '@charset "utf-8";\n\n'
      'h1.title { font-size: 2em; text-align: center; margin: 2em 0; }\n'
      'h2.recipe-title { font-size: 1.4em; margin-top: 1.5em;'
      ' border-bottom: 1px solid #ccc; padding-bottom: 0.2em; }\n'
      'h3.recipe-part { font-size: 1.1em; margin-top: 1em;'
      ' font-style: italic; }\n'
      'table.recipe-table { width: 100%; border-collapse: collapse;'
      ' margin: 0.5em 0 1em 0; font-size: 0.9em; }\n'
      'table.recipe-table th { background-color: #f5f5f5; padding: 4px 6px;'
      ' text-align: left; font-weight: bold;'
      ' border-bottom: 2px solid #ddd; }\n'
      'table.recipe-table td { padding: 3px 6px;'
      ' border-bottom: 1px solid #eee; vertical-align: top; }\n'
      '.col-ingredients { width: 38%; }\n'
      '.col-measure { width: 12%; text-align: center; }\n'
      'p.footnote { font-size: 0.85em; font-style: italic; }\n'
      '.calibre1 { color: inherit; text-decoration: none; }\n'
      '.calibre2 { vertical-align: super; font-size: 0.75em; }\n'
      '.calibre8 { color: inherit; text-decoration: none; }\n'
      'a.citation { color: inherit; text-decoration: none; }\n'
      'p.p-p1 { font-size: 1.3em; font-weight: bold;'
      ' margin-bottom: 0.5em; }\n'
      'p.p-p2 { font-size: 1.1em; margin-left: 1.5em;'
      ' margin-top: 0.3em; }\n'
      'p.p-p3 { margin-left: 3em; margin-top: 0.1em;'
      ' font-size: 0.95em; }\n'
      '.cover-image { display: block; max-width: 100%; margin: 0 auto; }\n'
      'div.title-page { text-align: center; margin-top: 2em; }\n',
    );

    final newArchive = Archive();
    final mimetypeBytes = utf8.encode('application/epub+zip');
    final mf = ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
    mf.compress = false;
    newArchive.addFile(mf);
    for (final entry in fileMap.entries) {
      newArchive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await File(path).writeAsBytes(ZipEncoder().encode(newArchive)!);
  }

  static String _generateUuid() {
    final b = List.generate(16, (_) => Random.secure().nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    return '${hex(b[0])}${hex(b[1])}${hex(b[2])}${hex(b[3])}'
        '-${hex(b[4])}${hex(b[5])}'
        '-${hex(b[6])}${hex(b[7])}'
        '-${hex(b[8])}${hex(b[9])}'
        '-${hex(b[10])}${hex(b[11])}${hex(b[12])}${hex(b[13])}${hex(b[14])}${hex(b[15])}';
  }
}
