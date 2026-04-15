import 'dart:io';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

class ExifData {
  final DateTime capturedAt;
  final double? latitude;
  final double? longitude;
  final String locationLabel;

  ExifData({
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    required this.locationLabel,
  });

  factory ExifData.empty({required DateTime capturedAt}) {
    return ExifData(
      capturedAt: capturedAt,
      latitude: null,
      longitude: null,
      locationLabel: 'unknown location',
    );
  }

  static String formatTimestamp(DateTime dt) {
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  String get utcTimestamp => capturedAt.toUtc().toIso8601String();

  String toPromptContext() {
    final coordLine = latitude != null
        ? 'coordinates: $latitude, $longitude\n'
        : '';
    return 'time: $utcTimestamp\n'
        'local time: ${formatTimestamp(capturedAt)}\n'
        'location: $locationLabel\n'
        '$coordLine';
  }
}

class ExifExtractor {
  Future<ExifData> extract(File photoFile) async {
    final now = DateTime.now();

    Position? position;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
        ).timeout(const Duration(seconds: 5));
      }
    } catch (_) {}

    String locationLabel = 'unknown location';
    if (position != null) {
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final pl = placemarks.first;
          final parts = [pl.name, pl.thoroughfare, pl.locality]
              .where((s) => s != null && s.isNotEmpty)
              .toList();
          locationLabel = parts.join(', ');
        }
      } catch (_) {}
    }

    return ExifData(
      capturedAt: now,
      latitude: position?.latitude,
      longitude: position?.longitude,
      locationLabel: locationLabel,
    );
  }
}
