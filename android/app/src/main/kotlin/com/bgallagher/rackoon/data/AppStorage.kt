package com.bgallagher.rackoon.data

import android.content.Context
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ssh.JsonFileKnownHosts
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import com.bgallagher.rackoon.demo.DemoHooks
import com.bgallagher.rackoon.ssh.ServerConnection
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.SshjTransport
import com.bgallagher.rackoon.terminal.TerminalManager
import java.io.File

/** `servers.json`: the saved servers, using the core `Server` model. Written atomically; a corrupt file reads as empty. */
class ServersFile(private val file: File) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }

    fun load(): List<Server> = try {
        if (file.exists()) json.decodeFromString<List<Server>>(file.readText()) else emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    fun save(servers: List<Server>) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(servers))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}

/** Small preferences. Read-only starts ON: a phone is easier to mis-tap than a Mac. */
class Prefs(context: Context, name: String = "rackoon") {
    private val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)

    var selectedServerId: String?
        get() = prefs.getString("selected_server", null)
        set(value) = prefs.edit().putString("selected_server", value).apply()

    var readOnly: Boolean
        get() = prefs.getBoolean("read_only", true)
        set(value) = prefs.edit().putBoolean("read_only", value).apply()

    /** Start every launch in Read-only, whatever it was when the app was last closed. */
    var startReadOnly: Boolean
        get() = prefs.getBoolean("start_read_only", true)
        set(value) = prefs.edit().putBoolean("start_read_only", value).apply()

    /** When Read-only turns itself back on (an [com.bgallagher.rackoon.core.AutoReadOnly] key). */
    var autoReadOnly: String
        get() = prefs.getString("auto_read_only", com.bgallagher.rackoon.core.AutoReadOnly.DEFAULT.key) ?: com.bgallagher.rackoon.core.AutoReadOnly.DEFAULT.key
        set(value) = prefs.edit().putString("auto_read_only", value).apply()

    /** Colour error words, IP addresses and high percentages in terminal output (core TerminalOutputFilter). */
    var highlightOutput: Boolean
        get() = prefs.getBoolean("highlight_output", true)
        set(value) = prefs.edit().putBoolean("highlight_output", value).apply()

    /** Terminal font size in sp. A phone is about 64 columns wide in portrait at 11 sp, so the default is smaller (9 sp gives about 88). */
    var terminalFontSize: Int
        get() = prefs.getInt("terminal_font_size", 9)
        set(value) = prefs.edit().putInt("terminal_font_size", value.coerceIn(7, 20)).apply()

    /** A theme id from themes.json, or `automatic` (Rackoon Dark/Light following the system). */
    var themeId: String
        get() = prefs.getString("theme_id", "automatic") ?: "automatic"
        set(value) = prefs.edit().putString("theme_id", value).apply()

    /** The opt-in vulnerability lookup (docs/security-plan.md, S3): on for every server. Off by default. */
    var osvLookupAll: Boolean
        get() = prefs.getBoolean("osv_lookup_all", false)
        set(value) = prefs.edit().putBoolean("osv_lookup_all", value).apply()

    /** Servers the vulnerability lookup is on for. */
    var osvLookupServers: Set<String>
        get() = prefs.getStringSet("osv_lookup_servers", emptySet())?.toSet() ?: emptySet()
        set(value) = prefs.edit().putStringSet("osv_lookup_servers", value).apply()

    var firstRunDone: Boolean
        get() = prefs.getBoolean("first_run_done", false)
        set(value) = prefs.edit().putBoolean("first_run_done", value).apply()
}

/**
 * Everything that lives for the whole process, built once by [com.bgallagher.rackoon.RackoonApp]. In demo mode ([demo] non-null,
 * debug builds only) it uses its own empty storage under the cache folder and fake connections, so a demo run never reads or
 * changes the real servers, keys or settings.
 */
class AppContainer(context: Context, private val demo: DemoHooks? = null) {
    private val appContext = context.applicationContext
    private val dir = if (demo != null) File(context.cacheDir, "demo").also { it.deleteRecursively() } else File(context.filesDir, "Rackoon")
    val isDemo: Boolean get() = demo != null
    val servers = ServersFile(File(dir, "servers.json")).also { f -> demo?.let { f.save(it.servers()) } }
    val knownHosts = JsonFileKnownHosts(File(dir, "known_hosts.json"))
    val prefs = Prefs(context, if (demo != null) "rackoon_demo" else "rackoon").also { p ->
        if (demo != null) { p.firstRunDone = true; p.selectedServerId = demo.servers().first().id }
    }
    val secrets = SecretStore(dir)
    val snapshots = SnapshotStore(dir)

    /** A connection to a server: the real one, or the demo's fake. */
    fun connection(endpoint: SshEndpoint): ServerConnection = demo?.connection(endpoint) ?: SshjTransport(endpoint, knownHosts)

    val terminals = TerminalManager(appContext, ::connection)
    val favicons = FaviconStore(File(dir, "favicons"))

    /** OSV.dev for the vulnerability lookup; demo mode answers from made-up advisories and sends nothing. */
    val osv: com.bgallagher.rackoon.core.OSVClient = demo?.osvClient() ?: HttpOSVClient()
    val osvCache = com.bgallagher.rackoon.core.OSVCache()
}
