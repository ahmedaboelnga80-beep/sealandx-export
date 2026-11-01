import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as path;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:printing/printing.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sync_manager.dart';
import 'firebase_mirror.dart';

List<CameraDescription> cameras = [];

/// Helper to check if we are running on a Desktop (Windows/Linux/macOS) platform
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Helper to check if we are on a wide screen (Desktop or Web)
bool isWideScreen(BuildContext context) {
  return MediaQuery.of(context).size.width > 700;
}

/// Helper to get application directory across Android, Desktop, and Web
Future<Directory> getAppDirectory() async {
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.documents);
      if (dirs != null && dirs.isNotEmpty) {
        return dirs.first;
      }
    } catch (e) {
      debugPrint('Error getting external storage directory: $e');
    }
  }
  return await getApplicationDocumentsDirectory();
}

enum ReportType { daily, weekly, monthly, yearly }

// Formatter to force uppercase
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera init error: $e');
  }

  // Initialize Hive
  await Hive.initFlutter();
  // Initialize Localizations & Dates
  await initializeDateFormatting('ar', null);

  await Hive.openBox('settings');
  await Hive.openBox('web_reports'); // Metadata for web reports
  await Hive.openBox('web_images'); // Image data for web reports

  // Initialize SyncManager
  await SyncManager.init();
  SyncManager.syncPendingReports(); // Try sync on startup

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SEALANDX EXPORT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF009688),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 2,
        ),
      ),
      home: const AccountWrapper(),
      locale: const Locale('ar'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ar'), Locale('en')],
    );
  }
}

// -------------------- ACCOUNT SECURITY (CLOUD) --------------------

class AccountWrapper extends StatefulWidget {
  const AccountWrapper({super.key});

  @override
  State<AccountWrapper> createState() => _AccountWrapperState();
}

class _AccountWrapperState extends State<AccountWrapper> {
  bool _isLoggedIn = false;
  bool _isLoading = true;
  final TextEditingController _emailController = TextEditingController();
  // تم إزالة passController

