/**
 * =========================================================================
 * SEALANDX EXPORT - GOOGLE APPS SCRIPT WEB APP FOR ALL-DATA & DECLARATIONS
 * =========================================================================
 * هذا السكريبت مخصص للربط المباشر مع شيت:
 * SealandX Export Tracking Record (صفحة All-Data ونظام الإقرارات)
 * 
 * الرابط الأساسي للشيت:
 * https://docs.google.com/spreadsheets/d/1U4T67Ao9HoE-p9pQjE_FVP_Kba5fa258vbxP4L1p41M/edit
 * 
 * الوظائف الرئيسية:
 * 1. استقبال بيانات فحص وتسيل الحاويات من تطبيق SealandX Export.
 * 2. البحث الذكي في صفحة All-Data: إذا كانت الحاوية مسجلة يتم تحديثها، وإذا كانت جديدة يتم إدراجها في أول صف فارغ.
 * 3. الحفاظ التلقائي على معادلة كود الإقرار في العمود B: =C{row}&COUNTIF($C$6:C{row},C{row})
 *    ومعادلة المسلسل في العمود A: =ROW()-5
 * 4. إنشاء وتنسيق العمود M (Col 13) في All-Data كخانة خاصة برابط تقرير الـ PDF.
 * 5. رفع ملف الـ PDF الناتج إلى مجلد SealandX_Export_PDFs على Google Drive وتوليد رابط عرض مباشر =HYPERLINK.
 * 6. بمجرد إدخال رقم البوكينج في صفحة "اقرار" (الخلية O4)، تظهر كافة البيانات جاهزة للطباعة فوراً!
 * =========================================================================
 */

var SPREADSHEET_ID = "1U4T67Ao9HoE-p9pQjE_FVP_Kba5fa258vbxP4L1p41M";
var TARGET_SHEET_NAME = "All-Data";

function doGet(e) {
  var html = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>SealandX Export Sync Web App</title>'
    + '<style>body{font-family:Segoe UI,Tahoma,Arial,sans-serif;direction:rtl;text-align:center;padding:50px;background:#101d1d;color:#e0f2f1;}'
    + '.card{background:#1a2c2c;border-radius:14px;padding:35px;max-width:650px;margin:auto;box-shadow:0 8px 30px rgba(0,0,0,0.6);border:1px solid #00BFA5;}'
    + 'h1{color:#00BFA5;margin-bottom:10px;}p{line-height:1.7;font-size:16px;}.badge{background:#00BFA5;color:#00332c;padding:6px 14px;border-radius:20px;font-weight:bold;font-size:14px;}'
    + '.sheet-info{background:#122020;padding:12px;border-radius:8px;margin:20px 0;text-align:right;font-size:14px;color:#80cbc4;}'
    + '</style></head><body>'
    + '<div class="card">'
    + '<h1>⚓ SealandX Export Sync Web App</h1>'
    + '<p><span class="badge">الخدمة تعمل ومتصلة بالشيت بنجاح ✓</span></p>'
    + '<div class="sheet-info">'
    + '📌 <b>الصفحة المستهدفة:</b> All-Data (تغذية نظام الإقرارات)<br>'
    + '📄 <b>عمود رابط الـ PDF:</b> العمود M (Col 13)<br>'
    + '🕒 <b>توقيت الخادم:</b> ' + new Date().toLocaleString()
    + '</div>'
    + '<p>الخدمة جاهزة لاستقبال تقارير الحاويات من تطبيق SealandX Export وحفظها تلقائياً.</p>'
    + '</div></body></html>';
  
  return HtmlService.createHtmlOutput(html)
    .setTitle("SealandX Export Sync Web App")
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}

function doPost(e) {
  var output = {};
  
  try {
    if (!e || !e.postData || !e.postData.contents) {
      throw new Error("لم يتم استلام أي بيانات في الطلب (Empty payload)");
    }

    var data = JSON.parse(e.postData.contents);
    var action = data.action || 'addReport';

    if (action === 'test') {
      output = {
        status: "success",
        message: "الاتصال بخدمة مزامنة SealandX Export يعمل بنجاح! ✓"
      };
      return ContentService.createTextOutput(JSON.stringify(output))
        .setMimeType(ContentService.MimeType.JSON);
    }

    if (action === 'addReport') {
      var result = handleAddOrUpdateReport(data);
      output = {
        status: "success",
        message: "تم حفظ بيانات الحاوية والتقرير في All-Data بنجاح! ✓",
        containerNo: result.containerNo,
        bookingNo: result.bookingNo,
        rowNumber: result.rowNumber,
        isUpdate: result.isUpdate,
        pdfUrl: result.pdfUrl
      };
    } else {
      throw new Error("إجراء غير معروف: " + action);
    }

  } catch (err) {
    output = {
      status: "error",
      message: err.toString()
    };
  }

  return ContentService.createTextOutput(JSON.stringify(output))
    .setMimeType(ContentService.MimeType.JSON);
}

