import 'dart:io';
import 'backend_service.dart';
import 'local_storage_service.dart';
import '../models/sync_progress.dart';

class BackendSyncService {
  final BackendService backend;
  final LocalStorageService storage;

  BackendSyncService(this.backend, this.storage);

  Stream<SyncProgress> sync() async* {
    final photos = await storage.pendingPhotos();
    if (photos.isEmpty) {
      yield const SyncProgress('Sin fotos pendientes.');
    } else {
      yield SyncProgress('Subiendo ${photos.length} fotos...');
      int done = 0;
      final uploadedIds = <int>[];
      for (final photo in photos) {
        try {
          final bytes = await File(photo.localPath).readAsBytes();
          final ts = _parseTs(photo.timestamp) ?? DateTime.now();
          await backend.uploadPhoto(bytes, photo.filename, ts);
          uploadedIds.add(photo.id);
          done++;
          yield SyncProgress('✓ ${photo.filename} ($done/${photos.length})');
        } catch (e) {
          yield SyncProgress('✗ ${photo.filename}: $e', isError: true);
        }
      }
      await storage.markPhotosUploaded(uploadedIds);
    }

    final entries = await storage.pendingLogEntries();
    if (entries.isEmpty) {
      yield const SyncProgress('Sin entradas de log pendientes.');
    } else {
      yield SyncProgress('Subiendo ${entries.length} entradas de log...');
      try {
        await backend.uploadLogs(entries.map((e) => e.entry).toList());
        await storage.markLogEntriesUploaded(entries.map((e) => e.id).toList());
        yield SyncProgress('✓ ${entries.length} entradas enviadas.');
      } catch (e) {
        yield SyncProgress('Error subiendo log: $e', isError: true);
      }
    }

    yield const SyncProgress('— Subida completada —');
  }

  DateTime? _parseTs(String? ts) {
    if (ts == null) return null;
    try {
      final sides = ts.split('T');
      if (sides.length != 2) return null;
      final d = sides[0].split('-');
      final t = sides[1].split('-');
      if (d.length != 3 || t.length != 3) return null;
      return DateTime(
        2000 + int.parse(d[0]), int.parse(d[1]), int.parse(d[2]),
        int.parse(t[0]), int.parse(t[1]), int.parse(t[2]),
      );
    } catch (_) {
      return null;
    }
  }
}
