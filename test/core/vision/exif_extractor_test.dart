import 'package:flutter_test/flutter_test.dart';
import 'package:ispy_ios/core/vision/exif_extractor.dart';

void main() {
  test('formatTimestamp returns human-readable date', () {
    final dt = DateTime(2026, 4, 14, 14, 23, 0);
    final result = ExifData.formatTimestamp(dt);
    expect(result, equals('2026-04-14 14:23'));
  });

  test('ExifData.empty returns safe defaults', () {
    final data = ExifData.empty(capturedAt: DateTime.utc(2026, 4, 14));
    expect(data.locationLabel, equals('unknown location'));
    expect(data.latitude, isNull);
    expect(data.longitude, isNull);
  });

  test('toPromptContext includes timestamp and location', () {
    final data = ExifData(
      capturedAt: DateTime.utc(2026, 4, 14, 14, 23, 0),
      latitude: 41.8781,
      longitude: -87.6298,
      locationLabel: 'Chicago',
    );
    final context = data.toPromptContext();
    expect(context, contains('2026-04-14'));
    expect(context, contains('Chicago'));
    expect(context, contains('41.8781'));
  });

  test('toPromptContext omits coordinates when null', () {
    final data = ExifData.empty(capturedAt: DateTime.utc(2026, 4, 14));
    final context = data.toPromptContext();
    expect(context, isNot(contains('coordinates')));
  });
}
