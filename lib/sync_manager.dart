import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'firebase_mirror.dart';

class SyncManager {
  // Default Google Apps Script Web App URL & Sheet settings
  static const String _defaultAppsScriptUrl =
      'https://script.google.com/macros/s/AKfycbxWLxlMvOvCQ43r2yWQ8DYkHhZm-tlNLw_eizT1BUaJVxaL7bcq6uN-p1PnMQ30SUoN/exec';
  static const String _defaultSheetUrl =
      'https://docs.google.com/spreadsheets/d/1U4T67Ao9HoE-p9pQjE_FVP_Kba5fa258vbxP4L1p41M/edit?usp=sharing';
  static const String _defaultSheetName = 'All-Data';

  static Box? _syncBox;
  static bool _isSyncing = false;
  static String lastError = '';
  static bool get isSyncing => _isSyncing;

  // Notifier to update the UI on how many reports are pending sync
  static final ValueNotifier<int> pendingSyncsNotifier = ValueNotifier<int>(0);

  // Initialize the Hive box for pending syncs
  static Future<void> init() async {
    _syncBox = await Hive.openBox('pending_syncs');
    updateNotifier();
  }

  static void updateNotifier() {
    if (_syncBox != null) {
      pendingSyncsNotifier.value = _syncBox!.length;
    }
  }

  static int get pendingCount {
    return _syncBox?.length ?? 0;
  }

  // Add a report folder/path to the sync queue
  static Future<void> queueReport(String reportPath) async {
    if (_syncBox == null) await init();
    
    // Save report key with timestamp
    await _syncBox!.put(reportPath, DateTime.now().toIso8601String());
    updateNotifier();
    debugPrint('SyncManager: Queued report: $reportPath. Pending count: $pendingCount');

    // Trigger sync in background asynchronously
    syncPendingReports();
  }

  // Attempt to sync all pending reports in the queue
  static Future<void> syncPendingReports() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      if (_syncBox == null) await init();
      updateNotifier();

      final Set<String> failedThisSession = {};
      int processedCount = 0;
      int successCount = 0;

      while (true) {
        final pendingKeys = _syncBox!.keys
            .cast<String>()
            .where((k) => !failedThisSession.contains(k))
            .toList();

        if (pendingKeys.isEmpty) {
          break;
        }

        final reportPath = pendingKeys.first;
        debugPrint('SyncManager: Syncing report $reportPath. Remaining: ${pendingKeys.length}');
        processedCount++;

        bool success = await _syncReport(reportPath);
        if (success) {
          await _syncBox!.delete(reportPath);
          updateNotifier();
          successCount++;
          debugPrint('SyncManager: Successfully synced $reportPath');
        } else {
          failedThisSession.add(reportPath);
          debugPrint('SyncManager: Failed to sync $reportPath, keeping in queue');
        }
      }