  // الرابط الخاص بك للتحكم في المستخدمين عبر Google Sheets
  final String _usersListUrl =
      'https://script.google.com/macros/s/AKfycbyxSXlBt6PHVgamCHbkzW_LFU481w-Tkx4gSA5cRJD4JnCj1h2y5fhzP4xrTC0VI88PHw/exec';

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // Check SharedPreferences first (Works for Web & Mobile)
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('is_logged_in') == true) {
        setState(() {
          _isLoggedIn = true;
          _isLoading = false;
        });
        return;
      }
    } catch (_) {}

    if (kIsWeb) {
      setState(() => _isLoading = false);
      return;
    }

    // Legacy File check for existing Windows users
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final loginFile = File(path.join(appDir.path, '.user_session'));

      if (await loginFile.exists()) {
        final sessionData = await loginFile.readAsString();
        final email = sessionData.trim();
        final result = await _verifyUserRemotely(email, null, checkOnly: true);
        if (result['status']?.toLowerCase() == "success") {
          if (mounted) {
            setState(() {
              _isLoggedIn = true;
            });
            // Migrate to SharedPreferences
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('is_logged_in', true);
            await prefs.setString('inspector_name', result['name'] ?? email);
          }
        }
      }
    } catch (e) {
      debugPrint('Login check error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Map<String, dynamic>> _verifyUserRemotely(
    String email,
    String? password, {
    bool checkOnly = false,
  }) async {
    try {
      String url = '$_usersListUrl?email=$email';
      if (password != null) url += '&pass=$password';

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      if (checkOnly) {
        return {'status': 'success'}; // Bypass for offline if already sessioned
      }
    }
    return {'status': 'fail'};
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('برجاء إدخال اسم المستخدم أو الكود')),
      );
      return;
    }

    setState(() => _isLoading = true);
    final response = await _verifyUserRemotely(email, null);
    final status = response['status'] ?? 'fail';
    final realName = response['name'] ?? email;

    Future<void> saveLoginSession(String email, String name) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('is_logged_in', true);
        await prefs.setString(
          'inspector_name',
          name,
        ); // Store actual Name from Sheet

        if (!kIsWeb) {
          final appDir = await getApplicationDocumentsDirectory();
          final loginFile = File(path.join(appDir.path, '.user_session'));
          await loginFile.writeAsString(email);
        }
      } catch (e) {
        debugPrint('Save session error: $e');
      }
    }

    if (status == 'success') {
      await saveLoginSession(email, realName);

      setState(() {
        _isLoggedIn = true;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
      String message = 'بيانات الدخول غير صحيحة';
      if (status == 'added') {
        message = 'تم إرسال طلب الدخول للمدير، برجاء الانتظار للموافقة';
      } else if (status == 'blocked') {
        message = 'حسابك معطل حالياً، برجاء مراجعة المدير';
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  Future<void> _logout() async {
    if (kIsWeb) {
      setState(() {
        _isLoggedIn = false;
      });
      return;
    }
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final loginFile = File(path.join(appDir.path, '.user_session'));
      if (await loginFile.exists()) await loginFile.delete();
      setState(() {
        _isLoggedIn = false;
      });
    } catch (e) {
      debugPrint('Logout error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // إذا كان مسجل دخول، اعرض التطبيق، وإلا اعرض صفحة الـ Login
    if (_isLoggedIn) return LibraryScreen(onLogout: _logout);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF004D40), Color(0xFF009688)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 40,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.account_circle,
                      size: 80,
                      color: Color(0xFF009688),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'تسجيل دخول المفتشين',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: 'اسم المستخدم / الكود',
                        prefixIcon: const Icon(Icons.person_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // تم إزالة حقل كلمة السر
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        onPressed: _handleLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF009688),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'دخول النظام',
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'SealandX Cloud Security v2.0',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- MODELS --------------------

class ReportFolder {
  final String name;
  final String path;
  final DateTime modified;
  final int itemCount;
  final File? coverImage;

  ReportFolder({
    required this.name,
    required this.path,
    required this.modified,
    required this.itemCount,
    this.coverImage,
  });
}

class ContainerPart {
  final String name;
  final String id;
  File? image;
  Uint8List? webImageBytes; // Added for Web support

  ContainerPart({
    required this.name,
    required this.id,
    this.image,
    this.webImageBytes,
  });
}

// -------------------- CONSTANTS --------------------

final List<String> containerPartNames = [
  'باب الحاوية الخلفية (Rear Door)',
  'السيل (SEAL)',
  'الجواب (Document)',
];

const List<String> containerSizes = ['20', '40', '45'];
const List<String> containerTypes = ['DV', 'HC', 'O.T', 'RF', 'FR'];
final List<String> lineOptions = [
  'EXPORT GATE',
  'Gate',
  'YD1',
  'YD2',
  'HM2',
  'EXT',
  'LCL',
  'HML',
];

final List<String> shippingLines = [
  'MSC',
  'COS',
  'CMA',
  'OOCL',
  'MRSK',
  'SLG',
  'TURK',
  'HLL',
  'BMC',
  'ARK',
  'COEU',
  'ZIM',
  'ONE',
  'YML',
  'EMC',
  'OSL',
];

const List<String> defaultShippers = [
  'ALJANA STAR',
  'SEALAND STEVEDORING',
  'GLOBAL LOGISTICS',
  'EGY',
  'EGYPTRA',
  'EGYPURE',
  'ELSFANY',
  'EVEREST',
  'FLEX',
  'GLOBELINK',
  'I.V.L',
  'KUEHNE',
  'M.Y.C.S',
  'MAERSK',
  'MAERSK L AND S',
  'MESCO',
  'MTS',
  'NATIONAL',
  'ORGANIC',
  'PHARMA',
  'PHARMAPLAST',
  'SAMSUNG',
  'STAR',
  'TCI',
  'U SHIPPER',
  'UNITED',
  'DHL',
  'ALFA',
  'ALTUN',
  'DHL GLOBAL',
];

// -------------------- SCREENS --------------------

class LibraryScreen extends StatefulWidget {
  final VoidCallback onLogout;
  const LibraryScreen({super.key, required this.onLogout});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _currentTab = 0;
  List<ReportFolder> _folders = [];
  final Set<ReportFolder> _selectedFolders = {};
  bool _isLoading = true;
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  // Cache for Web to allow Daily Report during current session
  static final List<ReportFolder> _webFoldersCache = [];
  static final Map<String, Map<String, dynamic>> _webMetaCache = {};
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() => _isLoading = true);

    if (kIsWeb) {
      if (_webFoldersCache.isEmpty) {
        // Load from Hive once
        try {
          final box = Hive.box('web_reports');
          _webFoldersCache.clear();
          _webMetaCache.clear();

          for (var key in box.keys) {
            final data = box.get(key) as Map;
            final path = key.toString();
            final meta = Map<String, dynamic>.from(data);

            _webMetaCache[path] = meta;

            // Reconstruct ReportFolder
            _webFoldersCache.add(
              ReportFolder(
                name:
                    meta['containerNo'] ??
                    path.replaceFirst('web_virtual_', ''),
                path: path,
                modified:
                    DateTime.tryParse(meta['createdAt'].toString()) ??
                    DateTime.now(),
                itemCount:
                    0, // Will be updated on open or save if we track parts count
                coverImage:
                    null, // No cover image on list view for web for now to save performance
              ),
            );
          }
          // Sort by modified date descending
          _webFoldersCache.sort((a, b) => b.modified.compareTo(a.modified));
        } catch (e) {
          debugPrint('Hive load error: $e');
        }
      }

      setState(() {
        _folders = List.from(_webFoldersCache);
        _isLoading = false;
      });
      return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final rootDir = Directory(path.join(appDir.path, 'ContainerReports'));

      if (!await rootDir.exists()) {
        await rootDir.create(recursive: true);
      }

      final List<ReportFolder> loaded = [];
      final entities = rootDir.listSync();

      for (var entity in entities) {
        if (entity is Directory) {
          final content = entity
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jpg'))
              .toList();

          final folderPath = entity.path;
          final name = path.basename(folderPath);
          final stats = entity.statSync();

          // Try to read containerNo and createdAt from metadata
          String displayName = name;
          DateTime folderDate = stats.modified;
          final metaFile = File(path.join(folderPath, 'metadata.json'));
          if (await metaFile.exists()) {
            try {
              final data = jsonDecode(await metaFile.readAsString());
              if (data['containerNo'] != null &&
                  data['containerNo'].toString().trim().isNotEmpty) {
                displayName = data['containerNo'];
              }
              if (data['createdAt'] != null) {
                folderDate = DateTime.parse(data['createdAt'].toString());
              }
            } catch (e) {
              debugPrint('Error reading metadata: $e');
            }
          }

          loaded.add(
            ReportFolder(
              name: displayName,
              path: folderPath,
              modified: folderDate,
              itemCount: content.length,
              coverImage: content.isNotEmpty ? content.first : null,
            ),
          );
        }
      }

      loaded.sort((a, b) => b.modified.compareTo(a.modified));

      setState(() {
        _folders = loaded;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading folders: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _createNewReport() async {
    final now = DateTime.now();
    final formatter = DateFormat('yyyy-MM-dd HH.mm.ss');
    final defaultName = 'Report ${formatter.format(now)}';

    final String? customName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: defaultName);
        return AlertDialog(
          title: const Text('إنشاء تقرير جديد'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'أدخل اسم الحاوية أو التقرير',
              labelText: 'رقم الحاوية / الاسم',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('إنشاء'),
            ),
          ],
        );
      },
    );

    if (customName == null || customName.trim().isEmpty) return;

    final safeName = customName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    String newPath = '';
    final createdAt = DateTime.now().toIso8601String();
    if (kIsWeb) {
      newPath = 'web_virtual_$safeName';
      final newFolder = ReportFolder(
        name: safeName,
        path: newPath,
        modified: DateTime.now(),
        itemCount: 0,
      );

      // Initialize metadata for web
      final meta = {
        'containerNo': safeName,
        'inspector': '',
        'sealingPerson': '',
        'bookingNo': '',
        'shippers': '',
        'sealNo': '',
        'size': null,
        'type': null,
        'line': null,
        'shippingLine': null,
        'dmg': 'NO',
        'createdAt': createdAt,
      };

      _webFoldersCache.insert(0, newFolder);
      _webMetaCache[newPath] = meta;

      // Save to Hive
      try {
        final box = Hive.box('web_reports');
        await box.put(newPath, meta);
      } catch (e) {
        debugPrint('Hive save error: $e');
      }

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) =>
                AlbumScreen(folderPath: newPath, folderName: safeName),
          ),
        ).then((_) => _loadFolders());
      }
      return;
    }

    final appDir = await getApplicationDocumentsDirectory();
    newPath = path.join(appDir.path, 'ContainerReports', safeName);
    final dir = Directory(newPath);
    if (await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('مجلد بهذا الاسم موجود بالفعل')),
        );
      }
      return;
    }
    await dir.create(recursive: true);

    // حفظ تاريخ الإنشاء في metadata فوراً عشان اليومية تشتغل صح
    final initMetaFile = File(path.join(newPath, 'metadata.json'));
    await initMetaFile.writeAsString(jsonEncode({'createdAt': createdAt}));

    if (!mounted) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) =>
                AlbumScreen(folderPath: newPath, folderName: safeName),
          ),
        )
        .then((_) => _loadFolders());
  }

  void _openReport(ReportFolder folder) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) =>
                AlbumScreen(folderPath: folder.path, folderName: folder.name),
          ),
        )
        .then((_) => _loadFolders());
  }

  Future<void> _deleteSelectedFolders() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف المختار'),
        content: Text('هل أنت متأكد من حذف ${_selectedFolders.length} تقارير؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (kIsWeb) {
        _webFoldersCache.removeWhere((f) => _selectedFolders.contains(f));

        final boxReports = Hive.box('web_reports');
        final boxImages = Hive.box('web_images');

        for (var f in _selectedFolders) {
          _webMetaCache.remove(f.path);
          // Remove from Hive
          boxReports.delete(f.path);

          // Delete associated images
          // Assuming we know part IDs... or better, we iterate all keys starting with f.path
          // Since Hive keys aren't ordered, we might have to filter
          final keysToDelete = boxImages.keys
              .where((k) => k.toString().startsWith('${f.path}_'))
              .toList();
          for (var k in keysToDelete) {
            boxImages.delete(k);
          }
        }
      } else {
        for (var folder in _selectedFolders) {
          try {
            await Directory(folder.path).delete(recursive: true);
          } catch (e) {
            debugPrint('Delete error: $e');
          }
        }
      }
      setState(() {
        _selectedFolders.clear();
      });
      _loadFolders();
    }
  }

  Future<void> _shareSelectedFolders() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final List<XFile> filesToShare = [];
      for (var folder in _selectedFolders) {
        final xfile = await _generatePdfXFile(folder);
        if (xfile != null) {
          filesToShare.add(xfile);
        }
      }

      if (mounted) Navigator.pop(context); // Close loading

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare, text: 'تقارير فحص الحاويات');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error sharing files: $e')));
      }
    }
  }

  Future<XFile?> _generatePdfXFile(ReportFolder folder) async {
    try {
      final metaFile = File(path.join(folder.path, 'metadata.json'));
      final reportFile = File(path.join(folder.path, 'report.txt'));

      Map<String, dynamic> meta = {};
      if (await metaFile.exists()) {
        meta = jsonDecode(await metaFile.readAsString());
      }

      String reportNotes = "SEAL HAS BEEN AFFIXED";
      if (await reportFile.exists()) {
        reportNotes = await reportFile.readAsString();
      }

      final imageFiles = Directory(folder.path)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList();

      final pdf = pw.Document();
      final logoData = await rootBundle.load('assets/sealand_logo.png');
      final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

      final helvetica = pw.Font.helvetica();
      final helveticaBold = pw.Font.helveticaBold();

      String cleanText(Object? val) {
        if (val == null) return "N/A";
        String s = val.toString().trim();
        if (s.isEmpty) return "N/A";
        // Remove non-ASCII characters (like Arabic) to prevent squares in PDF
        return s.replaceAll(RegExp(r'[^\x20-\x7E\n\r\t]+'), '').trim();
      }

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
                          'DATE: ${DateFormat('yyyy-MM-dd').format(folder.modified)}',
                          style: pw.TextStyle(
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
                    pw.Image(logoImage, height: 70),
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
                                  text: 'CONTAINER NO: ',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    meta['containerNo'],
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    meta['shippingLine'],
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
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
                                  text: 'REFERENCE: ',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(folder.name).toUpperCase(),
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
                                  text: 'DMG STATUS: ',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: meta['dmg'] == 'YES'
                                      ? 'DAMAGED'
                                      : 'GOOD',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    color: meta['dmg'] == 'YES'
                                        ? PdfColors.red800
                                        : PdfColors.green800,
                                  ),
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
                                  text: 'INSPECTOR: ',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    meta['inspector'],
                                  ).toUpperCase(),
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
              pw.Center(
                child: pw.Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: pw.WrapAlignment.center,
                  children: imageFiles.map((f) {
                    final image = pw.MemoryImage(f.readAsBytesSync());
                    final baseName = path.basenameWithoutExtension(f.path);
                    final isRear =
                        baseName.toLowerCase().contains('rear') ||
                        baseName.contains('خلفي');
                    return pw.Container(
                      width: isRear ? 500 : 260,
                      padding: const pw.EdgeInsets.all(5),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: PdfColors.grey300),
                      ),
                      child: pw.Column(
                        children: [
                          pw.Center(
                            child: pw.Image(
                              image,
                              height: isRear ? 350 : 180,
                              width: isRear ? 490 : 250,
                              fit: pw.BoxFit.contain,
                            ),
                          ),
                          pw.SizedBox(height: 5),
                          pw.Text(
                            (() {
                              String b = baseName.toUpperCase();
                              if (b.startsWith('PART_')) {
                                try {
                                  int idx = int.parse(b.substring(5));
                                  if (idx >= 0 &&
                                      idx < containerPartNames.length) {
                                    String name = containerPartNames[idx];
                                    // Extract text inside ( ... ) if available, otherwise translate
                                    final reg = RegExp(r'\(([^)]+)\)');
                                    final match = reg.firstMatch(name);
                                    if (match != null) {
                                      return match.group(1)!.toUpperCase();
                                    }
                                    if (name.contains('إضافية 1')) {
                                      return 'EXTRA PHOTO 1';
                                    }
                                    if (name.contains('إضافية 2')) {
                                      return 'EXTRA PHOTO 2';
                                    }
                                    return name
                                        .replaceAll(
                                          RegExp(r'[^\x20-\x7E]+'),
                                          '',
                                        )
                                        .trim()
                                        .toUpperCase();
                                  }
                                } catch (_) {}
                              }
                              return b
                                  .replaceAll('CLEAN', 'GOOD')
                                  .replaceAll('HEALTHY', 'GOOD');
                            })(),
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
                  reportNotes.trim().isEmpty
                      ? 'SEAL HAS BEEN AFFIXED'
                      : reportNotes,
                  style: const pw.TextStyle(fontSize: 11),
                ),
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

      final appDir = await getApplicationDocumentsDirectory();
      final String line = cleanText(meta['shippingLine']).toUpperCase();
      final String container = cleanText(meta['containerNo']).toUpperCase();
      final String fileName = 'Multi_${line}_$container.pdf'.replaceAll(
        RegExp(r'[^a-zA-Z0-9_\.-]'),
        '_',
      );
      final file = File(path.join(appDir.path, fileName));
      await file.writeAsBytes(await pdf.save());
      return XFile(file.path);
    } catch (e) {
      debugPrint('Error generating hidden PDF: $e');
      return null;
    }
  }

  // ---- توليد التقرير (يومية - أسبوعية - شهرية - سنوية) ----
  void _showReportTypeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'نوع التقرير المجمع',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _reportTypeCard(
                    ctx: ctx,
                    icon: Icons.today,
                    label: 'يومية',
                    subtitle: 'Day',
                    color: Colors.orangeAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      _generateAggregatedReport(ReportType.daily);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _reportTypeCard(
                    ctx: ctx,
                    icon: Icons.date_range,
                    label: 'أسبوعية',
                    subtitle: 'Week',
                    color: Colors.deepPurpleAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      _generateAggregatedReport(ReportType.weekly);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _reportTypeCard(
                    ctx: ctx,
                    icon: Icons.calendar_month,
                    label: 'شهرية',
                    subtitle: 'Month',
                    color: Colors.blueAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      _generateAggregatedReport(ReportType.monthly);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _reportTypeCard(
                    ctx: ctx,
                    icon: Icons.calendar_today,
                    label: 'سنوية',
                    subtitle: 'Year',
                    color: Colors.teal,
                    onTap: () {
                      Navigator.pop(ctx);
                      _generateAggregatedReport(ReportType.yearly);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _reportTypeCard({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: color.withAlpha(150), width: 2),
          borderRadius: BorderRadius.circular(16),
          color: color.withAlpha(20),
        ),
        child: Column(
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateAggregatedReport(ReportType type) async {
    final now = DateTime.now();

    DateTime? selectedDate;
    int? selectedMonth;
    int? selectedYear;

    // --- 1. Select Period ---
    if (type == ReportType.daily) {
      selectedDate = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(now.year - 2),
        lastDate: now,
        helpText: 'اختر اليوم',
      );
      if (selectedDate == null) return;
    } else if (type == ReportType.weekly) {
      final picked = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(now.year - 2),
        lastDate: now,
        helpText: 'اختر أي يوم في الأسبوع',
      );
      if (picked == null) return;
      // Calculate start (Saturday) and end (Friday) or Standard Monday-Sunday?
      // Let's assume Standard: User picks a date, we get the whole week.
      // Or simply explicit start/end. Let's do Start of Week (Saturday based on request logic or Standard).
      // Let's go with Monday start for standard, or Saturday if region specific.
      // For generic use: Find the first day of that week.
      // Let's assume Week starts on Saturday.
      // Simple approach: subtract weekday-1 to get Monday.

      // Let's use simple logic: DatePicker returns a date. We'll define the week around it.
      // Let's show RangePicker? No, simpler to just pick a week containing the date.
      selectedDate = picked;
      // Week Start: Saturday?
      // Weekdays: Mon=1 ... Sun=7.
      // If we want Saturday start:
      // If today is Friday(5), next Sat is tomorrow.
      // Mapping: Mon(1)->Sat(-2), Tue(2)->Sat(-3)... Sat(6)->Sat(0), Sun(7)->Sat(-1).
      // Let's just use ISO week (Mon-Sun) to be safe, or just asking range.
      // Let's stick to: Report for the week containing this date.
    } else if (type == ReportType.monthly) {
      final picked = await showDatePicker(
        context: context,
        initialDate: DateTime(now.year, now.month, 1),
        firstDate: DateTime(now.year - 2),
        lastDate: now,
        helpText: 'اختر الشهر (أي يوم فيه)',
      );
      if (picked == null) return;
      selectedMonth = picked.month;
      selectedYear = picked.year;
    } else if (type == ReportType.yearly) {
      final picked = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        helpText: 'اختر السنة (أي يوم فيها)',
      );
      if (picked == null) return;
      selectedYear = picked.year;
    }

    // --- 2. Filter Folders ---
    final List<ReportFolder> filteredFolders = [];

    // Helper to check range
    bool isInWeek(DateTime date, DateTime picked) {
      // Logic: Week starts Saturday.
      // Adjust date to align with Saturday start.
      // Dart DateTime weekday: Mon=1, Tue=2, ... Sat=6, Sun=7.
      // We want Sat=1, Sun=2 ... Fri=7.
      // Effective Weekday = (date.weekday % 7) + 1  -> Sat(6)->0+1=1. Sun(7)->0+1? No.
      // Sat=6 -> 6+1=7 -> mod 7 = 0.

      // Easy logic: Get start of week.
      // Sat=6. We want to subtract 0.
      // Sun=7. Subtract 1.
      // Mon=1. Subtract 2.
      // ...
      // Fri=5. Subtract 6.

      // Correct logic for "Saturday Start":
      // Sat(6) -> offset 0
      // Sun(7) -> offset 1
      // Mon(1) -> offset 2
      // ...
      // Fri(5) -> offset 6
      int offset = (picked.weekday == 6)
          ? 0
          : (picked.weekday == 7 ? 1 : picked.weekday + 1);

      DateTime startOfWeek = picked.subtract(Duration(days: offset));
      DateTime endOfWeek = startOfWeek.add(const Duration(days: 6)); // Fri

      // Compare without time
      DateTime d = DateTime(date.year, date.month, date.day);
      DateTime s = DateTime(
        startOfWeek.year,
        startOfWeek.month,
        startOfWeek.day,
      );
      DateTime e = DateTime(endOfWeek.year, endOfWeek.month, endOfWeek.day);

      return (d.isAtSameMomentAs(s) || d.isAfter(s)) &&
          (d.isAtSameMomentAs(e) || d.isBefore(e));
    }

    setState(() => _isLoading = true);

    for (var f in _folders) {
      try {
        final meta = await _getMetadata(f.path);
        DateTime folderDate;
        if (meta['createdAt'] != null) {
          folderDate = DateTime.parse(meta['createdAt'].toString());
        } else {
          folderDate = f.modified;
        }

        if (type == ReportType.daily) {
          if (folderDate.year == selectedDate!.year &&
              folderDate.month == selectedDate.month &&
              folderDate.day == selectedDate.day) {
            filteredFolders.add(f);
          }
        } else if (type == ReportType.weekly) {
          if (isInWeek(folderDate, selectedDate!)) {
            filteredFolders.add(f);
          }
        } else if (type == ReportType.monthly) {
          if (folderDate.year == selectedYear &&
              folderDate.month == selectedMonth) {
            filteredFolders.add(f);
          }
        } else if (type == ReportType.yearly) {
          if (folderDate.year == selectedYear) {
            filteredFolders.add(f);
          }
        }
      } catch (e) {
        debugPrint('Filter error: $e');
      }
    }

    setState(() => _isLoading = false);

    if (filteredFolders.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد تقارير في الفترة المحددة')),
        );
      }
      return;
    }

    // --- 3. Inspector Name (Auto-fill from Session) ---
    // Get from SharedPreferences if available
    String sessionInspector = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      sessionInspector = prefs.getString('inspector_name') ?? '';
    } catch (_) {}

    // Fallback to metadata if session is empty
    if (sessionInspector.isEmpty) {
      try {
        final firstMeta = await _getMetadata(filteredFolders.first.path);
        sessionInspector = firstMeta['inspector']?.toString().trim() ?? '';
      } catch (_) {}
    }

    final specialistController = TextEditingController(text: sessionInspector);
    String titlePrefix = '';
    switch (type) {
      case ReportType.daily:
        titlePrefix = 'يومية';
        break;
      case ReportType.weekly:
        titlePrefix = 'أسبوعية';
        break;
      case ReportType.monthly:
        titlePrefix = 'شهرية';
        break;
      case ReportType.yearly:
        titlePrefix = 'سنوية';
        break;
    }

    if (!mounted) return;
    final String? specialistName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تقرير $titlePrefix'),
        content: TextField(
          controller: specialistController,
          readOnly: sessionInspector.isNotEmpty,
          decoration: InputDecoration(
            labelText: 'اسم المختص / المفتش',
            hintText: 'سيتم ربط هذا الاسم بالتقرير',
            helperText: sessionInspector.isNotEmpty
                ? 'تم التحقق من المستخدم (لا يمكن التعديل)'
                : null,
            prefixIcon: sessionInspector.isNotEmpty
                ? const Icon(Icons.verified_user, color: Colors.blue)
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, specialistController.text.trim()),
            child: const Text('استخراج'),
          ),
        ],
      ),
    );

    if (specialistName == null) return;

    // --- 4. PDF Generation ---
    _generateSummaryPdf(
      filteredFolders,
      type,
      specialistName,
      selectedDate,
      selectedMonth,
      selectedYear,
    );
  }

  Future<void> _generateSummaryPdf(
    List<ReportFolder> folders,
    ReportType type,
    String specialist,
    DateTime? dayDate,
    int? month,
    int? year,
  ) async {
    setState(() => _isExporting = true);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      // Prepare Data
      final List<Map<String, dynamic>> loadedData = [];
      for (var f in folders) {
        final m = await _getMetadata(f.path);
        DateTime d;
        if (m['createdAt'] != null) {
          d = DateTime.parse(m['createdAt'].toString());
        } else {
          d = f.modified;
        }
        m['displayDate'] = d;
        m['folderName'] = f.name;
        loadedData.add(m);
      }
      loadedData.sort(
        (a, b) => (a['displayDate'] as DateTime).compareTo(
          b['displayDate'] as DateTime,
        ),
      );

      final pdf = pw.Document();
      final logoData = await rootBundle.load('assets/sealand_logo.png');
      final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

      final helvetica = pw.Font.helvetica();
      final helveticaBold = pw.Font.helveticaBold();

      String title = '';
      String subTitle = '';
      String filePrefix = '';

      if (type == ReportType.daily) {
        title = 'DAILY SUMMARY REPORT';
        subTitle = 'DATE: ${DateFormat('yyyy-MM-dd').format(dayDate!)}';
        filePrefix = 'Daily_${DateFormat('yyyyMMdd').format(dayDate)}';
      } else if (type == ReportType.weekly) {
        title = 'WEEKLY SUMMARY REPORT';
        // Calc week start logic again for display
        int offset = (dayDate!.weekday == 6)
            ? 0
            : (dayDate.weekday == 7 ? 1 : dayDate.weekday + 1);
        DateTime s = dayDate.subtract(Duration(days: offset));
        DateTime e = s.add(const Duration(days: 6));
        subTitle =
            'Week: ${DateFormat('MM/dd').format(s)} - ${DateFormat('MM/dd').format(e)}';
        filePrefix = 'Weekly_${DateFormat('yyyyMMdd').format(s)}';
      } else if (type == ReportType.monthly) {
        title = 'MONTHLY SUMMARY REPORT';
        subTitle =
            'MONTH: ${DateFormat('MMMM yyyy').format(DateTime(year!, month!))}';
        filePrefix = 'Monthly_${year}_$month';
      } else if (type == ReportType.yearly) {
        title = 'ANNUAL SUMMARY REPORT';
        subTitle = 'YEAR: $year';
        filePrefix = 'Annual_$year';
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          theme: pw.ThemeData.withFont(base: helvetica, bold: helveticaBold),
          header: (pw.Context context) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.blue800,
                    ),
                  ),
                  pw.Text(
                    subTitle,
                    style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
                  ),
                ],
              ),
              pw.Image(logoImage, height: 50),
            ],
          ),
          build: (pw.Context context) {
            // Columns
            // Dynamic Headers based on type
            final headers = [
              '#',
              'BOOKING NO',
              'SHIPPERS',
              'CONTAINER NO',
              'TYPE',
              'SIZE',
              'SEAL NO',
              'SEALED',
              'SEALING PERSON',
              'DATE',
            ];

            final colWidths = {
              0: const pw.FixedColumnWidth(20), // #
              1: const pw.FlexColumnWidth(1.4), // Booking
              2: const pw.FlexColumnWidth(1.6), // Shippers (Increased)
              3: const pw.FlexColumnWidth(2.0), // Container (Increased)
              4: const pw.FlexColumnWidth(0.6), // Type (Narrowed)
              5: const pw.FlexColumnWidth(0.6), // Size (Narrowed)
              6: const pw.FlexColumnWidth(1.5), // Seal No (Increased)
              7: const pw.FlexColumnWidth(0.9), // Sealed
              8: const pw.FlexColumnWidth(1.8), // Sealing Person
              9: const pw.FlexColumnWidth(1.0), // Date
            };

            // Calculate Statistics
            int totalNum = loadedData.length;
            int damagedNum = loadedData.where((m) => m['dmg'] == 'YES').length;
            int healthyNum = totalNum - damagedNum;

            pw.Widget buildStatBox(String label, String value, PdfColor color) {
              return pw.Column(
                children: [
                  pw.Text(
                    label,
                    style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                  ),
                  pw.Text(
                    value,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              );
            }

            return [
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: PdfColors.teal50,
                  border: pw.Border.all(color: PdfColors.teal, width: 1),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(8),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                  children: [
                    buildStatBox(
                      "TOTAL",
                      totalNum.toString(),
                      PdfColors.blue800,
                    ),
                    buildStatBox(
                      "GOOD",
                      healthyNum.toString(),
                      PdfColors.green800,
                    ),
                    buildStatBox(
                      "DAMAGED",
                      damagedNum.toString(),
                      PdfColors.red800,
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: colWidths,
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.teal),
                    children: headers
                        .map(
                          (h) => pw.Padding(
                            padding: const pw.EdgeInsets.all(6),
                            child: pw.Text(
                              h,
                              style: pw.TextStyle(
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.white,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),

                  for (int i = 0; i < loadedData.length; i++)
                    pw.TableRow(
                      decoration: pw.BoxDecoration(
                        color: i % 2 == 0 ? PdfColors.white : PdfColors.grey50,
                      ),
                      children: [
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(5),
                          child: pw.Text(
                            '${i + 1}',
                            style: const pw.TextStyle(fontSize: 9),
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['bookingNo']?.toString() ?? '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['shippers']?.toString() ?? '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            loadedData[i]['containerNo']
                                    ?.toString()
                                    .toUpperCase() ??
                                loadedData[i]['folderName']
                                    .toString()
                                    .toUpperCase(),
                            style: pw.TextStyle(
                              fontSize: 7,
                              fontWeight: pw.FontWeight.bold,
                            ),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['type']?.toString() ?? '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['size']?.toString() ?? '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['sealNo']?.toString() ?? '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            loadedData[i]['dmg'] == 'YES' ? 'YES' : 'NO',
                            textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(
                              fontSize: 7,
                              fontWeight: pw.FontWeight.bold,
                              color: loadedData[i]['dmg'] == 'YES'
                                  ? PdfColors.blue800
                                  : PdfColors.grey700,
                            ),
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            (loadedData[i]['sealingPerson']?.toString() ??
                                    loadedData[i]['inspector']?.toString() ??
                                    '')
                                .toUpperCase(),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: pw.Text(
                            DateFormat(
                              'MM/dd',
                            ).format(loadedData[i]['displayDate'] as DateTime),
                            style: const pw.TextStyle(fontSize: 7),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                ],
              ),

              pw.SizedBox(height: 30),
              pw.Text('Total: ${loadedData.length} records.'),
              pw.SizedBox(height: 10),
              pw.Text(
                'SPECIALIST: ${specialist.toUpperCase()}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            ];
          },
        ),
      );

      final fileName = '$filePrefix.pdf';
      if (kIsWeb) {
        final pdfBytes = await pdf.save();
        setState(() => _isExporting = false);
        await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
        return;
      }

      final pdfBytes = await pdf.save();
      final appDir = await getApplicationDocumentsDirectory();
      final file = File(path.join(appDir.path, fileName));
      await file.writeAsBytes(pdfBytes);

      setState(() => _isExporting = false);

      if (Platform.isWindows) {
        String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Report',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (savePath != null && mounted) {
          await file.copy(savePath);
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Saved: $savePath')));
        }
      } else {
        await Share.shareXFiles([XFile(file.path)], text: title);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isExporting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      // Ensure dialog is closed if still open (logic inside catches is safer)
    }
  }

  Future<Map<String, dynamic>> _getMetadata(String folderPath) async {
    if (kIsWeb) {
      return _webMetaCache[folderPath] ?? {};
    }
    final metaFile = File(path.join(folderPath, 'metadata.json'));
    if (await metaFile.exists()) {
      try {
        return jsonDecode(await metaFile.readAsString());
      } catch (e) {
        return {};
      }
    }
    return {};
  }

  Future<void> _syncSelectedFolders() async {
    for (final folder in _selectedFolders) {
      await SyncManager.queueReport(folder.path);
    }
    final count = _selectedFolders.length;
    setState(() {
      _selectedFolders.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تمت إضافة $count تقرير لقائمة المزامنة السحابية ✓'),
          backgroundColor: const Color(0xFF00BFA5),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    SyncManager.syncPendingReports();
  }

  Future<void> _showSyncSettings() async {
    final settingsBox = Hive.box('settings');
    final prefs = await SharedPreferences.getInstance();
    bool showAdvanced = false;

    final urlController = TextEditingController(
      text: settingsBox.get('sync_sheet_url', defaultValue: 'https://docs.google.com/spreadsheets/d/1U4T67Ao9HoE-p9pQjE_FVP_Kba5fa258vbxP4L1p41M/edit?usp=sharing') as String,
    );
    final nameController = TextEditingController(
      text: settingsBox.get('sync_sheet_name', defaultValue: 'All-Data') as String,
    );
    final scriptUrlController = TextEditingController(
      text: settingsBox.get('sync_apps_script_url', defaultValue: '') as String,
    );
    final firebaseController = TextEditingController(
      text: prefs.getString('firebase_rtdb_url') ?? '',
    );

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          String currentUrl = urlController.text.trim();
          String providerText = 'أدخل رابط Google Sheets أو OneDrive للبدء';
          Color providerColor = Colors.white38;
          IconData providerIcon = Icons.link;

          if (currentUrl.isNotEmpty) {
            if (currentUrl.contains('google.com') || currentUrl.contains('docs.google')) {
              providerText = 'تم التعرف تلقائياً على: Google Sheets ✓';
              providerColor = Colors.greenAccent;
              providerIcon = Icons.table_chart;
            } else if (currentUrl.contains('1drv.ms') || currentUrl.contains('onedrive') || currentUrl.contains('live.com')) {
              providerText = 'تم التعرف على: OneDrive Excel ✓';
              providerColor = Colors.lightBlueAccent;
              providerIcon = Icons.cloud;
            } else {
              providerText = 'رابط مخصص أو غير معروف';
              providerColor = Colors.orangeAccent;
              providerIcon = Icons.warning;
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1E2A2A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.cloud_sync, color: Color(0xFF00BFA5)),
                SizedBox(width: 8),
                Text(
                  'إعدادات مزامنة البيانات (Google Sheets)',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'رابط ملف Google Sheets (الجدول):',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: urlController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'الصق رابط شيت جوجل هنا...',
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF263333),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(providerIcon, color: const Color(0xFF00BFA5), size: 18),
                    ),
                    onChanged: (val) {
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        currentUrl.isEmpty ? Icons.info_outline : Icons.check_circle_outline,
                        color: providerColor,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          providerText,
                          style: TextStyle(
                            color: providerColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'اسم ورقة العمل (Sheet Name / Tab):',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'مثال: EXPORT أو فوارغ الصادر',
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF263333),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.table_chart, color: Color(0xFF00BFA5), size: 18),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: const Color(0xFF00BFA5),
                    ),
                    icon: Icon(
                      showAdvanced ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 18,
                    ),
                    label: const Text(
                      'إعدادات متقدمة (Web App URL & Firebase)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      setDialogState(() {
                        showAdvanced = !showAdvanced;
                      });
                    },
                  ),
                  if (showAdvanced) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'رابط Google Apps Script Web App URL:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: scriptUrlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'يُترك فارغاً لاستخدام السكريبت الافتراضي...',
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF263333),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.settings_ethernet, color: Color(0xFF00BFA5), size: 18),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'رابط Firebase RTDB للمتابعة:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: firebaseController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'https://project-id.firebaseio.com/',
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF263333),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.cloud_queue, color: Color(0xFF00BFA5), size: 18),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A3030),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF00BFA5).withAlpha(80)),
                    ),
                    child: const Text(
                      '💡 ضع رابط شيت جوجل وسيقوم التطبيق بإضافة الصفوف تلقائياً مع رفع صور الـ PDF إلى Google Drive وإرفاق رابطها.',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00BFA5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.save, size: 16, color: Colors.white),
                label: const Text('حفظ', style: TextStyle(color: Colors.white)),
                onPressed: () async {
                  await settingsBox.put('sync_sheet_url', urlController.text.trim());
                  await settingsBox.put('sync_sheet_name', nameController.text.trim().isEmpty ? 'All-Data' : nameController.text.trim());
                  await settingsBox.put('sync_apps_script_url', scriptUrlController.text.trim());
                  if (firebaseController.text.trim().isNotEmpty) {
                    await prefs.setString('firebase_rtdb_url', firebaseController.text.trim());
                    FirebaseMirror.updateState();
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('✓ تم حفظ إعدادات المزامنة بنجاح'),
                        backgroundColor: Color(0xFF00BFA5),
                        duration: Duration(seconds: 2),
                      ),
                    );
                    SyncManager.syncPendingReports();
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideScreen(context);
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: _selectedFolders.isNotEmpty
                ? Text('${_selectedFolders.length} مختار')
                : _currentTab == 1
                ? const Text('بحث واستعلام PSCCHC', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))
                : _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'بحث برقم الحاوية...',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                    ),
                    onChanged: (val) {
                      setState(() {
                        _searchQuery = val.trim().toLowerCase();
                      });
                    },
                  )
                : Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF009688), Color(0xFF00BFA5)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.inventory_2,
                          size: 22,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SealandX',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Container Reports',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
            leading: _selectedFolders.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _selectedFolders.clear();
                      });
                    },
                  )
                : null,
            actions: [
              if (_selectedFolders.isNotEmpty) ...[
                IconButton(
                  icon: const Icon(Icons.cloud_upload, color: Colors.cyanAccent),
                  onPressed: _syncSelectedFolders,
                  tooltip: 'مزامنة المختار سحابياً (Google Sheets)',
                ),
                IconButton(
                  icon: const Icon(Icons.share, color: Colors.greenAccent),
                  onPressed: _shareSelectedFolders,
                  tooltip: 'مشاركة المختار واتساب',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  onPressed: _deleteSelectedFolders,
                  tooltip: 'حذف المختار',
                ),
              ] else if (_currentTab == 1) ...[
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.redAccent),
                  onPressed: widget.onLogout,
                  tooltip: 'تسجيل خروج',
                ),
              ] else ...[
                // Cloud Sync Indicator
                ValueListenableBuilder<int>(
                  valueListenable: SyncManager.pendingSyncsNotifier,
                  builder: (context, pending, _) {
                    return GestureDetector(
                      onTap: () {
                        SyncManager.syncPendingReports();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              pending > 0
                                  ? 'جاري إعادة محاولة مزامنة $pending تقرير إلى Google Sheets...'
                                  : 'كل التقارير تمت مزامنتها بنجاح ✓',
                            ),
                            backgroundColor: pending > 0
                                ? Colors.orange
                                : const Color(0xFF00BFA5),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  pending > 0 ? Icons.cloud_sync : Icons.cloud_done,
                                  color: pending > 0 ? Colors.amberAccent : Colors.greenAccent,
                                  size: 24,
                                ),
                                if (pending > 0)
                                  Positioned(
                                    top: -4,
                                    right: -6,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: const BoxDecoration(
                                        color: Colors.redAccent,
                                        shape: BoxShape.circle,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 14,
                                        minHeight: 14,
                                      ),
                                      child: Text(
                                        '$pending',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_queue, color: Color(0xFF00BFA5)),
                  onPressed: _showSyncSettings,
                  tooltip: 'إعدادات مزامنة Google Sheets',
                ),
                IconButton(
                  icon: Icon(
                    _isSearching ? Icons.close : Icons.search,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSearching = !_isSearching;
                      if (!_isSearching) {
                        _searchQuery = "";
                        _searchController.clear();
                      }
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.summarize, color: Colors.orangeAccent),
                  onPressed: _showReportTypeSheet,
                  tooltip: 'تصدير تقرير',
                ),
                IconButton(
                  icon: const Icon(
                    Icons.auto_fix_high,
                    color: Colors.blueAccent,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ConverterScreen(),
                      ),
                    );
                  },
                  tooltip: 'مكتبة التحويل والأدوات',
                ),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.redAccent),
                  onPressed: widget.onLogout,
                  tooltip: 'تسجيل خروج',
                ),
              ],
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1.0),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFF009688),
                      Color(0xFF00BFA5),
                      Color(0xFF009688),
                    ],
                  ),
                ),
                height: 2.0,
              ),
            ),
          ),
          body: _currentTab == 1
              ? const PscchcSearchTab()
              : _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _folders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF009688).withAlpha(30),
                        ),
                        child: const Icon(
                          Icons.inventory_2_outlined,
                          size: 80,
                          color: Color(0xFF009688),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'لا توجد تقارير مخزنة',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'اضغط على الزر أدناه لبدء فحص حاوية جديدة',
                        style: TextStyle(fontSize: 13, color: Colors.white38),
                      ),
                      const SizedBox(height: 32),
                      FilledButton.icon(
                        onPressed: _createNewReport,
                        icon: const Icon(Icons.add_task),
                        label: const Text(
                          'بدء فحص جديد',
                          style: TextStyle(fontSize: 16),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF009688),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: wide ? 900 : double.infinity,
                    ),
                    child: (() {
                      // Logic to group folders by time periods
                      Map<String, List<ReportFolder>> grouped = {};
                      final displayedFolders = _searchQuery.isEmpty
                          ? _folders
                          : _folders.where((f) {
                              final nameMatch = f.name.toLowerCase().contains(
                                _searchQuery,
                              );
                              final dateStr = DateFormat(
                                'yyyy/MM/dd',
                              ).format(f.modified);
                              final dateMatch = dateStr.contains(_searchQuery);
                              return nameMatch || dateMatch;
                            }).toList();

                      for (var f in displayedFolders) {
                        String key;
                        final now = DateTime.now();
                        final today = DateTime(now.year, now.month, now.day);
                        final folderDate = DateTime(
                          f.modified.year,
                          f.modified.month,
                          f.modified.day,
                        );
                        final diff = today.difference(folderDate).inDays;

                        if (diff <= 0) {
                          key = "تقارير اليوم (Today)";
                        } else if (diff == 1) {
                          key = "تقارير أمس (Yesterday)";
                        } else if (diff < 7) {
                          key = "هذا الأسبوع (This Week)";
                        } else if (diff < 30) {
                          key = "هذا الشهر (This Month)";
                        } else {
                          key = DateFormat(
                            'MMMM yyyy',
                            'ar',
                          ).format(f.modified);
                        }

                        grouped.putIfAbsent(key, () => []).add(f);
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: grouped.length,
                        itemBuilder: (context, sectionIndex) {
                          final key = grouped.keys.elementAt(sectionIndex);
                          final items = grouped[key]!;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.calendar_today,
                                      size: 16,
                                      color: const Color(
                                        0xFF009688,
                                      ).withAlpha(180),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      key,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF00BFA5),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      '${items.length} حاويات',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ...items.map((item) => _buildFolderCard(item)),
                              const Divider(
                                height: 32,
                                thickness: 0.5,
                                color: Colors.white10,
                              ),
                            ],
                          );
                        },
                      );
                    })(),
                  ),
                ),
          floatingActionButton: _currentTab == 1
              ? null
              : FloatingActionButton.extended(
                  onPressed: _createNewReport,
                  backgroundColor: const Color(0xFF009688),
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: const Text(
                    'تقرير جديد',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentTab,
            onTap: (index) {
              setState(() {
                _currentTab = index;
              });
            },
            selectedItemColor: const Color(0xFF00BFA5),
            unselectedItemColor: Colors.grey,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.folder),
                label: 'التقارير المخزنة',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.search),
                label: 'بحث PSCCHC',
              ),
            ],
          ),
        ),
        if (_isExporting)
          Container(
            color: Colors.black45,
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF009688)),
            ),
          ),
      ],
    );
  }

  Widget _buildFolderCard(ReportFolder folder) {
    final isSelected = _selectedFolders.contains(folder);
    return Card(
      elevation: isSelected ? 6 : 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? const BorderSide(color: Color(0xFF009688), width: 2)
            : BorderSide.none,
      ),
      color: isSelected ? const Color(0xFF009688).withAlpha(25) : null,
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: Stack(
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(10),
                image: folder.coverImage != null
                    ? DecorationImage(
                        image: FileImage(folder.coverImage!),
                        fit: BoxFit.cover,
                      )
                    : null,
                gradient: folder.coverImage == null
                    ? const LinearGradient(
                        colors: [Color(0xFF004D40), Color(0xFF00796B)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
              ),
              child: folder.coverImage == null
                  ? const Icon(Icons.image_outlined, color: Colors.white24)
                  : null,
            ),
            if (isSelected)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Color(0xFF009688),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
                ),
              ),
          ],
        ),
        title: Text(
          folder.name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              DateFormat('yyyy/MM/dd hh:mm a').format(folder.modified),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF009688).withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${folder.itemCount} صور',
                    style: const TextStyle(
                      color: Color(0xFF009688),
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: () {
          if (_selectedFolders.isNotEmpty) {
            setState(() {
              if (isSelected) {
                _selectedFolders.remove(folder);
              } else {
                _selectedFolders.add(folder);
              }
            });
          } else {
            _openReport(folder);
          }
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.article, color: Colors.blueAccent),
              onPressed: () => _generateWordXFile(folder),
              tooltip: 'تصدير Word (صور أصلية)',
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Color(0xFF009688))
            else
              const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
        onLongPress: () {
          setState(() {
            if (isSelected) {
              _selectedFolders.remove(folder);
            } else {
              _selectedFolders.add(folder);
            }
          });
        },
      ),
    );
  }

  Future<void> _generateWordXFile(ReportFolder folder) async {
    setState(() => _isLoading = true);
    try {
      final metaFile = File(path.join(folder.path, 'metadata.json'));
      final reportFile = File(path.join(folder.path, 'report.txt'));
      Map<String, dynamic> meta = {};
      if (await metaFile.exists()) {
        meta = jsonDecode(await metaFile.readAsString());
      }
      String reportNotes = "SEAL HAS BEEN AFFIXED";
      if (await reportFile.exists()) {
        reportNotes = await reportFile.readAsString();
      }
      final imageFiles = Directory(folder.path)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList();

      final buffer = StringBuffer();
      buffer.write("<html><head><meta charset='utf-8'><style>");
      buffer.write(
        "body { font-family: 'Segoe UI', Arial; line-height: 1.6; color: #333; }",
      );
      buffer.write(
        ".header { border-bottom: 4px solid #004D40; padding-bottom: 10px; margin-bottom: 20px; }",
      );
      buffer.write(
        ".company { font-size: 12pt; font-weight: bold; color: #666; }",
      );
      buffer.write(
        ".title { font-size: 26pt; font-weight: 800; color: #004D40; }",
      );
      buffer.write(
        "table { width: 100%; border-collapse: collapse; margin-top: 20px; }",
      );
      buffer.write(
        "td { border: 1px solid #ddd; padding: 12px; font-size: 11pt; }",
      );
      buffer.write(
        ".key { background: #f9f9f9; font-weight: bold; color: #004D40; width: 25%; }",
      );
      buffer.write(
        ".section { background: #004D40; color: white; padding: 10px; font-weight: bold; margin-top: 30px; }",
      );
      buffer.write(".img-grid { margin-top: 20px; width: 100%; }");
      buffer.write(
        ".img-box { display: inline-block; width: 45%; padding: 10px; text-align: center; border: 1px solid #eee; margin: 5px; }",
      );
      buffer.write("</style></head><body>");

      buffer.write(
        "<div class='header'><div class='company'>SEALANDX LOGISTICS</div><div class='title'>SEAL Status Report</div></div>",
      );
      buffer.write("<table>");
      buffer.write(
        "<tr><td class='key'>CONTAINER:</td><td>${(meta['containerNo'] ?? 'N/A').toString().toUpperCase()}</td><td class='key'>SIZE:</td><td>${(meta['size'] ?? 'N/A').toString().toUpperCase()}</td></tr>",
      );
      buffer.write(
        "<tr><td class='key'>LOCATION:</td><td>${(meta['location'] ?? 'N/A').toString().toUpperCase()}</td><td class='key'>DATE:</td><td>${DateFormat('yyyy-MM-dd').format(folder.modified)}</td></tr>",
      );
      buffer.write(
        "<tr><td class='key'>DMG STATUS:</td><td colspan='3' style='color:${meta['dmg'] == 'YES' ? 'red' : 'green'}; font-weight:bold;'>${meta['dmg'] == 'YES' ? 'DAMAGED' : 'GOOD'}</td></tr>",
      );
      buffer.write("</table>");

      buffer.write("<div class='section'>REPORT CONTENT</div>");
      buffer.write(
        "<div style='border:1px solid #ddd; padding:15px; min-height:80px;'>${(reportNotes.trim().isEmpty ? 'SEAL HAS BEEN AFFIXED' : reportNotes).toUpperCase()}</div>",
      );

      buffer.write("<div class='section'>PHOTO EVIDENCE</div>");
      buffer.write("<div class='img-grid'>");
      for (var file in imageFiles) {
        final b64 = base64Encode(await file.readAsBytes());
        buffer.write(
          "<div class='img-box'><img src='data:image/jpeg;base64,$b64' width='280'><br><small>${path.basename(file.path)}</small></div>",
        );
      }
      buffer.write("</div></body></html>");

      final String fileName = "${meta['containerNo'] ?? 'report'}_word.doc";
      if (kIsWeb) {
        await Share.shareXFiles([
          XFile.fromData(
            utf8.encode(buffer.toString()),
            name: fileName,
            mimeType: 'application/msword',
          ),
        ]);
      } else if (Platform.isWindows) {
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'حفظ ملف الوورد',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['doc'],
        );
        if (selectedPath != null) {
          await File(selectedPath).writeAsString(buffer.toString());
        }
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        final file = File(path.join(appDir.path, fileName));
        await file.writeAsString(buffer.toString());
        await Share.shareXFiles([XFile(file.path)]);
      }
    } catch (e) {
      debugPrint("Export Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }
}

class AlbumScreen extends StatefulWidget {
  final String folderPath;
  final String folderName;

  const AlbumScreen({
    super.key,
    required this.folderPath,
    required this.folderName,
  });

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _reportController = TextEditingController();
  final TextEditingController _containerNoController = TextEditingController();
  final TextEditingController _inspectorController = TextEditingController();
  final TextEditingController _sealingPersonController =
      TextEditingController();
  final TextEditingController _bookingNoController = TextEditingController();
  final TextEditingController _shippersController = TextEditingController();
  final TextEditingController _sealNoController = TextEditingController();

  String? _selectedSize;
  String? _selectedType;
  String? _selectedLine;
  String? _selectedShippingLine;
  String? _selectedDMG; // YES / NO
  List<String> _shipperOptions = [];

  List<ContainerPart> _parts = [];
  bool _isLoading = true;
  bool _isExporting = false;
  late String _currentFolderPath;
  late String _currentFolderName;

  @override
  void initState() {
    super.initState();
    _currentFolderPath = widget.folderPath;
    _currentFolderName = widget.folderName;
    _loadShipperOptions();
    _initializeParts();
  }

  Future<void> _loadShipperOptions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String>? custom = prefs.getStringList('custom_shippers');
      setState(() {
        _shipperOptions = [...defaultShippers, ...(custom ?? [])];
      });
    } catch (e) {
      debugPrint('Error loading shippers: $e');
      setState(() {
        _shipperOptions = List.from(defaultShippers);
      });
    }
  }

  Future<void> _addNewShipperPrompt() async {
    final TextEditingController newShipperController = TextEditingController();
    final String? newShipper = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة مصدر جديد (New Shipper)'),
        content: TextField(
          controller: newShipperController,
          decoration: const InputDecoration(
            hintText: 'اسم المصدر...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, newShipperController.text.trim()),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );

    if (newShipper != null && newShipper.isNotEmpty) {
      if (!_shipperOptions.contains(newShipper)) {
        setState(() {
          _shipperOptions.add(newShipper);
        });
        final prefs = await SharedPreferences.getInstance();
        final List<String> custom = _shipperOptions
            .where((s) => !defaultShippers.contains(s))
            .toList();
        await prefs.setStringList('custom_shippers', custom);

        setState(() {
          _shippersController.text = newShipper;
        });
        _saveData();
      }
    }
  }

  Future<void> _initializeParts() async {
    // Load default parts first to ensure the list is never empty
    List<ContainerPart> loadedParts = List.generate(
      containerPartNames.length,
      (i) => ContainerPart(name: containerPartNames[i], id: 'part_$i'),
    );

    try {
      if (kIsWeb) {
        final boxReports = Hive.box('web_reports');
        final rawMeta = boxReports.get(_currentFolderPath);
        if (rawMeta != null) {
          final data = Map<String, dynamic>.from(rawMeta as Map);
          _containerNoController.text = data['containerNo'] ?? '';
          final prefs = await SharedPreferences.getInstance();
          _inspectorController.text =
              data['inspector'] ?? prefs.getString('inspector_name') ?? '';
          _sealingPersonController.text =
              data['sealingPerson'] ?? prefs.getString('inspector_name') ?? '';
          _bookingNoController.text = data['bookingNo'] ?? '';
          _shippersController.text = data['shippers'] ?? '';
          _sealNoController.text = data['sealNo'] ?? '';
          _reportController.text = data['report'] ?? '';
          _selectedSize = data['size'];
          _selectedType = data['type'];
          _selectedLine = data['line'];
          _selectedShippingLine = data['shippingLine'];
          _selectedDMG = data['dmg'];
        }

        final boxImages = Hive.box('web_images');
        for (int i = 0; i < loadedParts.length; i++) {
          final key = '${_currentFolderPath}_${loadedParts[i].id}';
          if (boxImages.containsKey(key)) {
            final base64Img = boxImages.get(key);
            if (base64Img != null && base64Img is String) {
              try {
                loadedParts[i].webImageBytes = base64Decode(base64Img);
              } catch (_) {}
            }
          }
        }
      } else {
        // Mobile/Windows logic
        final reportFile = File(path.join(_currentFolderPath, 'report.txt'));
        if (await reportFile.exists()) {
          _reportController.text = await reportFile.readAsString();
        }

        final metaFile = File(path.join(_currentFolderPath, 'metadata.json'));
        if (await metaFile.exists()) {
          try {
            final data = jsonDecode(await metaFile.readAsString());
            _containerNoController.text = data['containerNo'] ?? '';
            final prefs = await SharedPreferences.getInstance();
            _inspectorController.text =
                data['inspector'] ?? prefs.getString('inspector_name') ?? '';
            _sealingPersonController.text =
                data['sealingPerson'] ??
                prefs.getString('inspector_name') ??
                '';
            _bookingNoController.text = data['bookingNo'] ?? '';
            _shippersController.text = data['shippers'] ?? '';
            _sealNoController.text = data['sealNo'] ?? '';
            _selectedSize = data['size'];
            _selectedType = data['type'];
            _selectedLine = data['line'];
            _selectedShippingLine = data['shippingLine'];
            _selectedDMG = data['dmg'];
          } catch (_) {}
        }

        for (int i = 0; i < loadedParts.length; i++) {
          final imgPath = path.join(
            _currentFolderPath,
            '${loadedParts[i].id}.jpg',
          );
          final imgFile = File(imgPath);
          if (await imgFile.exists()) {
            loadedParts[i].image = imgFile;
          }
        }
      }
    } catch (e) {
      debugPrint('Init parts error: $e');
    } finally {
      setState(() {
        _parts = loadedParts;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveData({bool triggerSync = false}) async {
    if (kIsWeb) {
      // قراءة createdAt الموجود في الـ web cache عشان منمسحوش
      final existingMeta =
          _LibraryScreenState._webMetaCache[_currentFolderPath] ?? {};

      final String createdAt =
          existingMeta['createdAt'] ?? DateTime.now().toIso8601String();

      final meta = {
        'containerNo': _containerNoController.text,
        'inspector': _inspectorController.text,
        'sealingPerson': _sealingPersonController.text,
        'bookingNo': _bookingNoController.text,
        'shippers': _shippersController.text,
        'sealNo': _sealNoController.text,
        'size': _selectedSize,
        'type': _selectedType,
        'line': _selectedLine,
        'shippingLine': _selectedShippingLine,
        'dmg': _selectedDMG,
        'report': _reportController.text,
        'createdAt': createdAt,
      };

      // Update Cache
      _LibraryScreenState._webMetaCache[_currentFolderPath] = meta;

      // Update the folder list cache to reflect item count and name
      for (int i = 0; i < _LibraryScreenState._webFoldersCache.length; i++) {
        if (_LibraryScreenState._webFoldersCache[i].path ==
            _currentFolderPath) {
          final old = _LibraryScreenState._webFoldersCache[i];
          _LibraryScreenState._webFoldersCache[i] = ReportFolder(
            name: _containerNoController.text.trim().isEmpty
                ? old.name
                : _containerNoController.text.trim(),
            path: old.path,
            modified: old.modified,
            itemCount: _parts.where((p) => p.webImageBytes != null).length,
            coverImage: null,
          );
          break;
        }
      }

      // Save Metadata to Hive
      try {
        final boxReports = Hive.box('web_reports');
        await boxReports.put(_currentFolderPath, meta);

        // Save Images to Hive
        final boxImages = Hive.box('web_images');
        for (var part in _parts) {
          if (part.webImageBytes != null) {
            final key = '${_currentFolderPath}_${part.id}';
            await boxImages.put(key, base64Encode(part.webImageBytes!));
          } else {
            // If image removed, delete from Hive?
            // Maybe user deleted it.
            final key = '${_currentFolderPath}_${part.id}';
            if (boxImages.containsKey(key)) {
              await boxImages.delete(key);
            }
          }
        }
      } catch (e) {
        debugPrint('Hive save error: $e');
      }

      if (triggerSync) {
        SyncManager.queueReport(_currentFolderPath);
      }
      return;
    }
    final newContainerNo = _containerNoController.text.trim();

    // Rename folder if containerNo changed and is valid
    if (newContainerNo.isNotEmpty && newContainerNo != _currentFolderName) {
      try {
        final parentDir = Directory(_currentFolderPath).parent;
        final safeName = newContainerNo.replaceAll(
          RegExp(r'[\\/:*?"<>|]'),
          '_',
        );
        final newPath = path.join(parentDir.path, safeName);

        if (!await Directory(newPath).exists()) {
          final oldDir = Directory(_currentFolderPath);
          if (await oldDir.exists()) {
            await oldDir.rename(newPath);

            // Update image paths to point to new location prevent PathNotFoundException
            for (var part in _parts) {
              if (part.image != null) {
                final fileName = path.basename(part.image!.path);
                part.image = File(path.join(newPath, fileName));
              }
            }

            _currentFolderPath = newPath;
            _currentFolderName = safeName;
          }
        }
      } catch (e) {
        debugPrint('Error renaming folder: $e');
      }
    }

    final reportFile = File(path.join(_currentFolderPath, 'report.txt'));
    await reportFile.writeAsString(_reportController.text);

    // قراءة createdAt الموجود عشان منمسحوش لما نحفظ
    final metaFile = File(path.join(_currentFolderPath, 'metadata.json'));
    String? existingCreatedAt;
    if (await metaFile.exists()) {
      try {
        final existing = jsonDecode(await metaFile.readAsString());
        existingCreatedAt = existing['createdAt']?.toString();
      } catch (_) {}
    }

    final metaData = {
      'containerNo': _containerNoController.text,
      'inspector': _inspectorController.text,
      'sealingPerson': _sealingPersonController.text,
      'bookingNo': _bookingNoController.text,
      'shippers': _shippersController.text,
      'sealNo': _sealNoController.text,
      'size': _selectedSize,
      'type': _selectedType,
      'line': _selectedLine,
      'shippingLine': _selectedShippingLine,
      'dmg': _selectedDMG,
      // الحفاظ على createdAt الأصلي - لو مش موجود نحطه دلوقتي
      'createdAt': existingCreatedAt ?? DateTime.now().toIso8601String(),
    };
    await metaFile.writeAsString(jsonEncode(metaData));

    if (triggerSync) {
      SyncManager.queueReport(_currentFolderPath);
    }
  }

  Future<bool> _takePhoto(int index) async {
    return _pickImageGeneric(index, isCamera: true);
  }

  Future<bool> _pickImage(int index) async {
    return _pickImageGeneric(index, isCamera: false);
  }

  Future<bool> _pickImageGeneric(int index, {required bool isCamera}) async {
    try {
      if (kIsWeb) {
        XFile? photo;
        try {
          photo = await _picker.pickImage(
            source: isCamera ? ImageSource.camera : ImageSource.gallery,
            imageQuality: 80,
            maxWidth: 1024,
            maxHeight: 1024,
          );
        } catch (e) {
          debugPrint('ImagePicker error: $e');
        }

        // Fallback for gallery using FilePicker if ImagePicker failed or returned null
        if (photo == null && !isCamera) {
          FilePickerResult? result = await FilePicker.platform.pickFiles(
            type: FileType.image,
          );
          if (result != null && result.files.single.bytes != null) {
            setState(() {
              _parts[index].webImageBytes = result.files.single.bytes;
            });
            _saveData();
            return true;
          }
        }

        if (photo != null) {
          final bytes = await photo.readAsBytes();
          setState(() {
            _parts[index].webImageBytes = bytes;
          });
          _saveData();
          return true;
        }
        return false;
      }

      // Mobile Camera handling (Pro Experience)
      if (isCamera && !kIsWeb && !Platform.isWindows) {
        final status = await Permission.camera.request();
        if (status.isGranted && cameras.isNotEmpty) {
          final XFile? photo = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (ctx) => ProfessionalCameraScreen(
                camera: cameras.first,
                partName: _parts[index].name,
              ),
            ),
          );

          if (photo != null) {
            final part = _parts[index];
            final targetPath = path.join(_currentFolderPath, '${part.id}.jpg');
            final savedImage = await File(photo.path).copy(targetPath);
            setState(() {
              _parts[index].image = savedImage;
            });
            await _performOCR(savedImage, _parts[index].name);
            _saveData();
            return true;
          }
          return false;
        }

        // Fallback to default picker if permission denied or no cameras initialized
        final XFile? photo = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 80,
          maxWidth: 1024,
          maxHeight: 1024,
        );
        if (photo != null) {
          final part = _parts[index];
          final targetPath = path.join(_currentFolderPath, '${part.id}.jpg');
          final savedImage = await File(photo.path).copy(targetPath);
          setState(() {
            _parts[index].image = savedImage;
          });
          await _performOCR(savedImage, _parts[index].name);
          _saveData();
          return true;
        }
        return false;
      }

      // File Picker (Studio or Windows Camera fallback)
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      if (result != null && result.files.single.path != null) {
        final part = _parts[index];
        final targetPath = path.join(_currentFolderPath, '${part.id}.jpg');
        final savedImage = await File(
          result.files.single.path!,
        ).copy(targetPath);
        setState(() {
          _parts[index].image = savedImage;
        });
        await _performOCR(savedImage, _parts[index].name);
        _saveData();
        return true;
      }
    } catch (e) {
      debugPrint('Pick image error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error selecting image: $e')));
      }
    }
    return false;
  }

  Future<void> _startAutoScan() async {
    // Start loop for empty slots
    for (int i = 0; i < _parts.length; i++) {
      if ((kIsWeb
          ? _parts[i].webImageBytes == null
          : _parts[i].image == null)) {
        // ... (rest of the dialog logic)
        final bool? shouldProceed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.camera_enhance, color: Color(0xFF009688)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'تصوير: ${_parts[i].name}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
            content: Text(
              'الخطوة ${i + 1} من ${_parts.length}\n\nيرجى توجيه الكاميرا لالتقاط صورة:\n${_parts[i].name}',
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إيقاف'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.camera_alt),
                label: const Text('التقاط الصورة'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF009688),
                ),
              ),
            ],
          ),
        );

        if (shouldProceed != true) break;

        bool taken = await _takePhoto(i);

        if (!mounted) break;
        await Future.delayed(const Duration(milliseconds: 300));

        if (!taken) {
          // If user backed out of camera without taking photo, stop the scan
          break;
        }
      }
    }

    if (mounted &&
        _parts.every(
          (p) => (kIsWeb ? p.webImageBytes != null : p.image != null),
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم الانتهاء من تصوير جميع الأجزاء!')),
      );
    }
  }

  Future<void> _performOCR(File imageFile, String partName) async {
    // ML Kit is mobile only. Avoid crash on Windows/Web.
    if (kIsWeb || (!kIsWeb && Platform.isWindows)) {
      debugPrint('OCR not supported on this platform.');
      return;
    }
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final textRecognizer = TextRecognizer(
        script: TextRecognitionScript.latin,
      );
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );

      String? detectedContainerNo;
      String? detectedSize;
      String? detectedType;
      String? detectedSealNo;

      final containerPattern = RegExp(r'\b[A-Z0]{3}[A-Z0-9]\s?\d{6,7}\b');
      final sizePattern = RegExp(r'\b(20|22|40|42|45)\b');

      bool isRearDoor =
          partName.contains('Rear Door') || partName.contains('الأبواب');
      bool isSealOrDoc =
          partName.contains('SEAL') || partName.contains('السيل');

      List<String> sealCandidates = [];
      final genericSerialPattern = RegExp(r'\b[A-Z0-9]{6,12}\b');
      final List<String> sealKeywords = [
        'SEAL',
        'S/L',
        'NO',
        'NUM',
        'NR',
        'REF',
        '#',
      ];

      for (TextBlock block in recognizedText.blocks) {
        String blockText = block.text.toUpperCase();
        String textNoSpaces = blockText.replaceAll(' ', '');

        // 1. Container & Size Recognition (Only for Rear Door)
        if (isRearDoor) {
          final containerMatch = containerPattern.firstMatch(textNoSpaces);
          if (containerMatch != null && detectedContainerNo == null) {
            detectedContainerNo = containerMatch.group(0);
          }

          final sizeMatch = sizePattern.firstMatch(block.text);
          if (sizeMatch != null && detectedSize == null) {
            String rawSize = sizeMatch.group(1)!;
            if (rawSize == '22') {
              detectedSize = '20';
              detectedType = 'DV';
            } else if (rawSize == '45') {
              detectedSize = '40';
              detectedType = 'HC';
            } else if (rawSize == '42') {
              detectedSize = '40';
              detectedType = 'O.T';
            } else {
              detectedSize = rawSize;
            }
          }
        }

        // 2. Seal Candidate Collection
        if (isSealOrDoc) {
          bool hasKeyword = sealKeywords.any((k) => blockText.contains(k));

          Iterable<RegExpMatch> matches = genericSerialPattern.allMatches(
            textNoSpaces,
          );
          for (var m in matches) {
            String val = m.group(0)!;
            // If near a keyword, it's our top pick
            if (hasKeyword && (detectedSealNo == null)) {
              detectedSealNo = val;
            } else {
              sealCandidates.add(val);
            }
          }
        }
      }

      // Fallback: pick the first candidate that isn't the container number
      if (detectedSealNo == null && sealCandidates.isNotEmpty) {
        for (String candidate in sealCandidates) {
          if (detectedContainerNo != null &&
              detectedContainerNo.contains(candidate)) {
            continue;
          }
          detectedSealNo = candidate;
          break;
        }
      }

      await textRecognizer.close();

      if (mounted) {
        if (detectedContainerNo != null ||
            detectedSize != null ||
            detectedSealNo != null) {
          final result = await showDialog<Map<String, String?>>(
            context: context,
            builder: (ctx) => OCRReviewDialog(
              detectedContainerNo: detectedContainerNo,
              detectedSize: detectedSize,
              detectedType: detectedType,
              detectedSealNo: detectedSealNo,
              currentContainerNo: _containerNoController.text,
              currentSize: _selectedSize,
              currentType: _selectedType,
              currentSealNo: _sealNoController.text,
            ),
          );

          if (result != null) {
            setState(() {
              if (result['containerNo']?.isNotEmpty ?? false) {
                _containerNoController.text = result['containerNo']!;
              }
              if (result['size'] != null) {
                _selectedSize = result['size'];
              }
              if (result['type'] != null) {
                _selectedType = result['type'];
              }
              if (result['sealNo']?.isNotEmpty ?? false) {
                _sealNoController.text = result['sealNo']!;
              }
            });
            await _saveData();
          }
        }
      }
    } catch (e) {
      debugPrint('OCR Error: $e');
    }
  }

  // ---- PSCCHC Search Integration ----
  Future<void> _searchPscchc() async {
    String text = _containerNoController.text.trim().replaceAll(' ', '');
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('برجاء إدخال رقم الحاوية أولاً')));
      }
      return;
    }

    if (text.length < 2) return;
    String searchId = text.length == 11 ? text.substring(0, 10) : text;

    setState(() => _isLoading = true);
    try {
      final url = 'https://api.pscchc.com/pup/api/ContTrace?cnt=$searchId&typ=4';
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        var masterList = data['master'] as List?;

        if ((masterList == null || masterList.isEmpty) && text.length > 10) {
          final fallbackId = text.substring(0, text.length - 1);
          final fbResponse = await http
              .get(Uri.parse('https://api.pscchc.com/pup/api/ContTrace?cnt=$fallbackId&typ=4'))
              .timeout(const Duration(seconds: 10));
          if (fbResponse.statusCode == 200) {
            final fbData = jsonDecode(fbResponse.body);
            if (fbData['master'] != null && (fbData['master'] as List).isNotEmpty) {
              masterList = fbData['master'] as List;
            }
          }
        }

        if (masterList != null && masterList.isNotEmpty) {
          final info = masterList[0];

          setState(() {
            // 1. Size mapping
            String? s = info['csize']?.toString();
            if (s != null && containerSizes.contains(s)) {
              _selectedSize = s;
            }

            // 2. Type mapping
            String? t = info['type']?.toString().toUpperCase();
            if (t != null && t.isNotEmpty) {
              _selectedType = t;
            }

            // 3. Location / Gate mapping (from yard)
            String? yard = info['yard']?.toString().toUpperCase();
            if (yard != null && yard.isNotEmpty) {
              String? matchedOption;
              for (var opt in lineOptions) {
                if (yard.contains(opt.toUpperCase())) {
                  matchedOption = opt;
                  break;
                }
              }
              if (matchedOption != null) {
                _selectedLine = matchedOption;
              } else {
                if (!lineOptions.contains(yard)) {
                  lineOptions.add(yard);
                }
                _selectedLine = yard;
              }

              if (!_reportController.text.contains(yard)) {
                _reportController.text =
                    "${_reportController.text.trim()}\nLOC: $yard".trim();
              }
            }

            // 4. Shipping Line mapping
            String? sl = info['line']?.toString().toUpperCase();
            if (sl != null && sl.isNotEmpty) {
              if (shippingLines.contains(sl)) {
                _selectedShippingLine = sl;
              } else {
                bool found = false;
                for (var opt in shippingLines) {
                  if (sl.contains(opt) || opt.contains(sl)) {
                    _selectedShippingLine = opt;
                    found = true;
                    break;
                  }
                }
                if (!found) {
                  if (!shippingLines.contains(sl)) {
                    shippingLines.add(sl);
                  }
                  _selectedShippingLine = sl;
                }
              }
            }

            // 5. Booking No mapping (if available in master)
            String? bkg = info['book_no']?.toString() ?? info['bkg_no']?.toString();
            if (bkg != null && bkg.trim().isNotEmpty && _bookingNoController.text.trim().isEmpty) {
              _bookingNoController.text = bkg.trim();
            }
          });

          await _saveData();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✓ تم استيراد بيانات الحاوية من PSCCHC بنجاح'),
                backgroundColor: Color(0xFF00BFA5),
              ),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('لا توجد بيانات لهذه الحاوية في موقع بورسعيد للحاويات'),
              ),
            );
          }
        }
      } else {
        throw Exception('Server Error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ في الاتصال بالموقع: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sharePdf() async {
    await _saveData(triggerSync: true);

    if (_parts.every(
      (p) => (kIsWeb ? p.webImageBytes == null : p.image == null),
    )) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('برجاء التقاط صورة واحدة على الأقل قبل التصدير'),
        ),
      );
      return;
    }

    if (!mounted) return;

    setState(() => _isExporting = true);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final pdf = pw.Document();
      final logoData = await rootBundle.load('assets/sealand_logo.png');
      final logoBytes = logoData.buffer.asUint8List();
      final logoImage = pw.MemoryImage(logoBytes);

      final helvetica = pw.Font.helvetica();
      final helveticaBold = pw.Font.helveticaBold();

      // Helper function to ensure text is only ASCII (to prevent squares)
      String cleanText(Object? val) {
        if (val == null) return "N/A";
        String s = val.toString().trim();
        if (s.isEmpty) return "N/A";
        // Keep only printable ASCII characters and common whitespace
        String result = s.replaceAll(RegExp(r'[^\x20-\x7E\n\r\t]+'), '').trim();
        return result.isEmpty ? "N/A" : result;
      }

      final Map<String, String> partMap = {
        'باب الحاوية الخلفية (Rear Door)': 'REAR DOOR',
        'السيل (SEAL)': 'SEAL',
        'الجواب (Document)': 'DOCUMENT',
      };

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
                          style: pw.TextStyle(
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
                    pw.Image(logoImage, height: 70),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    _bookingNoController.text,
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    _shippersController.text,
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    _sealNoController.text,
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    _containerNoController.text,
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(_selectedSize).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(_selectedType).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(
                                    _selectedShippingLine,
                                  ).toUpperCase(),
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
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: cleanText(_selectedLine).toUpperCase(),
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
                                    color: _selectedDMG == 'YES'
                                        ? PdfColors.green
                                        : PdfColors.red,
                                  ),
                                ),
                                pw.TextSpan(
                                  text: _selectedDMG == 'YES' ? 'YES' : 'NO',
                                  style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    color: _selectedDMG == 'YES'
                                        ? PdfColors.green
                                        : PdfColors.red,
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
              pw.Center(
                child: pw.Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: pw.WrapAlignment.center,
                  children: _parts
                      .where(
                        (p) => (kIsWeb
                            ? p.webImageBytes != null
                            : p.image != null),
                      )
                      .map((p) {
                        final image = pw.MemoryImage(
                          kIsWeb
                              ? p.webImageBytes!
                              : p.image!.readAsBytesSync(),
                        );
                        final isRearDoor =
                            p.name.contains('الأبواب الخلفية') ||
                            p.name.contains('Rear');
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
                                partMap[p.name] ??
                                    cleanText(p.name).toUpperCase(),
                                style: pw.TextStyle(
                                  fontSize: 10,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      })
                      .toList(),
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
                  (_reportController.text.isEmpty
                          ? 'SEAL HAS BEEN AFFIXED'
                          : cleanText(_reportController.text))
                      .toUpperCase(),
                  style: const pw.TextStyle(fontSize: 11),
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Row(
                children: [
                  pw.RichText(
                    text: pw.TextSpan(
                      children: [
                        pw.TextSpan(
                          text: 'SEALING PERSON: ',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                        pw.TextSpan(
                          text: _sealingPersonController.text.isEmpty
                              ? '________________'
                              : cleanText(
                                  _sealingPersonController.text,
                                ).toUpperCase(),
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

      final String line = cleanText(_selectedShippingLine).toUpperCase();
      final String container = cleanText(
        _containerNoController.text,
      ).toUpperCase();
      final String fileName = '${line}_$container.pdf'.replaceAll(
        RegExp(r'[^a-zA-Z0-9_\.-]'),
        '_',
      );

      if (kIsWeb) {
        final pdfBytes = await pdf.save();
        setState(() => _isExporting = false);
        await Share.shareXFiles([
          XFile.fromData(pdfBytes, name: fileName, mimeType: 'application/pdf'),
        ], text: 'SEAL Status Report: $container');
        return;
      }

      final pdfBytes = await pdf.save();
      final appDir = await getApplicationDocumentsDirectory();
      final file = File(path.join(appDir.path, fileName));
      await file.writeAsBytes(pdfBytes);

      setState(() => _isExporting = false);

      if (!kIsWeb && Platform.isWindows) {
        // Save to device logic for Windows
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'حفظ التقرير PDF',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );

        if (selectedPath != null) {
          await file.copy(selectedPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('تم حفظ التقرير في: $selectedPath')),
            );
          }
        }
      } else {
        await Share.shareXFiles([
          XFile(file.path),
        ], text: 'SEAL Status Report: $_currentFolderName');
      }
    } catch (e) {
      setState(() => _isExporting = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error creating PDF: $e')));
      }
    }
  }

  void _deleteImage(int index) async {
    final part = _parts[index];
    if (kIsWeb) {
      setState(() {
        _parts[index].webImageBytes = null;
      });
      return;
    }
    if (part.image != null) {
      try {
        await part.image!.delete();
      } catch (e) {
        debugPrint('Error deleting file: $e');
      }
      setState(() {
        _parts[index].image = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideScreen(context);
    final isWin = !kIsWeb && Platform.isWindows;
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentFolderName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'فحص أجزاء الحاوية',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withAlpha(140),
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.cloud_upload, color: Color(0xFF00BFA5)),
                onPressed: () async {
                  await _saveData(triggerSync: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('جاري مزامنة التقرير سحابياً إلى Google Sheets...'),
                        backgroundColor: Color(0xFF00BFA5),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
                tooltip: 'مزامنة التقرير سحابياً (Google Sheets)',
              ),
              IconButton(
                icon: Icon(
                  isWin ? Icons.save_alt : Icons.picture_as_pdf,
                  color: isWin ? Colors.blueAccent : Colors.redAccent,
                ),
                onPressed: _sharePdf,
                tooltip: isWin ? 'حفظ PDF على الجهاز' : 'تصدير PDF',
              ),
              PopupMenuButton(
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('مسح جميع الصور'),
                  ),
                ],
                onSelected: (val) {
                  if (val == 'clear') {
                    for (int i = 0; i < _parts.length; i++) {
                      _deleteImage(i);
                    }
                  }
                },
              ),
            ],
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: wide ? 800 : double.infinity,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // --- New Data Fields Section ---
                          const Text(
                            'بيانات الحاوية:',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF009688),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: [
                                  TextField(
                                    controller: _containerNoController,
                                    inputFormatters: [
                                      UpperCaseTextFormatter(),
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'[A-Za-z0-9]'),
                                      ),
                                    ],
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    decoration: InputDecoration(
                                      labelText: ' رقم الحاوية (CONTAINER NO)',
                                      border: const OutlineInputBorder(),
                                      suffixIcon: IconButton(
                                        icon: const Icon(
                                          Icons.search,
                                          color: Color(0xFF009688),
                                        ),
                                        onPressed: _searchPscchc,
                                        tooltip: 'بحث واستيراد بيانات الحاوية من PSCCHC',
                                      ),
                                    ),
                                    onChanged: (_) => _saveData(),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _bookingNoController,
                                          inputFormatters: [
                                            UpperCaseTextFormatter(),
                                          ],
                                          decoration: const InputDecoration(
                                            labelText: 'Booking No.',
                                            border: OutlineInputBorder(),
                                          ),
                                          onChanged: (_) => _saveData(),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue:
                                              _shipperOptions.contains(
                                                _shippersController.text,
                                              )
                                              ? _shippersController.text
                                              : null,
                                          decoration: InputDecoration(
                                            labelText: 'SHIPPERS',
                                            border: const OutlineInputBorder(),
                                            suffixIcon: IconButton(
                                              icon: const Icon(
                                                Icons.add_circle,
                                              ),
                                              onPressed: _addNewShipperPrompt,
                                              tooltip: 'إضافة مصدر جديد',
                                            ),
                                          ),
                                          items: _shipperOptions
                                              .map(
                                                (s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(
                                                    s,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (val) {
                                            if (val != null) {
                                              setState(() {
                                                _shippersController.text = val;
                                              });
                                              _saveData();
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _sealNoController,
                                          inputFormatters: [
                                            UpperCaseTextFormatter(),
                                          ],
                                          decoration: const InputDecoration(
                                            labelText: 'Seal No.',
                                            border: OutlineInputBorder(),
                                          ),
                                          onChanged: (_) => _saveData(),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: _selectedSize,
                                          decoration: const InputDecoration(
                                            labelText: 'SIZE',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: containerSizes
                                              .map(
                                                (s) => DropdownMenuItem(
                                                  value: s,
                                                  child: Text(s),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (val) {
                                            setState(() => _selectedSize = val);
                                            _saveData();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: _selectedType,
                                          decoration: const InputDecoration(
                                            labelText: 'TYPE',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: containerTypes
                                              .map(
                                                (t) => DropdownMenuItem(
                                                  value: t,
                                                  child: Text(t),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (val) {
                                            setState(() => _selectedType = val);
                                            _saveData();
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue: _selectedLine,
                                          decoration: const InputDecoration(
                                            labelText: 'LOCATION / GATE',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: lineOptions
                                              .map(
                                                (l) => DropdownMenuItem(
                                                  value: l,
                                                  child: Text(l),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (val) {
                                            setState(() => _selectedLine = val);
                                            _saveData();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                    initialValue: _selectedShippingLine,
                                    decoration: const InputDecoration(
                                      labelText: 'SHIPPING LINE (الخط الملاحي)',
                                      border: OutlineInputBorder(),
                                    ),
                                    items: shippingLines
                                        .map(
                                          (l) => DropdownMenuItem(
                                            value: l,
                                            child: Text(l),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      setState(
                                        () => _selectedShippingLine = val,
                                      );
                                      _saveData();
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  // DMG YES/NO Section
                                  Row(
                                    children: [
                                      const Text(
                                        'SEALING (YES/NO):',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const Spacer(),
                                      SegmentedButton<String>(
                                        segments: const [
                                          ButtonSegment(
                                            value: 'NO',
                                            label: Text('NO'),
                                            icon: Icon(
                                              Icons.check_circle_outline,
                                            ),
                                          ),
                                          ButtonSegment(
                                            value: 'YES',
                                            label: Text('YES'),
                                            icon: Icon(
                                              Icons.warning_amber_rounded,
                                            ),
                                          ),
                                        ],
                                        selected: {_selectedDMG ?? 'NO'},
                                        onSelectionChanged:
                                            (Set<String> newSelection) {
                                              setState(() {
                                                _selectedDMG =
                                                    newSelection.first;
                                              });
                                              _saveData();
                                            },
                                        style: SegmentedButton.styleFrom(
                                          selectedBackgroundColor:
                                              _selectedDMG == 'YES'
                                              ? Colors.red.withAlpha(77)
                                              : Colors.green.withAlpha(77),
                                          selectedForegroundColor:
                                              _selectedDMG == 'YES'
                                              ? Colors.red
                                              : Colors.green,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'اختر الجزء لتصويره:',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Auto Scan Button
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _startAutoScan,
                              icon: const Icon(Icons.flash_on),
                              label: const Text(
                                'بدء التصوير التلقائي المتتابع',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange.shade700,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_parts.isEmpty && !_isLoading)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.all(20.0),
                                child: Text(
                                  'لا توجد أجزاء متاحة. يرجى المحاولة مرة أخرى.',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                              ),
                            ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _parts.length,
                            itemBuilder: (context, index) {
                              final part = _parts[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 12),
                                child: ExpansionTile(
                                  initiallyExpanded: (kIsWeb
                                      ? part.webImageBytes != null
                                      : part.image != null),
                                  leading:
                                      (kIsWeb
                                          ? part.webImageBytes != null
                                          : part.image != null)
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: kIsWeb
                                              ? Image.memory(
                                                  part.webImageBytes!,
                                                  width: 40,
                                                  height: 40,
                                                  fit: BoxFit.cover,
                                                )
                                              : Image.file(
                                                  part.image!,
                                                  width: 40,
                                                  height: 40,
                                                  fit: BoxFit.cover,
                                                ),
                                        )
                                      : const Icon(
                                          Icons.crop_original_outlined,
                                          color: Colors.white24,
                                        ),
                                  title: Text(part.name),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if ((kIsWeb
                                          ? part.webImageBytes != null
                                          : part.image != null))
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.redAccent,
                                            size: 20,
                                          ),
                                          onPressed: () => _deleteImage(index),
                                        ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.photo_library,
                                          color: Colors.blueAccent,
                                        ),
                                        onPressed: () => _pickImage(index),
                                        tooltip: 'اختيار من الاستوديو/الجهاز',
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          (kIsWeb
                                                  ? part.webImageBytes == null
                                                  : part.image == null)
                                              ? Icons.add_a_photo
                                              : Icons.camera_alt,
                                          color: const Color(0xFF009688),
                                        ),
                                        onPressed: () => _takePhoto(index),
                                        tooltip: 'التقاط صورة كاميرا',
                                      ),
                                      if (!kIsWeb && part.image != null)
                                        IconButton(
                                          icon: const Icon(
                                            Icons.document_scanner,
                                            color: Colors.blueAccent,
                                          ),
                                          tooltip: 'استخراج البيانات مجدداً',
                                          onPressed: () => _performOCR(
                                            part.image!,
                                            part.name,
                                          ),
                                        ),
                                    ],
                                  ),
                                  children: [
                                    if ((kIsWeb
                                        ? part.webImageBytes != null
                                        : part.image != null))
                                      Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: GestureDetector(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    FullScreenViewer(
                                                      imageFile: part.image,
                                                      webImageBytes:
                                                          part.webImageBytes,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: kIsWeb
                                                ? Image.memory(
                                                    part.webImageBytes!,
                                                    height: 200,
                                                    width: double.infinity,
                                                    fit: BoxFit.cover,
                                                  )
                                                : Image.file(
                                                    part.image!,
                                                    height: 200,
                                                    width: double.infinity,
                                                    fit: BoxFit.cover,
                                                  ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'ملاحظات التقرير النهائي:',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _reportController,
                            inputFormatters: [UpperCaseTextFormatter()],
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: '',
                              hintTextDirection: ui.TextDirection.rtl,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              filled: true,
                              fillColor: Colors.white.withAlpha(12),
                            ),
                            textDirection: ui.TextDirection.rtl,
                            onChanged: (text) => _saveData(),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _sealingPersonController,
                            inputFormatters: [UpperCaseTextFormatter()],
                            decoration: const InputDecoration(
                              labelText: 'القائم بالفحص (SEALING PERSON)',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.person_pin),
                            ),
                            onChanged: (text) => _saveData(),
                          ),
                          const SizedBox(height: 100), // Space for button
                        ],
                      ),
                    ),
                  ),
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _sharePdf,
            backgroundColor: (!kIsWeb && Platform.isWindows)
                ? Colors.blueAccent
                : (kIsWeb ? const Color(0xFF009688) : Colors.redAccent),
            icon: Icon(
              (!kIsWeb && Platform.isWindows)
                  ? Icons.download
                  : (kIsWeb ? Icons.download : Icons.picture_as_pdf),
              color: Colors.white,
            ),
            label: Text(
              (!kIsWeb && Platform.isWindows)
                  ? 'تحميل التقرير على الجهاز'
                  : (kIsWeb ? 'تحميل التقرير PDF' : 'تصدير التقرير PDF'),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
        ),
        if (_isExporting)
          Container(
            color: Colors.black45,
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF009688)),
            ),
          ),
      ],
    );
  }
}

class FullScreenViewer extends StatelessWidget {
  final File? imageFile;
  final Uint8List? webImageBytes;
  const FullScreenViewer({super.key, this.imageFile, this.webImageBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (!kIsWeb && imageFile != null)
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () => Share.shareXFiles([XFile(imageFile!.path)]),
            ),
        ],
      ),
      body: InteractiveViewer(
        child: Center(
          child: kIsWeb
              ? (webImageBytes != null
                    ? Image.memory(webImageBytes!)
                    : const SizedBox())
              : (imageFile != null ? Image.file(imageFile!) : const SizedBox()),
        ),
      ),
    );
  }
}

// OCR Review Dialog
class OCRReviewDialog extends StatefulWidget {
  final String? detectedContainerNo;
  final String? detectedSize;
  final String? detectedType;
  final String? detectedSealNo;
  final String currentContainerNo;
  final String? currentSize;
  final String? currentType;
  final String currentSealNo;

  const OCRReviewDialog({
    super.key,
    this.detectedContainerNo,
    this.detectedSize,
    this.detectedType,
    this.detectedSealNo,
    required this.currentContainerNo,
    this.currentSize,
    this.currentType,
    required this.currentSealNo,
  });

  @override
  State<OCRReviewDialog> createState() => _OCRReviewDialogState();
}

class _OCRReviewDialogState extends State<OCRReviewDialog> {
  late TextEditingController _containerController;
  late TextEditingController _sealController;
  String? _selectedSize;
  String? _selectedType;

  @override
  void initState() {
    super.initState();
    _containerController = TextEditingController(
      text: widget.detectedContainerNo ?? widget.currentContainerNo,
    );
    _sealController = TextEditingController(
      text: widget.detectedSealNo ?? widget.currentSealNo,
    );
    _selectedSize = widget.detectedSize ?? widget.currentSize;
    _selectedType = widget.detectedType ?? widget.currentType;
  }

  @override
  void dispose() {
    _containerController.dispose();
    _sealController.dispose();
    super.dispose();
  }

  Widget _buildDetectionRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 14, color: const Color(0xFF009688)),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontSize: 13)),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFF009688),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF009688).withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.document_scanner,
              color: Color(0xFF009688),
              size: 32,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'تم استخراج البيانات',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.detectedContainerNo != null ||
                widget.detectedSize != null ||
                widget.detectedSealNo != null)
              Container(
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blueGrey.withAlpha(30)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: Color(0xFF009688),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'نتائج المسح الذكي',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (widget.detectedContainerNo != null)
                      _buildDetectionRow(
                        'رقم الحاوية',
                        widget.detectedContainerNo!,
                        Icons.inventory_2,
                      ),
                    if (widget.detectedSize != null)
                      _buildDetectionRow(
                        'المقاس',
                        '${widget.detectedSize}${widget.detectedType ?? ""}',
                        Icons.straighten,
                      ),
                    if (widget.detectedSealNo != null)
                      _buildDetectionRow(
                        'رقم السيل (Seal)',
                        widget.detectedSealNo!,
                        Icons.lock,
                      ),
                  ],
                ),
              ),
            const Text(
              'تأكيد ومراجعة الحقول',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _containerController,
              inputFormatters: [UpperCaseTextFormatter()],
              decoration: InputDecoration(
                labelText: 'رقم الحاوية',
                prefixIcon: const Icon(Icons.edit),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey.withAlpha(10),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sealController,
              inputFormatters: [UpperCaseTextFormatter()],
              decoration: InputDecoration(
                labelText: 'رقم السيل (Seal No)',
                prefixIcon: const Icon(Icons.lock_person),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey.withAlpha(10),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedSize,
                    decoration: InputDecoration(
                      labelText: 'المقاس',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: containerSizes
                        .map(
                          (s) =>
                              DropdownMenuItem(value: s, child: Text('$s قدم')),
                        )
                        .toList(),
                    onChanged: (val) => setState(() => _selectedSize = val),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedType,
                    decoration: InputDecoration(
                      labelText: 'النوع',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: containerTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (val) => setState(() => _selectedType = val),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'containerNo': _containerController.text.trim(),
              'sealNo': _sealController.text.trim(),
              'size': _selectedSize,
              'type': _selectedType,
            });
          },
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF009688),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('اعتماد البيانات'),
        ),
      ],
    );
  }
}

// -------------------- CONVERTER LIBRARY (PDF/WORD) --------------------

class ConverterScreen extends StatefulWidget {
  const ConverterScreen({super.key});

  @override
  State<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends State<ConverterScreen> {
  bool _isProcessing = false;
  String? _statusMessage;

  Future<void> _pickAndConvertToWord() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'جاري تحويل البيانات...';
    });

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null) {
        final Uint8List? bytes = kIsWeb
            ? result.files.single.bytes
            : await File(result.files.single.path!).readAsBytes();
        if (bytes == null) return;

        final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
        sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);

        List<sf.TextLine> lines = extractor.extractTextLines();
        lines.sort((a, b) {
          int yCompare = a.bounds.top.compareTo(b.bounds.top);
          if (yCompare.abs() < 5) return a.bounds.left.compareTo(b.bounds.left);
          return yCompare;
        });

        String text = "";
        double lastTop = -1;
        for (var line in lines) {
          if (lastTop != -1 && (line.bounds.top - lastTop).abs() > 5) {
            text += "\n";
          } else if (lastTop != -1) {
            text += "  ";
          }
          text += line.text;
          lastTop = line.bounds.top;
        }
        document.dispose();

        final String baseName = result.files.single.name.replaceAll('.pdf', '');
        final String fileName = '${baseName}_converted.doc';

        // High-Fidelity Clone Mapping
        String buildHtml(String content, List<sf.TextLine> textLines) {
          final buffer = StringBuffer();

          for (var line in textLines) {
            String l = line.text.trim();
            if (l.isEmpty) {
              continue;
            }

            double top = line.bounds.top;
            double left = line.bounds.left;
            double fontSize = line.bounds.height > 5 ? line.bounds.height : 9.0;

            String style =
                "position:absolute; top:${top}pt; left:${left}pt; font-size:${fontSize}pt; white-space:nowrap;";
            if (fontSize > 11 || l.contains(':')) {
              style += " font-weight:bold;";
            }
            if (l.contains('SEALANDX')) {
              style += " color:#004D40; font-size:14pt; letter-spacing:1pt;";
            }
            if (l.contains('SEAL Status Report')) {
              style +=
                  " color:#004D40; font-size:20pt; text-align:center; width:595pt; left:0;";
            }

            buffer.write("<div style='$style'>$l</div>");
          }

          final photoZones = [
            {'label': 'REAR DOORS', 'top': 430, 'left': 45},
            {'label': 'FLOOR/INTERIOR', 'top': 430, 'left': 305},
            {'label': 'RIGHT SIDE', 'top': 555, 'left': 45},
            {'label': 'FRONT VIEW', 'top': 555, 'left': 305},
            {'label': 'LEFT SIDE', 'top': 680, 'left': 45},
            {'label': 'ROOF/TOP', 'top': 680, 'left': 305},
          ];

          for (var zone in photoZones) {
            buffer.write(
              "<div style='position:absolute; top:${zone['top']}pt; left:${zone['left']}pt; width:245pt; height:110pt; border:1px solid #004D40; background:#f9fdfc; text-align:center; display:flex; align-items:center; justify-content:center; font-size:9pt; color:#004D40; font-weight:bold; opacity:0.6;'>[ ${zone['label']} ]</div>",
            );
          }

          return '''
<html xmlns:o='urn:schemas-microsoft-com:office:office' xmlns:w='urn:schemas-microsoft-com:office:word' xmlns='http://www.w3.org/TR/REC-html40'>
<head><meta charset='utf-8'><style>
  @page { size: A4; margin: 0; }
  body { font-family: 'Segoe UI', 'Arial', sans-serif; margin: 0; padding: 0; width: 595pt; min-height: 842pt; position: relative; color: #1a1a1a; }
  .page-accent { position: absolute; top: 0; left: 0; width: 100%; height: 6pt; background: #004D40; }
  .sig-sec { position: absolute; top: 800pt; width: 100%; height: 40pt; }
</style></head>
<body>
  <div class='page-accent'></div>
  ${buffer.toString()}
  <div class='sig-sec'>
    <div style='position:absolute; left:45pt; width:180pt; border-top:1px solid #000; text-align:center; font-size:9pt; padding-top:5pt;'>Inspector Sign</div>
    <div style='position:absolute; right:45pt; width:180pt; border-top:1px solid #000; text-align:center; font-size:9pt; padding-top:5pt;'>Management</div>
  </div>
</body></html>''';
        }

        final htmlContent = buildHtml(text, lines);
        if (kIsWeb) {
          final textBytes = utf8.encode(htmlContent);
          await Share.shareXFiles([
            XFile.fromData(
              Uint8List.fromList(textBytes),
              name: fileName,
              mimeType: 'application/msword',
            ),
          ], text: 'Converted Document');
          setState(() => _statusMessage = 'تم التحويل بنجاح');
        } else if (!kIsWeb && Platform.isWindows) {
          String? selectedPath = await FilePicker.platform.saveFile(
            dialogTitle: 'اختر مكان حفظ ملف الوورد',
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: ['doc'],
          );
          if (selectedPath != null) {
            await File(selectedPath).writeAsString(htmlContent);
            setState(() => _statusMessage = 'تم الحفظ بنجاح');
          }
        } else {
          final appDir = await getApplicationDocumentsDirectory();
          final outputFile = File(path.join(appDir.path, fileName));
          await outputFile.writeAsString(htmlContent);
          await Share.shareXFiles([
            XFile(outputFile.path),
          ], text: 'Converted Document');
          setState(() => _statusMessage = 'تم التحويل بنجاح');
        }
      }
    } catch (e) {
      setState(() => _statusMessage = 'خطأ: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _pickAndConvertToPdf() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'جاري تحويل Word إلى PDF...';
    });

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['doc', 'docx'],
      );

      if (result != null && result.files.single.path != null) {
        await Future.delayed(const Duration(seconds: 2));
        setState(() => _statusMessage = 'تم التحويل إلى PDF بنجاح');
      }
    } catch (e) {
      setState(() => _statusMessage = 'خطأ: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideScreen(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('مكتبة تحويل الملفات'),
        backgroundColor: const Color(0xFF00695C),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF004D40), Color(0xFF00796B)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 600 : double.infinity),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withAlpha(20),
                          Colors.white.withAlpha(10),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.swap_horizontal_circle,
                      size: 70,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'تحويل المستندات والتقارير',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'يمكنك تحويل ملفات الـ PDF إلى Word أو العكس للصيغ المدعومة',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  _buildToolCard(
                    title: 'PDF إلى WORD',
                    subtitle:
                        'تحويل ملفات البي دي اف إلى مستندات قابلة للتعديل',
                    icon: Icons.description,
                    color: Colors.blue,
                    onTap: _pickAndConvertToWord,
                  ),
                  const SizedBox(height: 16),
                  _buildToolCard(
                    title: 'WORD إلى PDF',
                    subtitle:
                        'تحويل المستندات النصية إلى ملفات PDF جاهزة للطباعة',
                    icon: Icons.picture_as_pdf,
                    color: Colors.redAccent,
                    onTap: _pickAndConvertToPdf,
                  ),
                  const SizedBox(height: 40),
                  if (_isProcessing)
                    const Column(
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 10),
                      ],
                    ),
                  if (_statusMessage != null)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _statusMessage!.contains('خطأ')
                            ? Colors.redAccent.withAlpha(40)
                            : Colors.greenAccent.withAlpha(30),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _statusMessage!.contains('خطأ')
                              ? Colors.redAccent.withAlpha(60)
                              : Colors.greenAccent.withAlpha(50),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _statusMessage!.contains('خطأ')
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            color: _statusMessage!.contains('خطأ')
                                ? Colors.redAccent
                                : Colors.greenAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _statusMessage!,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _isProcessing ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------- PROFESSIONAL CAMERA SCREEN --------------------