/**
 * دالة إضافة أو تحديث الحاوية في صفحة All-Data ورفع الـ PDF
 */
function handleAddOrUpdateReport(data) {
  var ss;
  if (data.spreadsheetUrl && data.spreadsheetUrl.trim().length > 0) {
    try {
      ss = SpreadsheetApp.openByUrl(data.spreadsheetUrl.trim());
    } catch (_) {
      ss = SpreadsheetApp.openById(SPREADSHEET_ID);
    }
  } else {
    try {
      ss = SpreadsheetApp.getActiveSpreadsheet();
    } catch (_) {}
    if (!ss) {
      ss = SpreadsheetApp.openById(SPREADSHEET_ID);
    }
  }

  if (!ss) {
    throw new Error("تعذر فتح ملف Google Spreadsheet.");
  }

  var sheetName = data.targetSheetName || TARGET_SHEET_NAME;
  var sheet = ss.getSheetByName(sheetName);
  if (!sheet) {
    sheet = ss.getSheetByName(TARGET_SHEET_NAME);
  }
  if (!sheet) {
    throw new Error("صفحة " + sheetName + " غير موجودة في الشيت.");
  }

  // 1. التأكد من وجود ترويسة عمود الـ PDF في الخلية M5 (العمود 13)
  var headerM = sheet.getRange(5, 13).getValue();
  if (!headerM || headerM.toString().trim() === "") {
    var cellM5 = sheet.getRange(5, 13);
    cellM5.setValue("تقرير PDF (Google Drive)")
          .setBackground("#00897B")
          .setFontColor("#FFFFFF")
          .setFontWeight("bold")
          .setHorizontalAlignment("center")
          .setVerticalAlignment("middle");
    sheet.setColumnWidth(13, 160);
  }

  // 2. معالجة وحفظ ملف الـ PDF في Google Drive
  var pdfUrl = "";
  if (data.pdfBase64 && data.pdfBase64.trim().length > 0) {
    try {
      var folderName = "SealandX_Export_PDFs";
      var folders = DriveApp.getFoldersByName(folderName);
      var folder;
      if (folders.hasNext()) {
        folder = folders.next();
      } else {
        folder = DriveApp.createFolder(folderName);
        folder.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
      }

      var cNo = (data.containerNo || "CONTAINER").toString().trim().toUpperCase();
      var sNo = (data.sealNo || "").toString().trim().toUpperCase();
      var bNo = (data.bookingNo || "").toString().trim().toUpperCase();
      var dateStr = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyyMMdd_HHmmss");
      var fileName = cNo + (bNo ? "_" + bNo : "") + (sNo ? "_" + sNo : "") + "_" + dateStr + ".pdf";

      var decodedBytes = Utilities.base64Decode(data.pdfBase64);
      var blob = Utilities.newBlob(decodedBytes, "application/pdf", fileName);
      var file = folder.createFile(blob);
      file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
      pdfUrl = file.getUrl();
    } catch (pdfErr) {
      Logger.log("Error saving PDF to Google Drive: " + pdfErr);
    }
  }

  var pdfCellFormula = "";
  if (pdfUrl && pdfUrl.length > 0) {
    pdfCellFormula = '=HYPERLINK("' + pdfUrl + '", "View report")';
  }

  // 3. تطبيع البيانات لتطابق نمط All-Data بدقة
  var rawContainerNo = (data.containerNo || "").toString().trim().toUpperCase();
  var bookingNo = (data.bookingNo || "").toString().trim().toUpperCase();
  var shippers = (data.shippers || "").toString().trim().toUpperCase();
  var sealNo = (data.sealNo || "").toString().trim().toUpperCase();
  
  // تطبيع النوع Type (DV -> D.V / HC -> H.C)
  var rawType = (data.type || "").toString().trim().toUpperCase();
  if (rawType === "DV") rawType = "D.V";
  if (rawType === "HC") rawType = "H.C";
  if (rawType === "OT") rawType = "O.T";
  if (rawType === "RF") rawType = "R.F";
  if (rawType === "FR") rawType = "F.R";

  // تطبيع المقاس Size (20 -> 20.0 أو 20)
  var rawSize = (data.size || "").toString().trim();
  if (rawSize === "20") rawSize = 20;
  else if (rawSize === "40") rawSize = 40;
  else if (rawSize === "45") rawSize = 45;

  var sealingPerson = (data.sealingPerson || data.inspector || "").toString().trim().toUpperCase();
  var notes = (data.report || "").toString().trim();

  // تنسيق التاريخ ليطابق تاريخ التسيل (yyyy-MM-dd)
  var sealingDate = data.createdAt;
  try {
    if (!sealingDate || sealingDate.toString().trim() === "") {
      sealingDate = new Date();
    } else {
      var parsed = new Date(sealingDate);
      if (!isNaN(parsed.getTime())) {
        sealingDate = parsed;
      }
    }
  } catch (_) {
    sealingDate = new Date();
  }

  // 4. البحث عن الحاوية في العمود E (العمود 5) بدءاً من الصف 6
  var maxScanRows = Math.min(sheet.getLastRow(), 15000);
  if (maxScanRows < 6) maxScanRows = 6;
  var numRowsToScan = maxScanRows - 5;
  
  var containerColumnValues = sheet.getRange(6, 5, numRowsToScan, 1).getValues();
  
  var existingRow = -1;
  var firstEmptyRow = -1;

  for (var i = 0; i < containerColumnValues.length; i++) {
    var val = (containerColumnValues[i][0] || "").toString().trim().toUpperCase();
    if (rawContainerNo.length > 0 && val === rawContainerNo) {
      existingRow = i + 6;
      break;
    }
    if (firstEmptyRow === -1 && val === "") {
      // التحقق من أن العمود C أيضاً فارغ
      var bookingVal = (sheet.getRange(i + 6, 3).getValue() || "").toString().trim();
      if (bookingVal === "") {
        firstEmptyRow = i + 6;
      }
    }
  }

  var targetRow;
  var isUpdate = false;

  if (existingRow !== -1) {
    targetRow = existingRow;
    isUpdate = true;
  } else if (firstEmptyRow !== -1) {
    targetRow = firstEmptyRow;
  } else {
    targetRow = maxScanRows + 1;
  }

  // 5. كتابة أو تحديث البيانات في الصف المحدد
  // Col A: معادلة المسلسل
  sheet.getRange(targetRow, 1).setFormula("=ROW()-5");

  // Col B: معادلة مفتاح الإقرار
  sheet.getRange(targetRow, 2).setFormula("=C" + targetRow + "&COUNTIF($C$6:C" + targetRow + ",C" + targetRow + ")");

  // Col C: Booking No
  if (bookingNo.length > 0) {
    sheet.getRange(targetRow, 3).setValue(bookingNo);
  }

  // Col D: Shippers
  if (shippers.length > 0) {
    sheet.getRange(targetRow, 4).setValue(shippers);
  }

  // Col E: Container No
  sheet.getRange(targetRow, 5).setValue(rawContainerNo);

  // Col F: Type
  if (rawType.length > 0) {
    sheet.getRange(targetRow, 6).setValue(rawType);
  }

  // Col G: Size
  if (rawSize !== "") {
    sheet.getRange(targetRow, 7).setValue(rawSize);
  }

  // Col H: Seal No
  if (sealNo.length > 0) {
    sheet.getRange(targetRow, 8).setValue(sealNo);
  }

  // Col I: Sealing Personal
  if (sealingPerson.length > 0) {
    sheet.getRange(targetRow, 9).setValue(sealingPerson);
  }

  // Col J: Sealing Date
  sheet.getRange(targetRow, 10).setValue(sealingDate);

  // Col K: Revision Details / Notes
  if (notes.length > 0) {
    sheet.getRange(targetRow, 11).setValue(notes);
  }

  // Col L: Reporting Details
  sheet.getRange(targetRow, 12).setValue("Reported");

  // Col M: رابط التقرير PDF (إذا توفر)
  if (pdfCellFormula.length > 0) {
    sheet.getRange(targetRow, 13).setFormula(pdfCellFormula);
  }

  // تنسيق الصف
  var rowRange = sheet.getRange(targetRow, 1, 1, 13);
  rowRange.setHorizontalAlignment("center")
          .setVerticalAlignment("middle")
          .setFontFamily("Arial")
          .setFontSize(10);

  return {
    rowNumber: targetRow,
    isUpdate: isUpdate,
    containerNo: rawContainerNo,
    bookingNo: bookingNo,
    pdfUrl: pdfUrl
  };
}
