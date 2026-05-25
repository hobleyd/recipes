/// Converts between common imperial and metric cooking measurements.
/// Uses UK conventions (568 ml pint, metric cup = 250 ml).
class MeasurementConverter {
  // Imperial volume unit → ml
  static const _volToMl = <String, double>{
    'tsp': 5.0,
    'teaspoon': 5.0,
    'teaspoons': 5.0,
    'tbsp': 15.0,
    'tbs': 15.0,
    'tablespoon': 15.0,
    'tablespoons': 15.0,
    'cup': 250.0,
    'cups': 250.0,
    'fl oz': 28.413,
    'floz': 28.413,
    'fluid oz': 28.413,
    'pint': 568.261,
    'pints': 568.261,
    'pt': 568.261,
    'quart': 1136.52,
    'quarts': 1136.52,
    'qt': 1136.52,
  };

  // Imperial weight unit → g
  static const _wtToG = <String, double>{
    'oz': 28.3495,
    'ounce': 28.3495,
    'ounces': 28.3495,
    'lb': 453.592,
    'lbs': 453.592,
    'pound': 453.592,
    'pounds': 453.592,
  };

  static const _fracChars = <String, double>{
    '½': 0.5,
    '¼': 0.25,
    '¾': 0.75,
    '⅓': 1 / 3,
    '⅔': 2 / 3,
    '⅛': 0.125,
    '⅜': 0.375,
    '⅝': 0.625,
    '⅞': 0.875,
  };

  /// Returns e.g. "15 ml" or "28 g", or null if input can't be parsed/converted.
  static String? imperialToMetric(String input) {
    final parsed = _parseImperial(input);
    if (parsed == null) return null;
    final (value, unit) = parsed;

    if (_volToMl.containsKey(unit)) {
      final ml = value * _volToMl[unit]!;
      return '${_fmtMetric(ml)} ml';
    }
    if (_wtToG.containsKey(unit)) {
      final g = value * _wtToG[unit]!;
      return '${_fmtMetric(g)} g';
    }
    return null;
  }

  /// Returns e.g. "1 tbs" or "½ pint", or null if input can't be parsed/converted.
  static String? metricToImperial(String input) {
    final lower = input.trim().toLowerCase();
    if (lower.isEmpty) return null;

    double? value;
    bool isVol = false;

    if (lower.endsWith(' ml') || lower.endsWith('ml')) {
      value = _parseNum(lower.replaceAll(RegExp(r'\s*ml$'), '').trim());
      isVol = true;
    } else if (lower.endsWith(' kg') || lower.endsWith('kg')) {
      final kg = _parseNum(lower.replaceAll(RegExp(r'\s*kg$'), '').trim());
      if (kg != null) value = kg * 1000;
      isVol = false;
    } else if (lower.endsWith(' g') || lower.endsWith('g')) {
      value = _parseNum(lower.replaceAll(RegExp(r'\s*g$'), '').trim());
      isVol = false;
    } else if (lower.endsWith(' l') ||
        lower.endsWith('litre') ||
        lower.endsWith('liter')) {
      final l =
          _parseNum(lower.replaceAll(RegExp(r'\s*(litre|liter|l)$'), '').trim());
      if (l != null) value = l * 1000;
      isVol = true;
    }

    if (value == null || value <= 0) return null;
    return isVol ? _mlToImperial(value) : _gToImperial(value);
  }

  // ── private helpers ────────────────────────────────────────────────────────

  static String? _mlToImperial(double ml) {
    // Prefer largest unit that gives a tidy fraction.
    // Check pint first for larger volumes.
    if (ml >= 200) {
      final qty = ml / 568.261;
      final n = _niceImperial(qty, tol: 0.02);
      if (n != null) return '$n ${qty > 1.001 ? 'pints' : 'pint'}';
    }
    if (ml >= 50) {
      final qty = ml / 250.0;
      final n = _niceImperial(qty, tol: 0.02);
      if (n != null) return '$n ${qty > 1.001 ? 'cups' : 'cup'}';
    }
    if (ml <= 90) {
      final qty = ml / 15.0;
      final n = _niceImperial(qty, tol: 0.05);
      if (n != null) return '$n tbs';
    }
    if (ml <= 15) {
      final qty = ml / 5.0;
      final n = _niceImperial(qty, tol: 0.05);
      if (n != null) return '$n tsp';
    }
    return null;
  }

  static String? _gToImperial(double g) {
    if (g <= 285) {
      final qty = g / 28.3495;
      final n = _niceImperial(qty, tol: 0.05);
      if (n != null) return '$n oz';
    }
    final qty = g / 453.592;
    final n = _niceImperial(qty, tol: 0.03);
    if (n != null) return '$n ${qty > 1.001 ? 'lbs' : 'lb'}';
    return null;
  }

  /// Express [value] as a nice cooking fraction (multiples of ⅛).
  /// Returns null if the nearest ⅛ multiple is more than [tol] (relative) away.
  static String? _niceImperial(double value, {double tol = 0.05}) {
    if (value <= 0) return null;
    final eighths = (value * 8).round();
    if (eighths == 0) return null;
    final niceVal = eighths / 8.0;
    if ((value - niceVal).abs() / value > tol) return null;

    final whole = eighths ~/ 8;
    final rem = eighths % 8;
    const fracStr = ['', '⅛', '¼', '⅜', '½', '⅝', '¾', '⅞'];
    final frac = fracStr[rem];

    if (whole == 0) return frac.isEmpty ? null : frac;
    return '$whole$frac';
  }

  /// Round to nearest 0.5 for values < 5, otherwise nearest integer.
  static String _fmtMetric(double v) {
    if (v < 5) {
      final r = (v * 2).round() / 2;
      return r == r.floorToDouble()
          ? r.toInt().toString()
          : r.toStringAsFixed(1);
    }
    return v.round().toString();
  }

  /// Parse "1 tbs", "½ Pint", "1½ cups" → (quantity, lowercase-unit).
  static (double, String)? _parseImperial(String input) {
    input = input.trim();
    if (input.isEmpty) return null;

    double value = 0;
    String s = input;

    // Extract leading integer or decimal
    final numMatch = RegExp(r'^(\d+(?:\.\d+)?)').firstMatch(s);
    if (numMatch != null) {
      value = double.parse(numMatch.group(1)!);
      s = s.substring(numMatch.end).trim();
    }

    // Extract fraction character (handles "1½" and "½")
    for (final e in _fracChars.entries) {
      if (s.startsWith(e.key)) {
        value += e.value;
        s = s.substring(e.key.length).trim();
        break;
      }
    }

    if (value == 0 || s.isEmpty) return null;
    return (value, s.toLowerCase().trim());
  }

  /// Parse a plain number string, optionally with a leading fraction char.
  static double? _parseNum(String s) {
    s = s.trim();
    if (s.isEmpty) return null;
    double value = 0;
    final numMatch = RegExp(r'^(\d+(?:\.\d+)?)').firstMatch(s);
    if (numMatch != null) {
      value = double.parse(numMatch.group(1)!);
      s = s.substring(numMatch.end).trim();
    }
    for (final e in _fracChars.entries) {
      if (s == e.key) {
        value += e.value;
        s = '';
        break;
      }
    }
    if (s.isNotEmpty) return null;
    return value > 0 ? value : null;
  }
}