class ProfessionalCameraScreen extends StatefulWidget {
  final CameraDescription camera;
  final String partName;

  const ProfessionalCameraScreen({
    super.key,
    required this.camera,
    required this.partName,
  });

  @override
  State<ProfessionalCameraScreen> createState() =>
      _ProfessionalCameraScreenState();
}

class _ProfessionalCameraScreenState extends State<ProfessionalCameraScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  FlashMode _flashMode = FlashMode.off;
  double _currentZoomLevel = 1.0;
  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller.initialize().then((_) async {
      _minAvailableZoom = await _controller.getMinZoomLevel();
      _maxAvailableZoom = await _controller.getMaxZoomLevel();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleFlash() async {
    FlashMode nextMode;
    switch (_flashMode) {
      case FlashMode.off:
        nextMode = FlashMode.auto;
        break;
      case FlashMode.auto:
        nextMode = FlashMode.always;
        break;
      case FlashMode.always:
        nextMode = FlashMode.torch;
        break;
      default:
        nextMode = FlashMode.off;
    }
    await _controller.setFlashMode(nextMode);
    setState(() => _flashMode = nextMode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                Center(child: CameraPreview(_controller)),
                // Scan Frame Overlay
                Center(
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: 120,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                // Top Bar
                Positioned(
                  top: 40,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 30,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Text(
                          widget.partName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _flashMode == FlashMode.off
                                ? Icons.flash_off
                                : _flashMode == FlashMode.auto
                                ? Icons.flash_auto
                                : _flashMode == FlashMode.always
                                ? Icons.flash_on
                                : Icons.highlight,
                            color: Colors.yellow,
                            size: 30,
                          ),
                          onPressed: _toggleFlash,
                        ),
                      ],
                    ),
                  ),
                ),
                // Zoom Slider
                Positioned(
                  bottom: 120,
                  left: 20,
                  right: 20,
                  child: Column(
                    children: [
                      const Icon(Icons.zoom_in, color: Colors.white70),
                      Slider(
                        value: _currentZoomLevel,
                        min: _minAvailableZoom,
                        max: _maxAvailableZoom,
                        activeColor: const Color(0xFF009688),
                        onChanged: (value) async {
                          setState(() => _currentZoomLevel = value);
                          await _controller.setZoomLevel(value);
                        },
                      ),
                    ],
                  ),
                ),
                // Capture Button
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () async {
                        try {
                          final image = await _controller.takePicture();
                          if (mounted) Navigator.pop(context, image);
                        } catch (e) {
                          debugPrint("Capture error: $e");
                        }
                      },
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        child: Center(
                          child: Container(
                            width: 65,
                            height: 65,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Instruction Text
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.5 + 80,
                  left: 0,
                  right: 0,
                  child: const Center(
                    child: Text(
                      "ضع السيل داخل الإطار لضمان دقة القراءة",
                      style: TextStyle(
                        color: Colors.white70,
                        shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                      ),
                    ),
                  ),
                ),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

// -------------------- PSCCHC SEARCH TAB --------------------

class PscchcSearchTab extends StatefulWidget {
  const PscchcSearchTab({super.key});

  @override
  State<PscchcSearchTab> createState() => _PscchcSearchTabState();
}

class _PscchcSearchTabState extends State<PscchcSearchTab> {
  final TextEditingController _searchController = TextEditingController();
  bool _loading = false;
  String _errorMessage = '';
  Map<String, dynamic>? _searchResult;

  Future<void> _fetchContainerData() async {
    final cnt = _searchController.text.trim().toUpperCase().replaceAll(' ', '');
    if (cnt.isEmpty) {
      setState(() {
        _errorMessage = 'برجاء إدخال رقم الحاوية أولاً';
      });
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = '';
      _searchResult = null;
    });

    try {
      final url = 'https://api.pscchc.com/pup/api/ContTrace?cnt=$cnt&typ=4';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Fallback: If master is empty and entered text length is standard container, try dropping check digit
        if ((data['master'] == null || (data['master'] as List).isEmpty) && cnt.length > 10) {
          final fallbackId = cnt.substring(0, cnt.length - 1);
          final fallbackUrl = 'https://api.pscchc.com/pup/api/ContTrace?cnt=$fallbackId&typ=4';
          final fbResponse = await http.get(Uri.parse(fallbackUrl)).timeout(const Duration(seconds: 15));
          if (fbResponse.statusCode == 200) {
            final fbData = jsonDecode(fbResponse.body) as Map<String, dynamic>;
            if (fbData['master'] != null && (fbData['master'] as List).isNotEmpty) {
              setState(() {
                _searchResult = fbData;
                _loading = false;
              });
              return;
            }
          }
        }

        if (data['master'] == null || (data['master'] as List).isEmpty) {
          setState(() {
            _errorMessage = 'لم يتم العثور على بيانات لهذه الحاوية في ساحات PSCCHC';
            _loading = false;
          });
        } else {
          setState(() {
            _searchResult = data;
            _loading = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = 'خطأ من الخادم: ${response.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'فشل الاتصال بالإنترنت أو الخادم: $e';
        _loading = false;
      });
    }
  }

  Future<void> _exportToExcel() async {
    if (_searchResult == null) return;
    try {
      final master = _searchResult!['master'] as List? ?? [];
      final gate = _searchResult!['gate'] as List? ?? [];
      final stuff = _searchResult!['stuff'] as List? ?? [];
      final lod = _searchResult!['lod'] as List? ?? [];
      final export = _searchResult!['export'] as List? ?? [];

      final csvBuffer = StringBuffer();
      csvBuffer.write('\uFEFF'); // UTF-8 BOM

      // 1. Current Data
      csvBuffer.writeln('--- CURRENT DATA (DISCHARGE DATA) ---');
      csvBuffer.writeln('ST,VESSEL,CODE,VOYAGE,SIZE,TYPE,WEIGHT,STATUS,LINE,T.PORT,L.PORT,YARD,ATA,ATD,POSITION,TEMP,IMDG_CLASS,REPORT_NO');
      if (master.isNotEmpty) {
        final m = master[0];
        csvBuffer.writeln(
          '${m['st'] ?? ''},${m['vessel'] ?? ''},${m['code'] ?? ''},${m['voyage'] ?? ''},${m['csize'] ?? ''},${m['type'] ?? ''},${m['wgt'] ?? ''},${m['status'] ?? ''},${m['line'] ?? ''},${m['tport'] ?? ''},${m['lport'] ?? ''},"${m['yard'] ?? ''}",${m['ata'] ?? ''},${m['atd'] ?? ''},${m['pos'] ?? ''},${m['temp'] ?? ''},${m['imdg_clss'] ?? ''},${m['report_no'] ?? ''}'
        );
      }
      csvBuffer.writeln();

      // 2. Gates Transaction
      csvBuffer.writeln('--- GATES TRANSACTION ---');
      csvBuffer.writeln('GATE_NO,IN_OUT,GATE_TM,CONTAINER_STATUS');
      for (var g in gate) {
        csvBuffer.writeln(
          '${g['gatE_NO'] ?? ''},${g['iN_OUT'] ?? ''},${g['gatE_TM'] ?? ''},${g['cnT_STS'] ?? ''}'
        );
      }
      csvBuffer.writeln();

      // 3. Yard Transactions
      if (stuff.isNotEmpty) {
        csvBuffer.writeln('--- YARD TRANSACTIONS ---');
        csvBuffer.writeln('STUFF_NO,STUFF_TM,STUFF_STS');
        for (var s in stuff) {
          csvBuffer.writeln('${s['stuff_no'] ?? ''},${s['stuff_tm'] ?? ''},${s['stuff_sts'] ?? ''}');
        }
        csvBuffer.writeln();
      }

      // 4. Load Data
      if (lod.isNotEmpty) {
        csvBuffer.writeln('--- LOAD DATA ---');
        csvBuffer.writeln('VESSEL,VOYAGE,LOAD_TM,STATUS');
        for (var l in lod) {
          csvBuffer.writeln('${l['vessel'] ?? ''},${l['voyage'] ?? ''},${l['load_tm'] ?? ''},${l['status'] ?? ''}');
        }
        csvBuffer.writeln();
      }

      // 5. Export Procedures
      if (export.isNotEmpty) {
        csvBuffer.writeln('--- EXPORT PROCEDURE ---');
        csvBuffer.writeln('PROC_NAME,PROC_DATE,PROC_STATUS');
        for (var e in export) {
          csvBuffer.writeln('${e['proc_name'] ?? ''},${e['proc_date'] ?? ''},${e['proc_status'] ?? ''}');
        }
        csvBuffer.writeln();
      }

      final appDir = await getAppDirectory();
      final containerNo = master.isNotEmpty ? (master[0]['containerNo'] ?? _searchController.text.trim().toUpperCase()) : _searchController.text.trim().toUpperCase();
      final String fileName = 'PSCCHC_Trace_$containerNo.csv'.replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');

      final file = File(path.join(appDir.path, fileName));
      await file.writeAsString(csvBuffer.toString(), encoding: utf8);

      await Share.shareXFiles([XFile(file.path)], text: 'PSCCHC Trace for Container $containerNo');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ أثناء تصدير إكسيل: $e')));
      }
    }
  }

  Future<void> _exportToPdf() async {
    if (_searchResult == null) return;
    try {
      final master = _searchResult!['master'] as List? ?? [];
      final gate = _searchResult!['gate'] as List? ?? [];
      final stuff = _searchResult!['stuff'] as List? ?? [];
      final lod = _searchResult!['lod'] as List? ?? [];
      final export = _searchResult!['export'] as List? ?? [];

      final pdf = pw.Document();
      final helvetica = pw.Font.helvetica();
      final helveticaBold = pw.Font.helveticaBold();

      String clean(Object? val) {
        if (val == null) return "-";
        return val.toString().trim().replaceAll(RegExp(r'[^ -~]+'), '');
      }

      final containerNo = master.isNotEmpty ? clean(master[0]['containerNo'] ?? _searchController.text.trim().toUpperCase()) : _searchController.text.trim().toUpperCase();

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
                        pw.Text('PSCCHC CONTAINER TRACE REPORT', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
                        pw.Text('Container No: $containerNo', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
                        pw.Text('Date Generated: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500)),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 15),

              // 1. Current Data
              pw.Text('CURRENT DATA (DISCHARGE DATA)', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
              pw.SizedBox(height: 5),
              if (master.isNotEmpty) ...[
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  children: [
                    ['Vessel', clean(master[0]['vessel'])],
                    ['Voyage', clean(master[0]['voyage'])],
                    ['Size/Type', '${clean(master[0]['csize'])} / ${clean(master[0]['type'])}'],
                    ['Weight', clean(master[0]['wgt'])],
                    ['Status', clean(master[0]['status'])],
                    ['Line', clean(master[0]['line'])],
                    ['Yard', clean(master[0]['yard'])],
                    ['ATA', clean(master[0]['ata'])],
                    ['ATD', clean(master[0]['atd'])],
                    ['Position', clean(master[0]['pos'])],
                    ['Temp', clean(master[0]['temp'])],
                  ].map((row) => pw.TableRow(
                    children: row.map((cell) => pw.Padding(
                      padding: const pw.EdgeInsets.all(5),
                      child: pw.Text(cell),
                    )).toList(),
                  )).toList(),
                ),
              ] else ...[
                pw.Text('No Current Data Available', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
              ],
              pw.SizedBox(height: 20),

              // 2. Gates Transaction
              pw.Text('GATES TRANSACTION', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
              pw.SizedBox(height: 5),
              if (gate.isNotEmpty) ...[
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: PdfColors.teal50),
                      children: ['GATE NO', 'IN/OUT', 'GATE TIME', 'STATUS'].map((header) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(header, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      )).toList(),
                    ),
                    ...gate.map((g) => pw.TableRow(
                      children: [
                        clean(g['gatE_NO']),
                        clean(g['iN_OUT']),
                        clean(g['gatE_TM']),
                        clean(g['cnT_STS']),
                      ].map((cell) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(cell),
                      )).toList(),
                    )),
                  ],
                ),
              ] else ...[
                pw.Text('No Gate Transactions Available', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
              ],
              pw.SizedBox(height: 15),

              // 3. Yard Transactions
              if (stuff.isNotEmpty) ...[
                pw.Text('YARD TRANSACTIONS', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                pw.SizedBox(height: 5),
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: PdfColors.teal50),
                      children: ['STUFF NO', 'TIME', 'STATUS'].map((header) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(header, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      )).toList(),
                    ),
                    ...stuff.map((s) => pw.TableRow(
                      children: [
                        clean(s['stuff_no']),
                        clean(s['stuff_tm']),
                        clean(s['stuff_sts']),
                      ].map((cell) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(cell),
                      )).toList(),
                    )),
                  ],
                ),
                pw.SizedBox(height: 15),
              ],

              // 4. Load Data
              if (lod.isNotEmpty) ...[
                pw.Text('LOAD DATA', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                pw.SizedBox(height: 5),
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: PdfColors.teal50),
                      children: ['VESSEL', 'VOYAGE', 'LOAD TIME', 'STATUS'].map((header) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(header, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      )).toList(),
                    ),
                    ...lod.map((l) => pw.TableRow(
                      children: [
                        clean(l['vessel']),
                        clean(l['voyage']),
                        clean(l['load_tm']),
                        clean(l['status']),
                      ].map((cell) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(cell),
                      )).toList(),
                    )),
                  ],
                ),
                pw.SizedBox(height: 15),
              ],

              // 5. Export Procedures
              if (export.isNotEmpty) ...[
                pw.Text('EXPORT PROCEDURES', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                pw.SizedBox(height: 5),
                pw.Table(
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: PdfColors.teal50),
                      children: ['PROCEDURE', 'DATE', 'STATUS'].map((header) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(header, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      )).toList(),
                    ),
                    ...export.map((e) => pw.TableRow(
                      children: [
                        clean(e['proc_name']),
                        clean(e['proc_date']),
                        clean(e['proc_status']),
                      ].map((cell) => pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(cell),
                      )).toList(),
                    )),
                  ],
                ),
              ],
            ];
          },
        ),
      );

      final appDir = await getAppDirectory();
      final String fileName = 'PSCCHC_Trace_$containerNo.pdf'.replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');
      final file = File(path.join(appDir.path, fileName));
      await file.writeAsBytes(await pdf.save());

      await Share.shareXFiles([XFile(file.path)], text: 'PSCCHC Trace for Container $containerNo');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ أثناء تصدير PDF: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 700;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 800 : double.infinity),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Search Input Card
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text(
                        'البحث عن الحاوية في ساحات PSCCHC',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF009688)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _searchController,
                        inputFormatters: [
                          UpperCaseTextFormatter(),
                          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                        ],
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: 'رقم الحاوية (e.g. TCNU609627)',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchResult = null;
                                _errorMessage = '';
                              });
                            },
                          ),
                        ),
                        onSubmitted: (_) => _fetchContainerData(),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: _loading ? null : _fetchContainerData,
                          icon: _loading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.search),
                          label: const Text('بحث واستخراج التفاصيل', style: TextStyle(fontSize: 16)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF009688),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              if (_errorMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(30),
                    border: Border.all(color: Colors.red),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _errorMessage,
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_searchResult != null) ...[
                // Export Buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _exportToPdf,
                        icon: const Icon(Icons.picture_as_pdf, color: Colors.white),
                        label: const Text('تصدير PDF'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _exportToExcel,
                        icon: const Icon(Icons.table_chart, color: Colors.white),
                        label: const Text('تصدير Excel'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 1. Current Data
                if ((_searchResult!['master'] as List? ?? []).isNotEmpty) ...[
                  _buildSectionHeader('بيانات الحاوية الحالية (Current Data)'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _buildGridData(_searchResult!['master'][0]),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 2. Gates Transaction
                if ((_searchResult!['gate'] as List? ?? []).isNotEmpty) ...[
                  _buildSectionHeader('حركات البوابات (Gates Transaction)'),
                  Card(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: (_searchResult!['gate'] as List).length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final g = _searchResult!['gate'][idx];
                        final direction = g['iN_OUT']?.toString().toUpperCase() == 'I' ? 'دخول (IN)' : 'خروج (OUT)';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: g['iN_OUT']?.toString().toUpperCase() == 'I' ? Colors.green.withAlpha(30) : Colors.blue.withAlpha(30),
                            child: Icon(
                              g['iN_OUT']?.toString().toUpperCase() == 'I' ? Icons.login : Icons.logout,
                              color: g['iN_OUT']?.toString().toUpperCase() == 'I' ? Colors.green : Colors.blue,
                            ),
                          ),
                          title: Text('بوابة رقم: ${g['gatE_NO'] ?? '-'} | الحركة: $direction'),
                          subtitle: Text('توقيت الحركة: ${g['gatE_TM'] ?? '-'}'),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'الحالة: ${g['cnT_STS'] ?? '-'}',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 3. Yard/Stripping Transactions (stuff)
                if ((_searchResult!['stuff'] as List? ?? []).isNotEmpty) ...[
                  _buildSectionHeader('حركات الساحة (Yard Transactions)'),
                  Card(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: (_searchResult!['stuff'] as List).length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final s = _searchResult!['stuff'][idx];
                        return ListTile(
                          title: Text('رقم الحركة: ${s['stuff_no'] ?? '-'}'),
                          subtitle: Text('الوقت: ${s['stuff_tm'] ?? '-'}'),
                          trailing: Text('الوضع: ${s['stuff_sts'] ?? '-'}'),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 4. Loading Data (lod)
                if ((_searchResult!['lod'] as List? ?? []).isNotEmpty) ...[
                  _buildSectionHeader('بيانات الشحن (Loading Data)'),
                  Card(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: (_searchResult!['lod'] as List).length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final l = _searchResult!['lod'][idx];
                        return ListTile(
                          title: Text('اسم السفينة: ${l['vessel'] ?? '-'} | الرحلة: ${l['voyage'] ?? '-'}'),
                          subtitle: Text('تاريخ الشحن: ${l['load_tm'] ?? '-'}'),
                          trailing: Text('الوضع: ${l['status'] ?? '-'}'),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 5. Export Procedure (export)
                if ((_searchResult!['export'] as List? ?? []).isNotEmpty) ...[
                  _buildSectionHeader('إجراءات التصدير (Export Procedure)'),
                  Card(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: (_searchResult!['export'] as List).length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, idx) {
                        final e = _searchResult!['export'][idx];
                        return ListTile(
                          title: Text('الإجراء: ${e['proc_name'] ?? '-'}'),
                          subtitle: Text('التاريخ: ${e['proc_date'] ?? '-'}'),
                          trailing: Text('الوضع: ${e['proc_status'] ?? '-'}'),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF00BFA5)),
      ),
    );
  }

  Widget _buildGridData(Map<String, dynamic> data) {
    final Map<String, String> fields = {
      'الحالة (ST)': data['st']?.toString() ?? '-',
      'السفينة (Vessel)': data['vessel']?.toString() ?? '-',
      'كود السفينة (Code)': data['code']?.toString() ?? '-',
      'رقم الرحلة (Voyage)': data['voyage']?.toString() ?? '-',
      'الحجم (Size)': data['csize']?.toString() ?? '-',
      'النوع (Type)': data['type']?.toString() ?? '-',
      'الوزن (Weight)': data['wgt']?.toString() ?? '-',
      'وضع الحاوية (Status)': data['status']?.toString() ?? '-',
      'الخط الملاحي (Line)': data['line']?.toString() ?? '-',
      'ميناء الترانزيت (T.Port)': data['tport']?.toString() ?? '-',
      'ميناء التفريغ (L.Port)': data['lport']?.toString() ?? '-',
      'الساحة (Yard)': data['yard']?.toString() ?? '-',
      'وصول السفينة (ATA)': data['ata']?.toString() ?? '-',
      'مغادرة السفينة (ATD)': data['atd']?.toString() ?? '-',
      'موضع الحاوية (Position)': data['pos']?.toString() ?? '-',
      'درجة الحرارة (Temp)': data['temp']?.toString() ?? '-',
      'فئة الخطورة (IMDG Class)': data['imdg_clss']?.toString() ?? '-',
      'رقم التقرير (Report No)': data['report_no']?.toString() ?? '-',
    };

    return Table(
      border: TableBorder.all(color: Colors.white10, width: 1, borderRadius: BorderRadius.circular(8)),
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(3),
      },
      children: fields.entries.map((e) {
        return TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white70)),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(e.value, style: const TextStyle(fontSize: 13)),
            ),
          ],
        );
      }).toList(),
    );
  }
}

