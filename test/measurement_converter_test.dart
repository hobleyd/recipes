import 'package:flutter_test/flutter_test.dart';
import 'package:recipes/measurement_converter.dart';

void main() {
  group('imperialToMetric', () {
    group('volume – teaspoons', () {
      test('1 tsp', () => expect(MeasurementConverter.imperialToMetric('1 tsp'), '5 ml'));
      test('½ tsp', () => expect(MeasurementConverter.imperialToMetric('½ tsp'), '2.5 ml'));
      test('2 tsp', () => expect(MeasurementConverter.imperialToMetric('2 tsp'), '10 ml'));
      test('1 teaspoon (long form)', () => expect(MeasurementConverter.imperialToMetric('1 teaspoon'), '5 ml'));
      test('2 teaspoons (plural)', () => expect(MeasurementConverter.imperialToMetric('2 teaspoons'), '10 ml'));
    });

    group('volume – tablespoons', () {
      test('1 tbs', () => expect(MeasurementConverter.imperialToMetric('1 tbs'), '15 ml'));
      test('1 tbsp', () => expect(MeasurementConverter.imperialToMetric('1 tbsp'), '15 ml'));
      test('2 tbs', () => expect(MeasurementConverter.imperialToMetric('2 tbs'), '30 ml'));
      test('½ tbs', () => expect(MeasurementConverter.imperialToMetric('½ tbs'), '8 ml'));
      test('1 tablespoon (long form)', () => expect(MeasurementConverter.imperialToMetric('1 tablespoon'), '15 ml'));
    });

    group('volume – cups', () {
      test('1 cup', () => expect(MeasurementConverter.imperialToMetric('1 cup'), '250 ml'));
      test('½ cup', () => expect(MeasurementConverter.imperialToMetric('½ cup'), '125 ml'));
      test('¼ cup', () => expect(MeasurementConverter.imperialToMetric('¼ cup'), '63 ml'));
      test('2 cups', () => expect(MeasurementConverter.imperialToMetric('2 cups'), '500 ml'));
      test('1½ cups', () => expect(MeasurementConverter.imperialToMetric('1½ cups'), '375 ml'));
    });

    group('volume – pints', () {
      test('1 pint', () => expect(MeasurementConverter.imperialToMetric('1 pint'), '568 ml'));
      test('½ pint', () => expect(MeasurementConverter.imperialToMetric('½ pint'), '284 ml'));
      test('¼ pint', () => expect(MeasurementConverter.imperialToMetric('¼ pint'), '142 ml'));
      test('2 pints', () => expect(MeasurementConverter.imperialToMetric('2 pints'), '1137 ml'));
      test('1 pt (abbreviation)', () => expect(MeasurementConverter.imperialToMetric('1 pt'), '568 ml'));
    });

    group('volume – fluid oz', () {
      test('1 fl oz', () => expect(MeasurementConverter.imperialToMetric('1 fl oz'), '28 ml'));
      test('2 fl oz', () => expect(MeasurementConverter.imperialToMetric('2 fl oz'), '57 ml'));
    });

    group('volume – quarts', () {
      test('1 quart', () => expect(MeasurementConverter.imperialToMetric('1 quart'), '1137 ml'));
      test('1 qt', () => expect(MeasurementConverter.imperialToMetric('1 qt'), '1137 ml'));
    });

    group('weight – ounces', () {
      test('1 oz', () => expect(MeasurementConverter.imperialToMetric('1 oz'), '28 g'));
      test('2 oz', () => expect(MeasurementConverter.imperialToMetric('2 oz'), '57 g'));
      test('4 oz', () => expect(MeasurementConverter.imperialToMetric('4 oz'), '113 g'));
      test('8 oz', () => expect(MeasurementConverter.imperialToMetric('8 oz'), '227 g'));
      test('½ oz', () => expect(MeasurementConverter.imperialToMetric('½ oz'), '14 g'));
      test('1 ounce (long form)', () => expect(MeasurementConverter.imperialToMetric('1 ounce'), '28 g'));
    });

    group('weight – pounds', () {
      test('1 lb', () => expect(MeasurementConverter.imperialToMetric('1 lb'), '454 g'));
      test('2 lbs', () => expect(MeasurementConverter.imperialToMetric('2 lbs'), '907 g'));
      test('½ lb', () => expect(MeasurementConverter.imperialToMetric('½ lb'), '227 g'));
      test('¼ lb', () => expect(MeasurementConverter.imperialToMetric('¼ lb'), '113 g'));
      test('1½ lbs', () => expect(MeasurementConverter.imperialToMetric('1½ lbs'), '680 g'));
      test('1 pound (long form)', () => expect(MeasurementConverter.imperialToMetric('1 pound'), '454 g'));
    });

    group('fraction characters in input', () {
      test('⅓ cup', () => expect(MeasurementConverter.imperialToMetric('⅓ cup'), '83 ml'));
      test('⅔ cup', () => expect(MeasurementConverter.imperialToMetric('⅔ cup'), '167 ml'));
      test('⅛ tsp', () => expect(MeasurementConverter.imperialToMetric('⅛ tsp'), '0.5 ml'));
      test('¾ cup', () => expect(MeasurementConverter.imperialToMetric('¾ cup'), '188 ml'));
      test('1¾ cups', () => expect(MeasurementConverter.imperialToMetric('1¾ cups'), '438 ml'));
    });

    group('invalid / unrecognised input', () {
      test('empty string', () => expect(MeasurementConverter.imperialToMetric(''), isNull));
      test('no unit', () => expect(MeasurementConverter.imperialToMetric('100'), isNull));
      test('unknown unit', () => expect(MeasurementConverter.imperialToMetric('1 gallon'), isNull));
      test('zero quantity', () => expect(MeasurementConverter.imperialToMetric('0 tsp'), isNull));
      test('fraction only no unit', () => expect(MeasurementConverter.imperialToMetric('½'), isNull));
    });
  });

  group('metricToImperial', () {
    group('volume – ml', () {
      test('5 ml → 1 tsp', () => expect(MeasurementConverter.metricToImperial('5 ml'), '1 tsp'));
      test('10 ml → 2 tsp', () => expect(MeasurementConverter.metricToImperial('10 ml'), '2 tsp'));
      test('15 ml → 1 tbs', () => expect(MeasurementConverter.metricToImperial('15 ml'), '1 tbs'));
      test('30 ml → 2 tbs', () => expect(MeasurementConverter.metricToImperial('30 ml'), '2 tbs'));
      // 60 ml is close enough to ¼ cup (62.5 ml) within 5% tolerance
      test('60 ml → ¼ cup', () => expect(MeasurementConverter.metricToImperial('60 ml'), '¼ cup'));
      test('125 ml → ½ cup', () => expect(MeasurementConverter.metricToImperial('125 ml'), '½ cup'));
      test('250 ml → 1 cup', () => expect(MeasurementConverter.metricToImperial('250 ml'), '1 cup'));
      // 142 ml = ¼ pint — previously broken when threshold was 200 ml
      test('142 ml → ¼ pint', () => expect(MeasurementConverter.metricToImperial('142 ml'), '¼ pint'));
      test('284 ml → ½ pint', () => expect(MeasurementConverter.metricToImperial('284 ml'), '½ pint'));
      test('568 ml → 1 pint', () => expect(MeasurementConverter.metricToImperial('568 ml'), '1 pint'));
      test('no space before unit', () => expect(MeasurementConverter.metricToImperial('15ml'), '1 tbs'));
    });

    group('volume – litres', () {
      test('1 litre', () => expect(MeasurementConverter.metricToImperial('1 litre'), '1¾ pints'));
      test('1 liter (US spelling)', () => expect(MeasurementConverter.metricToImperial('1 liter'), '1¾ pints'));
    });

    group('weight – g', () {
      test('28 g → 1 oz', () => expect(MeasurementConverter.metricToImperial('28 g'), '1 oz'));
      test('57 g → 2 oz', () => expect(MeasurementConverter.metricToImperial('57 g'), '2 oz'));
      test('113 g → ¼ lb', () => expect(MeasurementConverter.metricToImperial('113 g'), '¼ lb'));
      test('227 g → ½ lb', () => expect(MeasurementConverter.metricToImperial('227 g'), '½ lb'));
      test('340 g → ¾ lb', () => expect(MeasurementConverter.metricToImperial('340 g'), '¾ lb'));
      test('454 g → 1 lb', () => expect(MeasurementConverter.metricToImperial('454 g'), '1 lb'));
      test('680 g → 1½ lbs', () => expect(MeasurementConverter.metricToImperial('680 g'), '1½ lbs'));
      // 300 g previously returned null (gap between oz threshold and nice lb fraction)
      test('300 g → some result', () => expect(MeasurementConverter.metricToImperial('300 g'), isNotNull));
      test('no space before unit', () => expect(MeasurementConverter.metricToImperial('28g'), '1 oz'));
    });

    group('weight – kg', () {
      test('1 kg → 2¼ lbs', () => expect(MeasurementConverter.metricToImperial('1 kg'), '2¼ lbs'));
      test('0.5 kg → 1⅛ lbs (500 g ≈ 1.1 lb)', () => expect(MeasurementConverter.metricToImperial('0.5 kg'), '1⅛ lbs'));
      test('no space before unit', () => expect(MeasurementConverter.metricToImperial('1kg'), '2¼ lbs'));
    });

    group('invalid / unrecognised input', () {
      test('empty string', () => expect(MeasurementConverter.metricToImperial(''), isNull));
      test('no unit', () => expect(MeasurementConverter.metricToImperial('100'), isNull));
      test('zero value', () => expect(MeasurementConverter.metricToImperial('0 ml'), isNull));
      test('negative value', () => expect(MeasurementConverter.metricToImperial('-5 ml'), isNull));
      test('unknown unit', () => expect(MeasurementConverter.metricToImperial('100 cl'), isNull));
    });
  });
}
