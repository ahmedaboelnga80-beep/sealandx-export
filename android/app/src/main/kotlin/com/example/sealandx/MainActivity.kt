package com.example.sealandx

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "sealandx/msc_http"
    private var hiddenWebView: WebView? = null
    private var pageReady = false
    private var pendingCallback: ((Boolean, String) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    inner class JsBridge {
        @JavascriptInterface
        fun onSuccess(responseText: String) {
            mainHandler.post {
                val cb = pendingCallback
                pendingCallback = null
                cb?.invoke(true, responseText)
            }
        }

        @JavascriptInterface
        fun onError(errorText: String) {
            mainHandler.post {
                val cb = pendingCallback
                pendingCallback = null
                cb?.invoke(false, errorText)
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun ensureWebView(onReady: () -> Unit) {
        if (hiddenWebView != null && pageReady) {
            onReady()
            return
        }
        val wv = WebView(this)
        wv.settings.javaScriptEnabled = true
        wv.settings.domStorageEnabled = true
        wv.settings.userAgentString =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
        wv.addJavascriptInterface(JsBridge(), "AndroidMscBridge")
        wv.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                if (!pageReady) {
                    pageReady = true
                    onReady()
                }
            }
        }
        hiddenWebView = wv
        wv.loadDataWithBaseURL(
            "https://www.msc.com/en/track-a-shipment",
            "<!DOCTYPE html><html><head><meta charset='utf-8'></head><body></body></html>",
            "text/html",
            "UTF-8",
            null
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "queryMsc") {
                val trackingNumber = call.argument<String>("trackingNumber") ?: ""
                val trackingMode = call.argument<String>("trackingMode") ?: "1"
                var replied = false

                val timeoutRunnable = Runnable {
                    if (!replied) {
                        replied = true
                        pendingCallback = null
                        result.error("TIMEOUT", "WebView MSC request timed out", null)
                    }
                }
                mainHandler.postDelayed(timeoutRunnable, 22000)

                pendingCallback = { ok, text ->
                    mainHandler.removeCallbacks(timeoutRunnable)
                    if (!replied) {
                        replied = true
                        if (ok) {
                            result.success(text)
                        } else {
                            result.error("MSC_ERR", text, null)
                        }
                    }
                }

                ensureWebView {
                    val safeTrack = JSONObject.quote(trackingNumber)
                    val safeMode = JSONObject.quote(trackingMode)
                    val js = """
                        (function() {
                            fetch("https://www.msc.com/api/feature/tools/TrackingInfo", {
                                method: "POST",
                                headers: {
                                    "X-Requested-With": "XMLHttpRequest",
                                    "Accept": "application/json",
                                    "Content-Type": "application/json"
                                },
                                body: JSON.stringify({
                                    trackingNumber: $safeTrack,
                                    trackingMode: $safeMode
                                })
                            })
                            .then(function(r) {
                                if (!r.ok) throw new Error("HTTP_" + r.status);
                                return r.text();
                            })
                            .then(function(txt) {
                                AndroidMscBridge.onSuccess(txt);
                            })
                            .catch(function(err) {
                                AndroidMscBridge.onError(err.toString());
                            });
                        })();
                    """.trimIndent()
                    hiddenWebView?.evaluateJavascript(js, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