      if (processedCount > 0 && successCount == processedCount) {
        lastError = '';
      }
    } catch (e) {
      lastError = 'خطأ في حلقة المزامنة: $e';
      debugPrint('SyncManager Error in sync loop: $e');
    } finally {
      _isSyncing = false;
      updateNotifier();
      FirebaseMirror.updateState();
    }
  }

  // Clear all pending syncs in the queue
  static Future<void> clearQueue() async {
    if (_syncBox == null) await init();
    await _syncBox!.clear();
    updateNotifier();
    lastError = '';
    debugPrint('SyncManager: Queue cleared');
  }

  // Sync a single report
  static Future<bool> _syncReport(String reportPath) async {
    Map<String, dynamic> meta = {};
    String notes = '';
    String containerNo = '';
    String createdAtStr = '';

    try {
      if (kIsWeb) {
        // Web Mode: Load from Hive
        final boxReports = Hive.box('web_reports');
        final rawMeta = boxReports.get(reportPath);
        if (rawMeta == null) return true; // Report was deleted, remove from sync queue
        
        meta = Map<String, dynamic>.from(rawMeta as Map);
        containerNo = meta['containerNo'] ?? '';
        createdAtStr = meta['createdAt'] ?? DateTime.now().toIso8601String();
        notes = meta['report'] ?? '';
      } else {
        // Mobile/Desktop Mode: Load from File
        final metaFile = File(path.join(reportPath, 'metadata.json'));
        if (!await metaFile.exists()) {
          lastError = 'ملف البيانات غير موجود لتقرير: $reportPath';
          return true; // Report folder deleted, remove from queue
        }
        
        try {
          meta = jsonDecode(await metaFile.readAsString());
          containerNo = meta['containerNo'] ?? '';
          createdAtStr = meta['createdAt'] ?? DateTime.now().toIso8601String();
        } catch (e) {
          lastError = 'فشل قراءة ملف JSON للتقرير: $e';
          return false;
        }

        final reportFile = File(path.join(reportPath, 'report.txt'));
        if (await reportFile.exists()) {
          notes = await reportFile.readAsString();
        } else if (meta['report'] != null) {
          notes = meta['report'].toString();
        }
      }

      if (containerNo.trim().isEmpty) {
        // No container number, remove from queue to avoid blocking
        lastError = 'رقم الحاوية فارغ لتقرير: $reportPath';
        return true;
      }

      // Generate the PDF document bytes
      Uint8List? pdfBytes;
      try {
        pdfBytes = await _generatePdfBytesForSync(reportPath, meta, notes);
      } catch (pdfError) {
        lastError = 'فشل في إنشاء ملف الـ PDF: $pdfError';
        debugPrint('SyncManager: PDF Generation failed: $pdfError');
      }

      String? pdfBase64;
      if (pdfBytes != null) {
        pdfBase64 = base64Encode(pdfBytes);
      }

      // Format date nicely
      String formattedDate = createdAtStr;
      try {
        final dt = DateTime.parse(createdAtStr);
        formattedDate = DateFormat('yyyy-MM-dd HH:mm').format(dt);
      } catch (_) {}

      // Get configuration from Hive settings Box
      final settingsBox = Hive.box('settings');
      String appsScriptUrl = settingsBox.get('sync_apps_script_url', defaultValue: '') as String;
      if (appsScriptUrl.trim().isEmpty) {
        appsScriptUrl = _defaultAppsScriptUrl;
      }
      String sheetUrl = settingsBox.get('sync_sheet_url', defaultValue: '') as String;
      if (sheetUrl.trim().isEmpty) {
        sheetUrl = _defaultSheetUrl;
      }
      String sheetName = settingsBox.get('sync_sheet_name', defaultValue: '') as String;
      if (sheetName.trim().isEmpty) {
        sheetName = _defaultSheetName;
      }

      if (appsScriptUrl.trim().isEmpty) {
        lastError = 'رابط Google Apps Script غير مضبوط في الإعدادات';
        debugPrint('SyncManager: Google Apps Script Web App URL is not set.');
        return false;
      }

      // Build the payload for Google Apps Script Web App
      final payload = {
        'action': 'addReport',
        'spreadsheetUrl': sheetUrl,
        'targetSheetName': sheetName,
        'containerNo': containerNo,
        'bookingNo': meta['bookingNo'] ?? '',
        'sealNo': meta['sealNo'] ?? '',
        'shippers': meta['shippers'] ?? '',
        'size': meta['size'] ?? '',
        'type': meta['type'] ?? '',
        'line': meta['line'] ?? '', // Location / Yard
        'shippingLine': meta['shippingLine'] ?? '',
        'dmg': meta['dmg'] ?? 'NO', // Sealed status
        'inspector': meta['inspector'] ?? '',
        'sealingPerson': meta['sealingPerson'] ?? '',
        'createdAt': formattedDate,
        'report': notes,
        'pdfBase64': pdfBase64 ?? '',
      };

      debugPrint('SyncManager: Sending export report to Google Apps Script Web App...');
      final response = await _postWithRedirects(
        appsScriptUrl,
        {'Content-Type': 'application/json'},
        jsonEncode(payload),
      );

      bool isSuccess = false;
      if (response.statusCode == 200) {
        try {
          final resObj = jsonDecode(response.body);
          if (resObj['status'] == 'success') {
            debugPrint('SyncManager: Google Apps Script accepted the export report ✓');
            isSuccess = true;
          } else {
            lastError = 'خطأ من Apps Script: ${resObj['message'] ?? response.body}';
            debugPrint('SyncManager: $lastError');
          }
        } catch (e) {
          if (response.body.contains('success')) {
            debugPrint('SyncManager: Google Apps Script response body contains success string ✓');
            isSuccess = true;
          } else {
            lastError = 'فشل تحليل رد Apps Script: ${response.body}';
            debugPrint('SyncManager: $lastError');
          }
        }
      } else {
        lastError = 'خطأ كود (${response.statusCode}) من Apps Script';
        debugPrint('SyncManager: Google Apps Script returned status ${response.statusCode}: ${response.body}');
      }

      if (isSuccess) {
        // Update local metadata: set synced = true
        meta['synced'] = true;
        if (kIsWeb) {
          final boxReports = Hive.box('web_reports');
          await boxReports.put(reportPath, meta);
        } else {
          final metaFile = File(path.join(reportPath, 'metadata.json'));
          await metaFile.writeAsString(jsonEncode(meta));
        }
        return true;
      }
    } catch (e) {
      lastError = 'فشل الاتصال: $e';
      debugPrint('SyncManager sync error for $reportPath: $e');
    }
    return false;
  }

  // Generate PDF bytes in background for cloud sync
  static Future<Uint8List?> _generatePdfBytesForSync(
      String reportPath, Map<String, dynamic> meta, String notes) async {
    try {
      final pdf = pw.Document();

      pw.MemoryImage? logoImage;
      try {
        final logoData = await rootBundle.load('assets/sealand_logo.png');
        logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
      } catch (_) {}

      final helvetica = pw.Font.helvetica();
      final helveticaBold = pw.Font.helveticaBold();

      String cleanText(Object? val) {
        if (val == null) return "N/A";
        String s = val.toString().trim();
        if (s.isEmpty) return "N/A";
        return s.replaceAll(RegExp(r'[^\x20-\x7E\n\r\t]+'), '').trim();
      }

      final Map<String, String> partMap = {
        'part_0': 'REAR DOOR',
        'part_1': 'SEAL',
        'part_2': 'DOCUMENT',
      };

      // Load images for export parts (0: Rear Door, 1: SEAL, 2: Document)
      final List<Map<String, dynamic>> activeParts = [];

      for (int i = 0; i < 3; i++) {
        final partId = 'part_$i';
        Uint8List? imgBytes;

        if (kIsWeb) {
          final boxImages = Hive.box('web_images');
          final key = '${reportPath}_$partId';
          if (boxImages.containsKey(key)) {
            final base64Img = boxImages.get(key);
            if (base64Img != null && base64Img is String) {
              try {
                imgBytes = base64Decode(base64Img);
              } catch (_) {}
            }
          }
        } else {
          final imgPath = path.join(reportPath, '$partId.jpg');
          final imgFile = File(imgPath);
          if (await imgFile.exists()) {
            imgBytes = await imgFile.readAsBytes();
          }
        }

        if (imgBytes != null) {
          activeParts.add({
            'id': partId,
            'name': partMap[partId] ?? 'PHOTO ${i + 1}',
            'bytes': imgBytes,
          });
        }
      }

      // If activeParts is empty on desktop, fallback to any .jpg file in the directory
      if (!kIsWeb && activeParts.isEmpty) {
        try {
          final dir = Directory(reportPath);
          if (await dir.exists()) {
            final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList();
            for (var f in files) {
              activeParts.add({
                'id': path.basenameWithoutExtension(f.path),
                'name': path.basenameWithoutExtension(f.path).toUpperCase(),
                'bytes': await f.readAsBytes(),
              });
            }
          }
        } catch (_) {}
      }

      final isSealed = meta['dmg'] == 'YES';

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          theme: pw.ThemeData.withFont(base: helvetica, bold: helveticaBold),
          build: (pw.Context context) {
            return [
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'DATE: ${DateFormat('yyyy-MM-dd').format(DateTime.now())}  TIME: ${DateFormat('HH:mm').format(DateTime.now())}',
                          style: const pw.TextStyle(
                            fontSize: 9,
                            color: PdfColors.grey600,
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Text(
                          'SEALANDX INTEGRATED LOGISTICS',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.grey700,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'SEAL Status Report',
                          style: pw.TextStyle(
                            fontSize: 17,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.blue800,
                          ),
                        ),
                      ],
                    ),
                    if (logoImage != null) pw.Image(logoImage, height: 70),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  border: pw.Border.all(color: PdfColors.grey300),
                ),
                child: pw.Column(
                  children: [
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'BOOKING: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['bookingNo']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'SHIPPERS: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['shippers']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'SEAL NO: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['sealNo']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 6),
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'CONTAINER NO: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['containerNo']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'SIZE: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['size']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'TYPE: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['type']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 6),
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'LINE: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['shippingLine']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'LOCATION: ',
                                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                                ),
                                pw.TextSpan(
                                  text: cleanText(meta['line']).toUpperCase(),
                                ),
                              ],
                            ),
                          ),
                        ),
                        pw.Expanded(
                          child: pw.RichText(
                            text: pw.TextSpan(
                              children: [
                                pw.TextSpan(
                                  text: 'SEALED: ',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    color: isSealed ? PdfColors.green : PdfColors.red,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: isSealed ? 'YES' : 'NO',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    color: isSealed ? PdfColors.green : PdfColors.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.Divider(thickness: 2, color: PdfColors.teal),
              pw.SizedBox(height: 10),

              // Images Grid
              if (activeParts.isNotEmpty)
                pw.Center(
                  child: pw.Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: pw.WrapAlignment.center,
                    children: activeParts.map((p) {
                      final image = pw.MemoryImage(p['bytes'] as Uint8List);
                      final isRearDoor = p['id'].toString().contains('part_0') ||
                          p['name'].toString().contains('REAR');
                      return pw.Container(
                        width: isRearDoor ? 500 : 260,
                        padding: const pw.EdgeInsets.all(5),
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.grey300),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Center(
                              child: pw.Image(
                                image,
                                height: isRearDoor ? 350 : 180,
                                width: isRearDoor ? 490 : 250,
                                fit: pw.BoxFit.contain,
                              ),
                            ),
                            pw.SizedBox(height: 5),
                            pw.Text(
                              p['name'].toString(),
                              style: pw.TextStyle(
                                fontSize: 10,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),

              pw.SizedBox(height: 20),
              pw.Text(
                'REPORT CONTENT:',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.teal,
                ),
              ),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(5),
                  ),
                ),
                child: pw.Text(
                  notes.trim().isEmpty ? 'SEAL HAS BEEN AFFIXED' : cleanText(notes),
                  style: const pw.TextStyle(fontSize: 11),
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.RichText(
                    text: pw.TextSpan(
                      children: [
                        pw.TextSpan(
                          text: 'INSPECTOR: ',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                        pw.TextSpan(
                          text: cleanText(meta['inspector']).toUpperCase(),
                        ),
                      ],
                    ),
                  ),
                  pw.RichText(
                    text: pw.TextSpan(
                      children: [
                        pw.TextSpan(
                          text: 'SEALING PERSON: ',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                        pw.TextSpan(
                          text: cleanText(meta['sealingPerson']).toUpperCase(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 40),
              pw.Row(
                children: [
                  pw.Text(
                    'DATE: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey600,
                    ),
                  ),
                  pw.Spacer(),
                  pw.Text(
                    'Generated by SealandX App',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey600,
                    ),
                  ),
                ],
              ),
            ];
          },
        ),
      );

      return await pdf.save();
    } catch (e) {
      debugPrint('Error generating PDF bytes for sync: $e');
      return null;
    }
  }

  // Helper function to handle HTTP POST requests with redirects
  static Future<http.Response> _postWithRedirects(
      String url, Map<String, String> headers, String body) async {
    if (kIsWeb) {
      return await http.post(
        Uri.parse(url),
        headers: headers,
        body: body,
      ).timeout(const Duration(seconds: 60));
    }

    final client = http.Client();
    try {
      var uri = Uri.parse(url);
      var request = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..body = body
        ..followRedirects = false;

      var streamedResponse = await client.send(request).timeout(const Duration(seconds: 60));
      var response = await http.Response.fromStream(streamedResponse);

      int redirectCount = 0;
      while ((response.statusCode == 301 ||
              response.statusCode == 302 ||
              response.statusCode == 303 ||
              response.statusCode == 307 ||
              response.statusCode == 308) &&
          redirectCount < 5) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl == null || redirectUrl.isEmpty) break;

        uri = Uri.parse(redirectUrl);

        if (response.statusCode == 301 ||
            response.statusCode == 302 ||
            response.statusCode == 303) {
          request = http.Request('GET', uri)..followRedirects = false;
        } else {
          request = http.Request('POST', uri)
            ..headers.addAll(headers)
            ..body = body
            ..followRedirects = false;
        }

        streamedResponse = await client.send(request).timeout(const Duration(seconds: 60));
        response = await http.Response.fromStream(streamedResponse);
        redirectCount++;
      }
      return response;
    } finally {
      client.close();
    }
  }
}
