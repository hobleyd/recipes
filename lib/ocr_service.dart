import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'models.dart';

enum OcrBackend { ollama, claude }

class OcrSettings {
  final String claudeApiKey;
  final String ollamaUrl;
  final String ollamaModel;
  final String ollamaTextModel;
  final OcrBackend preferred;

  const OcrSettings({
    this.claudeApiKey = '',
    this.ollamaUrl = 'http://localhost:11434',
    this.ollamaModel = 'llama3.2-vision',
    this.ollamaTextModel = '',
    this.preferred = OcrBackend.ollama,
  });

  bool get isConfigured => preferred == OcrBackend.ollama
      ? ollamaUrl.isNotEmpty
      : claudeApiKey.isNotEmpty;

  /// The model used for text-based extraction (web-page import). Falls back
  /// to the vision model if no separate text model has been configured.
  String get effectiveOllamaTextModel =>
      ollamaTextModel.isEmpty ? ollamaModel : ollamaTextModel;
}

abstract class OcrService {
  factory OcrService.claude(String apiKey) = _ClaudeOcrService;
  factory OcrService.ollama(
      {required String baseUrl,
      required String model,
      required String textModel}) = _OllamaOcrService;

  Future<RecipeData> extractRecipe(String filePath);
  Future<RecipeData> extractRecipeFromUrl(String url);

