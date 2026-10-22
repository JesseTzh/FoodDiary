package com.jessetzh.fooddiary

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var updates: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private var downloading = false
    private var pendingInstall: File? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updates = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fooddiary/updates")
        updates.setMethodCallHandler { call, result ->
            when (call.method) {
                "installedVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                    result.success(mapOf("versionCode" to code))
                }
                "download" -> {
                    val url = call.argument<String>("url")
                    val sha = call.argument<String>("sha256")
                    val size = call.argument<Number>("size")?.toLong() ?: 0
                    val versionCode = call.argument<Number>("versionCode")?.toLong() ?: 0
                    if (downloading || url == null || sha == null || !sha.matches(Regex("[0-9a-f]{64}")) || size <= 0 || size > 512L * 1024 * 1024) {
                        result.error("UPDATE_INVALID", "下载参数无效或已有下载任务", null)
                    } else {
                        downloading = true
                        worker.execute {
                            try {
                                download(url, sha, size, versionCode)
                                runOnUiThread { downloading = false; result.success(null) }
                            } catch (e: Exception) {
                                runOnUiThread { downloading = false; result.error("UPDATE_DOWNLOAD", e.message ?: "下载失败，请重试", null) }
                            }
                        }
                    }
                }
                "install" -> {
                    val sha = call.argument<String>("sha256") ?: ""
                    if (!sha.matches(Regex("[0-9a-f]{64}"))) {
                        result.error("UPDATE_INVALID", "安装包无效", null)
                    } else {
                        val file = File(cacheDir, "updates/$sha.apk")
                        if (!file.isFile) {
                            result.error("UPDATE_MISSING", "安装包已清理，请重新下载", null)
                            return@setMethodCallHandler
                        }
                        try {
                            check(pendingResult == null) { "请先完成安装授权" }
                            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                pendingInstall = file
                                pendingResult = result
                                startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")), 7101)
                            } else {
                                openInstaller(file)
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            pendingInstall = null
                            pendingResult = null
                            result.error("UPDATE_INSTALL", e.message ?: "无法打开安装界面", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun download(address: String, sha: String, size: Long, versionCode: Long) {
        val url = URL(address)
        check(url.protocol == "https" || (BuildConfig.DEBUG && url.protocol == "http")) { "更新下载需要 HTTPS" }
        val dir = File(cacheDir, "updates").apply { mkdirs() }
        // Only our updater writes this directory, and only one task runs at once.
        dir.listFiles()?.forEach { it.delete() }
        val tmp = File(dir, "$sha.part")
        val target = File(dir, "$sha.apk")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 20_000
        // The server may first need to retrieve and verify the APK from GitHub.
        connection.readTimeout = 660_000
        connection.instanceFollowRedirects = false
        try {
            check(connection.responseCode == 200) { "下载失败（${connection.responseCode}），请重新检查更新" }
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            var lastProgress = 0L
            val deadline = System.nanoTime() + 20L * 60 * 1_000_000_000
            connection.inputStream.use { input ->
                tmp.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val length = input.read(buffer)
                        if (length == -1) break
                        count += length
                        check(count <= size && System.nanoTime() < deadline) { "安装包大小异常或下载超时" }
                        output.write(buffer, 0, length)
                        digest.update(buffer, 0, length)
                        val now = System.currentTimeMillis()
                        if (now - lastProgress >= 200) {
                            lastProgress = now
                            val received = count
                            runOnUiThread { updates.invokeMethod("downloadProgress", mapOf("received" to received, "total" to size)) }
                        }
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            check(count == size && actual == sha) { "安装包校验失败，请重新下载" }
            validatePackage(tmp, versionCode)
            check(tmp.renameTo(target)) { "无法保存安装包，请检查剩余空间" }
        } finally {
            connection.disconnect()
            tmp.delete()
        }
    }

    @Suppress("DEPRECATION")
    private fun validatePackage(file: File, versionCode: Long) {
        val archive = packageManager.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNATURES)
            ?: error("安装包无法识别")
        val installed = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        val nextCode = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        val currentCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        check(archive.packageName == packageName && nextCode == versionCode) { "安装包与应用或目标版本不匹配" }
        check(nextCode >= currentCode) { "服务端版本较旧，Android 无法覆盖安装" }
        val signatures = archive.signatures?.map { it.toCharsString() }?.toSet()
        check(!signatures.isNullOrEmpty() && signatures == installed.signatures?.map { it.toCharsString() }?.toSet()) {
            "更新包签名与当前应用不一致，无法覆盖安装"
        }
    }

    private fun openInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    @Deprecated("Android activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7101) return
        val result = pendingResult ?: return
        val file = pendingInstall
        pendingInstall = null
        pendingResult = null
        try {
            check(Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()) { "未允许安装更新包，可授权后重试" }
            check(file != null && file.isFile) { "安装包已清理，请重新下载" }
            openInstaller(file)
            result.success(null)
        } catch (e: Exception) {
            result.error("UPDATE_INSTALL", e.message, null)
        }
    }
}
