import '../services/local_storage_service.dart';

class GalleryGroup {
  final String timestampRaw;
  final DateTime? timestamp;
  final List<StoredPhoto> photos;
  final String? eventType;
  final Map<String, double> sensors;

  const GalleryGroup({
    required this.timestampRaw,
    required this.photos,
    this.timestamp,
    this.eventType,
    this.sensors = const {},
  });

  bool get hasSensorData => sensors.isNotEmpty;
}