  static Future<List<String>> fetchOllamaModels(String baseUrl) async {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final response = await http
        .get(Uri.parse('$base/api/tags'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw Exception('Ollama returned ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final models = (data['models'] as List?) ?? [];
    return models
        .map((m) => (m['name'] as String?) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

const _recipePrompt = r'''
Extract this recipe and return it as a JSON object with exactly this structure:
{
  "title": "Recipe name",
  "description": "Brief introduction or description",
  "ingredientSections": [
    {
      "label": "",
      "ingredients": [
        {"name": "butter", "imperial": "2 tbsp", "metric": "30 g"}
      ]
    }
  ],
  "method": "Step 1...\n\nStep 2...",
  "footnote": ""
}

Rules:
- Use one section with an empty label if there is only one ingredient group.
- Use multiple sections with descriptive labels if the recipe has groups (e.g. "For the sauce:").
- Provide both imperial and metric measurements; if only one system is given, convert to the other.
- Return ONLY the JSON object — no markdown, no explanation, no other text.
''';

RecipeData _parseRecipeJson(Map<String, dynamic> json) {
  final sectionsList = (json['ingredientSections'] as List?) ?? [];
  final sections = sectionsList.map((s) {
    final ingList = (s['ingredients'] as List?) ?? [];
    final ingredients = ingList
        .map((i) => Ingredient(
              name: (i['name'] as String?) ?? '',
              imperial: (i['imperial'] as String?) ?? '',
              metric: (i['metric'] as String?) ?? '',
            ))
        .toList();
    return IngredientSection(
      label: (s['label'] as String?) ?? '',
      ingredients: ingredients.isNotEmpty ? ingredients : [Ingredient()],
    );
  }).toList();

  return RecipeData(
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    ingredientSections: sections.isNotEmpty
        ? sections
        : [IngredientSection(ingredients: [Ingredient()])],
    method: (json['method'] as String?) ?? '',
    footnote: (json['footnote'] as String?) ?? '',
    anchorNum: 0,
  );
}

RecipeData _extractAndParseJson(String text) {
  final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(text);
  if (jsonMatch == null) {
    throw Exception('Could not find structured recipe data in response');
  }
  return _parseRecipeJson(
      jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>);
}

Future<String> _fetchPageText(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) {
    throw Exception('Enter a valid URL');
  }

  late http.Response response;
  try {
    response = await http.get(
      uri,
      headers: {'User-Agent': 'Mozilla/5.0 (compatible; RecipeManager/1.0)'},
    ).timeout(const Duration(seconds: 20));
  } on TimeoutException {
    throw Exception('Timed out fetching the web page');
  } on SocketException catch (e) {
    throw Exception('Could not reach $url ($e)');
  }

  if (response.statusCode != 200) {
    throw Exception('Web page returned ${response.statusCode}');
  }

  final text = _stripHtml(response.body);
  if (text.isEmpty) {
    throw Exception('Could not find any readable text on that page');
  }
  return text;
}

String _stripHtml(String html) {
  var text = html
      .replaceAll(
          RegExp(r'<script[^>]*>.*?</script>',
              dotAll: true, caseSensitive: false),
          ' ')
      .replaceAll(
          RegExp(r'<style[^>]*>.*?</style>',
              dotAll: true, caseSensitive: false),
          ' ')
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');

  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'&#\d+;'), '');

  text = text
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n')
      .trim();

  const maxLength = 20000;
  return text.length > maxLength ? text.substring(0, maxLength) : text;
}

// ─── Claude backend ───────────────────────────────────────────────────────────

class _ClaudeOcrService implements OcrService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _model = 'claude-haiku-4-5-20251001';

  final String apiKey;
  _ClaudeOcrService(this.apiKey);

  @override
  Future<RecipeData> extractRecipe(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final ext = filePath.toLowerCase().split('.').last;
    final isPdf = ext == 'pdf';

    final List<Map<String, dynamic>> content = [
      if (isPdf)
        {
          'type': 'document',
          'source': {
            'type': 'base64',
            'media_type': 'application/pdf',
            'data': base64Encode(bytes),
          },
        }
      else
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': _mediaType(ext),
            'data': base64Encode(bytes),
          },
        },
      {'type': 'text', 'text': _recipePrompt},
    ];

    final response = await http.post(
      Uri.parse(_apiUrl),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        if (isPdf) 'anthropic-beta': 'pdfs-2024-09-25',
      },
      body: jsonEncode({
        'model': _model,
        'max_tokens': 4096,
        'messages': [
          {'role': 'user', 'content': content},
        ],
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final msg = (body['error'] as Map?)?['message'] ?? response.body;
      throw Exception(msg);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = ((data['content'] as List).first as Map)['text'] as String;
    return _extractAndParseJson(text);
  }

  static String _mediaType(String ext) => switch (ext) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };

  @override
  Future<RecipeData> extractRecipeFromUrl(String url) async {
    final pageText = await _fetchPageText(url);

    final response = await http.post(
      Uri.parse(_apiUrl),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': _model,
        'max_tokens': 4096,
        'messages': [
          {
            'role': 'user',
            'content': '$_recipePrompt\n\nWeb page content:\n\n$pageText',
          },
        ],
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final msg = (body['error'] as Map?)?['message'] ?? response.body;
      throw Exception(msg);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = ((data['content'] as List).first as Map)['text'] as String;
    return _extractAndParseJson(text);
  }
}

// ─── Ollama backend ───────────────────────────────────────────────────────────

class _OllamaOcrService implements OcrService {
  final String baseUrl;
  final String model;
  final String textModel;

  _OllamaOcrService(
      {required this.baseUrl, required this.model, required this.textModel});

  @override
  Future<RecipeData> extractRecipe(String filePath) async {
    final bytes = await File(filePath).readAsBytes();

    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final url = Uri.parse('$base/api/chat');

    late http.Response response;
    try {
      response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'messages': [
                {
                  'role': 'user',
                  'content': _recipePrompt,
                  'images': [base64Encode(bytes)],
                },
              ],
            }),
          )
          .timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw Exception(
          'Ollama timed out after 3 minutes. Is the model loaded? Run: ollama pull $model');
    } on SocketException catch (e) {
      throw Exception('Could not reach Ollama at $baseUrl — is it running? ($e)');
    }

    if (response.statusCode != 200) {
      throw Exception('Ollama error ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = (data['message'] as Map)['content'] as String;
    return _extractAndParseJson(text);
  }

  @override
  Future<RecipeData> extractRecipeFromUrl(String url) async {
    final pageText = await _fetchPageText(url);

    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final apiUrl = Uri.parse('$base/api/chat');

    late http.Response response;
    try {
      response = await http
          .post(
            apiUrl,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': textModel,
              'stream': false,
              'messages': [
                {
                  'role': 'user',
                  'content':
                      '$_recipePrompt\n\nWeb page content:\n\n$pageText',
                },
              ],
            }),
          )
          .timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw Exception(
          'Ollama timed out after 3 minutes. Is the model loaded? Run: ollama pull $textModel');
    } on SocketException catch (e) {
      throw Exception('Could not reach Ollama at $baseUrl — is it running? ($e)');
    }

    if (response.statusCode != 200) {
      throw Exception('Ollama error ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = (data['message'] as Map)['content'] as String;
    return _extractAndParseJson(text);
  }
}
