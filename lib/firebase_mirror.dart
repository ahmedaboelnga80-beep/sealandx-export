import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class FirebaseMirror {
  static const String _defaultUrl = "https://sealandx-master-default-rtdb.firebaseio.com/";

  // Retrieve Firebase URL from SharedPreferences
  static Future<String> getFirebaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String url = prefs.getString('firebase_rtdb_url') ?? _defaultUrl;
      if (!url.endsWith('/')) {
        url += '/';
      }
      return url;
    } catch (_) {
      return _defaultUrl;
    }
  }

  // Set Firebase URL in SharedPreferences
  static Future<void> setFirebaseUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!url.endsWith('/')) {
        url += '/';
      }
      await prefs.setString('firebase_rtdb_url', url);
    } catch (_) {}
  }

  // Primary function to compile the status of the current inspector and send it to Firebase RTDB
  static Future<void> updateState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? inspectorName = prefs.getString('inspector_name');
      if (inspectorName == null || inspectorName.trim().isEmpty) {
        debugPrint('FirebaseMirror: No inspector logged in. Skipping update.');
        return;
      }

      final String firebaseRootUrl = await getFirebaseUrl();
      final String safeUsername = inspectorName.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final String requestUrl = '${firebaseRootUrl}inspectors_export/$safeUsername.json';

      // 1. Gather all reports metadata
      final List<Map<String, dynamic>> reportsList = [];
      int pendingCount = 0;
      int syncedCount = 0;

      final pendingBox = await Hive.openBox('pending_syncs');
      final Set<String> pendingPaths = pendingBox.keys.cast<String>().toSet();

      if (kIsWeb) {
        final reportsBox = await Hive.openBox('web_reports');
        for (var key in reportsBox.keys) {
          final pathKey = key.toString();
          final data = reportsBox.get(key);
          if (data is Map) {
            final meta = Map<String, dynamic>.from(data);
            final containerNo = meta['containerNo'] ?? 'Unknown';
            final createdAt = meta['createdAt'] ?? DateTime.now().toIso8601String();
            final isPending = pendingPaths.contains(pathKey);
            
            if (isPending) {
              pendingCount++;
            } else {
              syncedCount++;
            }

            reportsList.add({
              'id': pathKey,
              'container_no': containerNo,
              'status': isPending ? 'pending' : 'synced',
              'created_at': createdAt,
            });
          }
        }
      } else {
        // Desktop / Mobile
        Directory? appDir;
        if (!kIsWeb && Platform.isAndroid) {
          final dirs = await getExternalStorageDirectories(type: StorageDirectory.documents);
          if (dirs != null && dirs.isNotEmpty) {
            appDir = dirs.first;
          }
        }
        appDir ??= await getApplicationDocumentsDirectory();
        
        final reportsDir = Directory(path.join(appDir.path, 'ContainerReports'));
        if (await reportsDir.exists()) {
          final entities = reportsDir.listSync();
          for (var entity in entities) {
            if (entity is Directory) {
              final folderPath = entity.path;
              final folderName = path.basename(folderPath);
              
              String containerNo = folderName;
              String createdAt = entity.statSync().modified.toIso8601String();
              
              final metaFile = File(path.join(folderPath, 'metadata.json'));
              if (await metaFile.exists()) {
                try {
                  final data = jsonDecode(await metaFile.readAsString());
                  if (data['containerNo'] != null && data['containerNo'].toString().trim().isNotEmpty) {
                    containerNo = data['containerNo'];
                  }
                  if (data['createdAt'] != null) {
                    createdAt = data['createdAt'].toString();
                  }
                } catch (_) {}
              }

              final isPending = pendingPaths.contains(folderPath);
              if (isPending) {
                pendingCount++;
              } else {
                syncedCount++;
              }

              reportsList.add({
                'id': folderPath,
                'container_no': containerNo,
                'status': isPending ? 'pending' : 'synced',
                'created_at': createdAt,
              });
            }
          }
        }
      }

      // Sort reports by created_at descending
      reportsList.sort((a, b) => b['created_at'].toString().compareTo(a['created_at'].toString()));

      // 2. Prepare payload
      final Map<String, dynamic> payload = {
        'username': inspectorName,
        'app': 'SealandX Export',
        'last_seen': DateTime.now().toIso8601String(),
        'pending_sync_count': pendingCount,
        'synced_count': syncedCount,
        'latest_reports': reportsList.take(20).toList(),
      };

      // 3. Make HTTP PUT request to Firebase RTDB
      final response = await http.put(
        Uri.parse(requestUrl),
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        debugPrint('FirebaseMirror: Successfully mirrored export state for $inspectorName');
      } else {
        debugPrint('FirebaseMirror: Failed to update state. Status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('FirebaseMirror Error updating state: $e');
    }
  }
}
