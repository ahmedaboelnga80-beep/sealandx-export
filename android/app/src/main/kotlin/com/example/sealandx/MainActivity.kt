package com.example.sealandx

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "sealandx/msc_http"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "queryMsc") {
                val trackingNumber = call.argument<String>("trackingNumber") ?: ""
                val trackingMode = call.argument<String>("trackingMode") ?: "1"
                thread {
                    try {
                        val url = URL("https://www.msc.com/api/feature/tools/TrackingInfo")
                        val conn = url.openConnection() as HttpURLConnection
                        conn.requestMethod = "POST"
                        conn.connectTimeout = 20000
                        conn.readTimeout = 20000
                        conn.setRequestProperty("X-Requested-With", "XMLHttpRequest")
                        conn.setRequestProperty("Accept", "application/json")
                        conn.setRequestProperty("Content-Type", "application/json")
                        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
                        conn.doOutput = true

                        val payload = "{\"trackingNumber\":\"$trackingNumber\",\"trackingMode\":\"$trackingMode\"}"
                        val writer = OutputStreamWriter(conn.outputStream, Charsets.UTF_8)
                        writer.write(payload)
                        writer.flush()
                        writer.close()

                        val code = conn.responseCode
                        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                        val reader = BufferedReader(InputStreamReader(stream, Charsets.UTF_8))
                        val responseText = reader.readText()
                        reader.close()

                        runOnUiThread {
                            if (code in 200..299) {
                                result.success(responseText)
                            } else {
                                result.error("HTTP_$code", responseText, null)
                            }
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error("ERR", e.toString(), null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
