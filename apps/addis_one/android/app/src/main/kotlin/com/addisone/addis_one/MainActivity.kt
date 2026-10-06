package com.addisone.addis_one

import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The merged app's single activity.
 *
 * The manifest declares `.MainActivity`, and the package here must match the
 * `namespace` in build.gradle.kts exactly — Android resolves the manifest's
 * leading-dot name against the namespace, so a mismatch compiles and installs
 * cleanly and then dies on first launch with
 *
 *     ClassNotFoundException: Didn't find class "com.addisone.addis_one.MainActivity"
 *
 * That is a launch-time crash with no build-time warning, which is why this file
 * has to exist even though nothing references it from Kotlin.
 *
 * One activity for both roles, not two. The role fork happens inside Dart, at
 * the router, and the merged app is one process with one entry point; two
 * activities would mean two entry points and a choice of which one the launcher
 * fires — a second place for the role to be decided, which is exactly the
 * ambiguity this merge exists to remove.
 *
 * Outbound social sharing for the ticket flows.
 *
 * This channel was carried over from the standalone passenger app during the
 * merge. Its Dart side (`MethodChannelTicketShareService`) addresses it by
 * name unconditionally — a missing registration here does not fail the build
 * or the launch, it fails every share call at runtime with
 * MissingPluginException. That is how a merge can drop sharing without
 * touching a line of Dart, and why the channel name lives in exactly one
 * place on each side.
 *
 * Sharing opens a target app with content pre-filled rather than sending
 * autonomously: a ticket forwarded to a group chat is something the passenger
 * must be able to see and edit before it leaves their phone.
 *
 * It never reports delivery. The value returned to Dart is true only once the
 * platform accepted the request — the UI must never claim a message arrived.
 */
class MainActivity : FlutterActivity() {

    private val shareChannelName = "addis_one_passenger/share"

    /** WhatsApp's package. Targeted directly so the tap lands on the chat list. */
    private val whatsappPackage = "com.whatsapp"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerShareChannel(flutterEngine)
    }

    // ── Share ────────────────────────────────────────────────────────────────

    private fun registerShareChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> {
                        val target = call.argument<String>("target")
                        result.success(
                            if (target == "whatsapp") isWhatsappInstalled() else true
                        )
                    }
                    "share" -> {
                        val text = call.argument<String>("text")
                        val target = call.argument<String>("target")

                        if (text.isNullOrBlank()) {
                            result.error(
                                "invalid_args",
                                "'text' is required.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        result.success(shareText(text, target))
                    }
                    "shareQr" -> {
                        val pngBytes = call.argument<ByteArray>("pngBytes")
                        val fileName = call.argument<String>("fileName")
                        val text = call.argument<String>("text")
                        val target = call.argument<String>("target")

                        if (pngBytes == null || pngBytes.isEmpty() ||
                            fileName.isNullOrBlank() ||
                            text.isNullOrBlank()
                        ) {
                            result.error(
                                "invalid_args",
                                "'pngBytes', 'fileName' and 'text' are required.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        result.success(shareQr(pngBytes!!, fileName, text, target))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isWhatsappInstalled(): Boolean {
        return try {
            packageManager.getPackageInfo(whatsappPackage, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Opens a share target with [text] pre-filled.
     *
     * WhatsApp is addressed by package so the tap goes straight to it, but it
     * is NOT made a hard requirement: if WhatsApp is missing or refuses the
     * explicit intent, this falls back to the system share sheet. Losing the
     * ability to forward a ticket because one app is not installed would be a
     * worse outcome than sharing through a different app.
     */
    private fun shareText(text: String, target: String?): Boolean {
        if (target == "whatsapp" && isWhatsappInstalled()) {
            val whatsapp = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                setPackage(whatsappPackage)
                putExtra(Intent.EXTRA_TEXT, text)
            }
            if (tryStart(whatsapp)) return true
            // Fall through to the chooser rather than reporting failure.
        }

        val chooser = Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            },
            "Share ticket"
        )
        return tryStart(chooser)
    }

    private fun tryStart(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            // No app can handle the intent, or it was blocked. Reported as
            // "not sent"/"not shared" rather than crashing a passenger who is
            // standing at a vehicle.
            false
        }
    }

    /**
     * Writes the QR PNG to the app's private share cache and shares it as an
     * attachment with [text] as the caption.
     *
     * The file lives in `cacheDir/share-qr/` — the one directory the
     * FileProvider exposes — under the Dart-provided name, and is readable by
     * the receiving app only for this share via FLAG_GRANT_READ_URI_PERMISSION.
     * Stale files are pruned first: a QR is a bearer token for one boarding,
     * and keeping yesterday's images on disk past their usefulness is how a
     * forwarded or re-sent cache file boards someone on an expired fare.
     */
    private fun shareQr(
        pngBytes: ByteArray,
        fileName: String,
        text: String,
        target: String?
    ): Boolean {
        val dir = File(cacheDir, "share-qr")
        if (!dir.isDirectory && !dir.mkdirs()) return false
        dir.listFiles()?.forEach { old ->
            // Sweep before writing, not after: a share that crashes after
            // pruning but before writing never leaves a hole the old file
            // could fill, because the new file is written unconditionally
            // below regardless of what the sweep removed.
            if (old.isFile) old.delete()
        }

        val safeName = fileName.substringAfterLast('/').substringAfterLast('\\')
        val file = File(dir, safeName.ifBlank { "ticket.png" })
        try {
            file.writeBytes(pngBytes)
        } catch (e: Exception) {
            return false
        }

        val uri = try {
            FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
        } catch (e: Exception) {
            file.delete()
            return false
        }

        fun sendWithImage(type: String, pack: String?): Intent {
            return Intent(Intent.ACTION_SEND).apply {
                this.type = type
                if (!pack.isNullOrBlank()) setPackage(pack)
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TEXT, text)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }

        // Text-only shares keep type "text/plain" so the channel's existing
        // `share` path is untouched. An image share is a different intent from
        // the text path's point of view: EXTRA_STREAM with type "image/png"
        // plus EXTRA_TEXT rides as the caption.
        if (target == "whatsapp" && isWhatsappInstalled()) {
            if (tryStart(sendWithImage("image/png", whatsappPackage))) return true
            // Fall through to the chooser rather than reporting failure.
        }

        val chooser = Intent.createChooser(
            sendWithImage("image/png", null),
            "Share ticket"
        )
        return tryStart(chooser)
    }
}