package com.bgallagher.rackoon

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bgallagher.rackoon.data.AuthKind
import com.bgallagher.rackoon.data.StoredAuth
import com.bgallagher.rackoon.core.ActionPolicy
import com.bgallagher.rackoon.core.AptAction
import com.bgallagher.rackoon.core.AutoReadOnly
import com.bgallagher.rackoon.core.RebootError
import com.bgallagher.rackoon.core.RebootOutcome
import com.bgallagher.rackoon.core.RebootSession
import com.bgallagher.rackoon.core.AptPrompt
import com.bgallagher.rackoon.core.UpdatesPresentation
import com.bgallagher.rackoon.core.UpdatesSession
import com.bgallagher.rackoon.core.UpdatesState
import com.bgallagher.rackoon.core.OSV
import com.bgallagher.rackoon.core.PackageInventory
import com.bgallagher.rackoon.core.PendingPackage
import com.bgallagher.rackoon.core.SecurityContext
import com.bgallagher.rackoon.core.SecurityFinding
import com.bgallagher.rackoon.core.SecurityRules
import com.bgallagher.rackoon.core.SecuritySession
import com.bgallagher.rackoon.core.SecuritySnapshot
import com.bgallagher.rackoon.core.VulnerabilityFinding
import com.bgallagher.rackoon.core.VulnerabilityLookup
import com.bgallagher.rackoon.core.Bookmark
import com.bgallagher.rackoon.core.BookmarkEditor
import com.bgallagher.rackoon.core.BookmarkPlan
import com.bgallagher.rackoon.core.ComposeAction
import com.bgallagher.rackoon.core.DockerSession
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.FileEdit
import com.bgallagher.rackoon.core.SaveOutcome
import com.bgallagher.rackoon.core.StackFileSession
import com.bgallagher.rackoon.core.StackFiles
import com.bgallagher.rackoon.core.StandaloneAction
import com.bgallagher.rackoon.core.bookmarkableStacks
import com.bgallagher.rackoon.core.serviceNames
import com.bgallagher.rackoon.ui.PendingAction
import com.bgallagher.rackoon.core.AddContainerDraft
import com.bgallagher.rackoon.core.AddState
import com.bgallagher.rackoon.core.DeployRequest
import com.bgallagher.rackoon.core.NewStackDefaults
import com.bgallagher.rackoon.core.DockerAction
import com.bgallagher.rackoon.core.EditableFile
import com.bgallagher.rackoon.core.EditorState
import com.bgallagher.rackoon.core.StackEditor
import com.bgallagher.rackoon.core.LogFollower
import com.bgallagher.rackoon.core.LogsState
import com.bgallagher.rackoon.core.DockerState
import com.bgallagher.rackoon.core.DockerSnapshot
import com.bgallagher.rackoon.core.ActionPrompts
import com.bgallagher.rackoon.core.DockerContainer
import com.bgallagher.rackoon.core.PolicyError
import com.bgallagher.rackoon.core.TerminalTheme
import com.bgallagher.rackoon.output.ActionOutput
import com.bgallagher.rackoon.core.ConnectionFailure
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.ServerInput
import com.bgallagher.rackoon.core.ServerSession
import com.bgallagher.rackoon.core.ServerState
import com.bgallagher.rackoon.ssh.HostKeyInfo
import com.bgallagher.rackoon.ssh.SshAuth
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.SshException
import com.bgallagher.rackoon.ssh.SshKeys
import com.bgallagher.rackoon.ssh.TrustedHostKey
import com.bgallagher.rackoon.ssh.scanHostKey
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/** Why a server cannot be shown, in terms the screen can explain. */
sealed class Issue {
    class Unreachable(val detail: String) : Issue()
    class AuthFailed(val detail: String) : Issue()
    class KeyChanged(val host: String, val trusted: TrustedHostKey, val presented: HostKeyInfo) : Issue()
    class KeyUnknown(val host: String, val port: Int, val presented: HostKeyInfo) : Issue()
    class Other(val detail: String) : Issue()
}

sealed class OverviewUi {
    object Connecting : OverviewUi()
    class Ready(val state: ServerState) : OverviewUi()
    class Failed(val issue: Issue) : OverviewUi()
}

/** What the Docker screen shows: the first load, the stacks, no Docker, or a failure (with whether the server could not be reached at all). */
sealed class DockerUi {
    object Loading : DockerUi()
    class Ready(
        val snapshot: DockerSnapshot, val updatedAt: Long?, val error: String?,
        /** Containers and compose projects with an action in flight, and why the last action failed (if it did). */
        val busy: Set<String> = emptySet(), val busyStacks: Set<String> = emptySet(), val actionError: String? = null,
        /** Stacks docker doesn't list right now but that should stay on screen: one being deleted, or left "Not started" after a failed delete. */
        val extraStacks: List<DockerStack> = emptyList(),
    ) : DockerUi() {
        /** Every stack to show: the ones docker reports, then the extras it doesn't (so a stack never vanishes while it is being deleted). */
        val stacks: List<DockerStack> by lazy {
            val ids = snapshot.stacks.map { it.id }.toSet()
            snapshot.stacks + extraStacks.filter { it.id !in ids }.sortedBy { it.name }
        }

        companion object {
            fun from(s: DockerState, snapshot: DockerSnapshot, extra: List<DockerStack> = emptyList()) =
                Ready(snapshot, s.updatedAt, s.error, s.busy, s.busyStacks, s.actionError, extra)
        }
    }
    object NotInstalled : DockerUi()
    class Failed(val message: String, val unreachable: Boolean) : DockerUi()
}

enum class Tab { Overview, Docker, Terminal, More }

/** The sign-in choice in the Add server and Server settings forms. Secrets live here only while the form is open. */
data class AuthFields(
    val kind: AuthKind = AuthKind.Tailscale,
    val password: String = "",
    val keyPem: String? = null,
    val keyName: String? = null,
    val passphrase: String = "",
) {
    fun toStored() = StoredAuth(kind, password.takeIf { kind == AuthKind.Password }, keyPem.takeIf { kind == AuthKind.Key }, passphrase.takeIf { kind == AuthKind.Key && it.isNotEmpty() }, keyName.takeIf { kind == AuthKind.Key })

    /** What is missing or wrong, in words, or null when this can be tried. A key is read now so a bad file or passphrase is caught before connecting. */
    fun problem(): String? = when (kind) {
        AuthKind.Tailscale -> null
        AuthKind.Password -> if (password.isEmpty()) "Enter the password." else null
        AuthKind.Key -> if (keyPem == null) "Choose your private key file." else try { SshKeys.load(keyPem, passphrase.takeIf { it.isNotEmpty() }); null } catch (e: SshException.AuthFailed) { e.detail }
    }
}

/** Server settings: rename, change the address and how Rackoon signs in, forget the trusted host key, remove. */
data class SettingsForm(
    val server: Server,
    val name: String,
    /** The address as typed: host, user and port are text until they are saved. A blank user means root, a blank port 22. */
    val host: String = server.host,
    val user: String = server.user.orEmpty(),
    val port: String = server.port?.toString().orEmpty(),
    /** Set while the user is deciding whether to trust the key a changed address presented for the first time. */
    val trust: HostKeyInfo? = null,
    val auth: AuthFields,
    val currentKind: AuthKind,
    val currentKeyName: String?,
    val authChanged: Boolean = false,
    val hostKey: TrustedHostKey?,
    val busy: Boolean = false,
    val error: String? = null,
)

/** The add/edit bookmark sheet: which stack and service, the fields, and what it is doing. */
data class BookmarkForm(
    val stackLocked: Boolean = false,
    /** The chosen stack's [DockerStack.id] (for a compose stack, its project name). */
    val stackName: String? = null,
    val service: String = "",
    val existing: Bookmark? = null,
    val url: String = "",
    val name: String = "",
    val group: String = "",
    val icon: String = "",
    val details: String = "",
    /** What it is doing right now ("Saving…"), or null when idle. */
    val busy: String? = null,
    val notice: String? = null,
) {
    val normalizedUrl: String get() = Bookmark.normalizedAddress(url)
    val urlProblem: String? get() = if (url.isBlank() || Bookmark.isValidUrl(normalizedUrl)) null else "Enter a web address such as https://app.example.com"

    fun bookmark(): Bookmark? =
        if (Bookmark.isValidUrl(normalizedUrl)) Bookmark(href = normalizedUrl, name = name, group = group, icon = icon, description = details) else null

    /** Why Save is off, or null when it can go ahead. */
    fun saveBlockedReason(readOnly: Boolean, stack: DockerStack?): String? = when {
        readOnly -> "Read-only mode is on"
        busy != null -> "Working…"
        stack == null -> "Choose a stack"
        service.isEmpty() -> "This stack has no containers to bookmark"
        url.isBlank() -> "Enter a web address"
        bookmark() == null -> urlProblem
        else -> null
    }

    /** Picks a stack and a service in it (the one asked for, else the first that already has a bookmark, else the first). */
    fun choosingStack(stack: DockerStack, wanted: String?): BookmarkForm {
        val names = stack.serviceNames
        val service = wanted?.takeIf { it in names } ?: names.firstOrNull { n -> stack.containers.firstOrNull { it.service == n }?.bookmark != null } ?: names.firstOrNull() ?: ""
        return copy(stackName = stack.id).choosingService(stack, service)
    }

    fun choosingService(stack: DockerStack, service: String): BookmarkForm {
        val b = stack.containers.firstOrNull { it.service == service }?.bookmark
        return copy(
            service = service, existing = b, notice = null,
            url = b?.href.orEmpty(), name = b?.name.orEmpty(), group = b?.group.orEmpty(), icon = b?.icon.orEmpty(), details = b?.description.orEmpty(),
        )
    }
}

/** The "Add server" form and where it is in its flow. */
data class AddForm(
    val name: String = "",
    val target: String = "",
    val auth: AuthFields = AuthFields(),
    val busy: Boolean = false,
    val error: String? = null,
    /** Set while the user is deciding whether to trust a first-seen host key. */
    val trust: HostKeyInfo? = null,
    /** Set when the server presented a different key than the one trusted: the connection is blocked. */
    val blocked: Issue.KeyChanged? = null,
)

/** A reboot started from the app, as the banner shows it. */
sealed class RebootUi {
    object Requesting : RebootUi()
    data class Waiting(val sinceMillis: Long) : RebootUi()
    data class Back(val afterMillis: Long) : RebootUi()
    object TimedOut : RebootUi()
    data class Failed(val message: String) : RebootUi()

    val isActive: Boolean get() = this is Requesting || this is Waiting
}

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val c = (application as RackoonApp).container

    /** Site icons of bookmarked services (see [com.bgallagher.rackoon.data.FaviconStore]). */
    val favicons get() = c.favicons

    private val _servers = MutableStateFlow(c.servers.load())
    val servers: StateFlow<List<Server>> = _servers.asStateFlow()

    private val _selectedId = MutableStateFlow(c.prefs.selectedServerId?.takeIf { id -> _servers.value.any { it.id == id } } ?: _servers.value.firstOrNull()?.id)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()

    private fun current(): Server? = _servers.value.firstOrNull { it.id == _selectedId.value }

    /** The server on screen, kept in step with the list and the selection. */
    val selectedServer: StateFlow<Server?> = combine(_servers, _selectedId) { list, id -> list.firstOrNull { it.id == id } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, current())

    /** The one gate every state-changing command goes through. Read-only is kept in step with the chip. */
    // Every launch starts in Read-only unless the user turned that off in Safety settings.
    private val initialReadOnly = if (c.prefs.startReadOnly) true else c.prefs.readOnly
    val policy = ActionPolicy(readOnly = initialReadOnly)

    private val _readOnly = MutableStateFlow(initialReadOnly)
    val readOnly: StateFlow<Boolean> = _readOnly.asStateFlow()

    private val _firstRun = MutableStateFlow(!c.prefs.firstRunDone)
    val firstRun: StateFlow<Boolean> = _firstRun.asStateFlow()

    private val _tab = MutableStateFlow(Tab.Overview)
    val tab: StateFlow<Tab> = _tab.asStateFlow()

    private val _overview = MutableStateFlow<OverviewUi>(OverviewUi.Connecting)
    val overview: StateFlow<OverviewUi> = _overview.asStateFlow()

    private val _switcher = MutableStateFlow(false)
    val switcher: StateFlow<Boolean> = _switcher.asStateFlow()

    private val _add = MutableStateFlow<AddForm?>(null)
    val add: StateFlow<AddForm?> = _add.asStateFlow()

    /** Statuses for the switcher: the selected server's live state, others unknown. */
    private var live: Live? = null
    private var pollJob: Job? = null
    private var dockerJob: Job? = null

    private inner class Live(val server: Server) {
        val transport = c.connection(endpointOf(server))
        val docker = DockerSession(transport, policy = policy)
        val logs = LogFollower(transport)
        val updates = UpdatesSession(transport, policy = policy)
        val reboot = RebootSession(transport, policy)
        val session = ServerSession(transport, cached = c.snapshots.load(server.id), onSnapshot = { c.snapshots.save(server.id, it) })
    }

    private fun endpointOf(server: Server) = SshEndpoint(
        server.host, server.port ?: 22, server.user?.takeIf { it.isNotEmpty() } ?: "root",
        c.secrets.load(server.id)?.toSshAuth() ?: SshAuth.TailscaleNone,
    )


    // MARK: terminals (sessions live in TerminalManager, not here, so they outlast screens)

    val terminals = c.terminals
    private val _highlight = MutableStateFlow(c.prefs.highlightOutput)
    val highlightOutput: StateFlow<Boolean> = _highlight.asStateFlow()

    fun openTerminal(server: Server, theme: com.bgallagher.rackoon.core.TerminalTheme) {
        c.terminals.open(server.id, server.name, endpointOf(server), theme, _highlight.value)
    }

    // MARK: appearance

    private val _themeId = MutableStateFlow(c.prefs.themeId)
    val themeId: StateFlow<String> = _themeId.asStateFlow()
    fun setTheme(id: String) { _themeId.value = id; c.prefs.themeId = id }

    private val _appearance = MutableStateFlow(false)
    val appearance: StateFlow<Boolean> = _appearance.asStateFlow()
    fun showAppearance(show: Boolean) { _appearance.value = show }

    private val _fontSize = MutableStateFlow(c.prefs.terminalFontSize)
    val terminalFontSize: StateFlow<Int> = _fontSize.asStateFlow()

    fun changeFontSize(delta: Int) {
        c.prefs.terminalFontSize = (_fontSize.value + delta).coerceIn(7, 20)
        _fontSize.value = c.prefs.terminalFontSize
    }

    fun setHighlight(on: Boolean) {
        _highlight.value = on; c.prefs.highlightOutput = on; c.terminals.setHighlight(on)
    }

    // MARK: first run, read-only, tabs

    fun dismissFirstRun() { c.prefs.firstRunDone = true; _firstRun.value = false }
    private fun setReadOnly(on: Boolean) { _readOnly.value = on; c.prefs.readOnly = on; policy.isReadOnly = on }

    /** The Read-only chip and every "Turn off" button. Turning it ON is immediate; turning it OFF asks once. */
    fun toggleReadOnly() {
        if (!_readOnly.value) { setReadOnly(true); return }
        val server = current()
        _pending.value = PendingAction(
            "Allow changes on ${server?.name ?: "this server"}?",
            "Rackoon will be able to change the server: run actions, edit files and open a shell. Every change still shows the exact command and asks first.",
            user = "", command = "", confirmLabel = "Allow changes", cancelLabel = "Keep read-only",
            run = { setReadOnly(false) },
        )
    }

    // MARK: Safety settings and Read-only turning itself back on

    private val _startReadOnly = MutableStateFlow(c.prefs.startReadOnly)
    val startReadOnly: StateFlow<Boolean> = _startReadOnly.asStateFlow()
    fun setStartReadOnly(on: Boolean) { _startReadOnly.value = on; c.prefs.startReadOnly = on }

    private val _autoReadOnly = MutableStateFlow(AutoReadOnly.fromKey(c.prefs.autoReadOnly))
    val autoReadOnly: StateFlow<AutoReadOnly> = _autoReadOnly.asStateFlow()
    fun setAutoReadOnly(mode: AutoReadOnly) { _autoReadOnly.value = mode; c.prefs.autoReadOnly = mode.key }

    /** One-off messages for the snackbar ("Read-only turned back on"). */
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages: SharedFlow<String> = _messages.asSharedFlow()

    @Volatile private var lastTouchMillis = System.currentTimeMillis()
    /** Called for every touch in the app, so "idle" means no one has touched it. */
    fun noteTouch() { lastTouchMillis = System.currentTimeMillis() }

    /** An action is running: Read-only must not flip under it. */
    private fun actionRunning() = _working.value != null || _updatesWorking.value != null || _reboot.value?.isActive == true || _bookmarkBusy.value != null

    private fun reenableReadOnly() {
        if (_readOnly.value) return
        setReadOnly(true)
        _pending.value = null
        _messages.tryEmit("Read-only turned back on")
    }

    private fun watchIdle() {
        viewModelScope.launch {
            while (true) {
                delay(5_000)
                if (AutoReadOnly.shouldReenable(_autoReadOnly.value, _readOnly.value, lastTouchMillis, System.currentTimeMillis(), actionRunning())) reenableReadOnly()
            }
        }
    }

    /** The app left the screen. */
    fun onBackgrounded() {
        if (AutoReadOnly.shouldReenableOnBackground(_autoReadOnly.value, _readOnly.value, actionRunning())) reenableReadOnly()
    }

    // MARK: More pages (Terminal settings, Safety, About)

    enum class MorePage { Terminal, Safety, About }
    private val _morePage = MutableStateFlow<MorePage?>(null)
    val morePage: StateFlow<MorePage?> = _morePage.asStateFlow()
    fun showMorePage(page: MorePage?) { _morePage.value = page }

    /** Edit a server from the switcher: select it, then open its settings. */
    fun editServer(server: Server) { select(server); openSettings() }
    fun showTab(tab: Tab) { _tab.value = tab }
    fun showSwitcher(show: Boolean) { _switcher.value = show }

    // MARK: servers

    fun select(server: Server) {
        _switcher.value = false
        if (server.id == _selectedId.value && live != null) return
        _selectedId.value = server.id
        c.prefs.selectedServerId = server.id
        openLive(server)
    }

    fun remove(server: Server) {
        if (server.id in _lookup.value.servers) setVulnerabilityLookup(server.id, false)
        c.terminals.closeAll(server.id)
        c.secrets.remove(server.id)
        c.snapshots.remove(server.id)
        c.knownHosts.forget(server.host, server.port ?: 22)
        _servers.update { list -> list.filterNot { it.id == server.id } }
        c.servers.save(_servers.value)
        if (_selectedId.value == server.id) {
            live?.logs?.stop(); live?.transport?.close(); live = null; pollJob?.cancel(); clearBookmarkState()
            _selectedId.value = _servers.value.firstOrNull()?.id
            c.prefs.selectedServerId = _selectedId.value
            _servers.value.firstOrNull()?.let(::openLive)
        }
    }

    private fun openLive(server: Server) {
        pollJob?.cancel()
        live?.transport?.close()
        live?.logs?.stop()
        live = Live(server)
        clearBookmarkState()
        logsJob?.cancel()
        _logs.value = LogsState()
        val followed = live!!.logs
        logsJob = viewModelScope.launch { followed.state.collect { _logs.value = it } }
        clearDockerActions()
        clearUpdatesState()
        _security.value = SecurityUi(); _securityOpen.value = false
        rebootJob?.cancel(); _reboot.value = null
        val updatesSession = live!!.updates
        updatesJob?.cancel()
        updatesJob = viewModelScope.launch { updatesSession.state.collect { _updates.value = it } }
        // The Docker session's own state (stacks, busy markers, action errors) is what the screens show; the polling loop and the
        // actions only change that state, and this publishes it.
        dockerJob?.cancel()
        val docker = live!!.docker
        dockerJob = viewModelScope.launch { docker.state.collect { st -> lastDockerState = st; publishDocker() } }
        _docker.value = DockerUi.Loading
        _openStack.value = null
        // A saved reading shows at once (marked stale) while the first poll runs.
        _overview.value = live!!.session.state.value.takeIf { it.overview != null }?.let { OverviewUi.Ready(it) } ?: OverviewUi.Connecting
    }

    // MARK: Docker (polled every 10 s, only while the Docker tab is on screen: `docker stats` is slow)

    private val _docker = MutableStateFlow<DockerUi>(DockerUi.Loading)
    val docker: StateFlow<DockerUi> = _docker.asStateFlow()

    /** The [DockerStack.id] of the stack whose page is open (a compose project's name, or `standalone/<container>`), or null for the list. */
    private val _openStack = MutableStateFlow<String?>(null)
    val openStack: StateFlow<String?> = _openStack.asStateFlow()
    fun openStack(id: String?) {
        _openStack.value = id
        // A run that belongs to this stack is still on screen: reopen the page on its Output.
        _stackTab.value = if (id != null && _output.value?.scope == id) StackTab.Output else StackTab.Containers
    }

    suspend fun pollDockerWhileVisible() {
        val l = live ?: return
        while (true) {
            refreshDockerOnce(l)
            delay(10_000)
        }
    }

    fun refreshDockerNow() {
        val l = live ?: return
        viewModelScope.launch { refreshDockerOnce(l) }
    }

    private suspend fun refreshDockerOnce(l: Live) {
        val previous = _docker.value
        try {
            l.transport.connect()
            l.docker.refresh()
            val s = l.docker.state.value
            _docker.value = when {
                s.snapshot != null -> DockerUi.Ready.from(s, s.snapshot!!, extraStacks())
                s.error?.contains("not installed", ignoreCase = true) == true -> DockerUi.NotInstalled
                s.error != null -> DockerUi.Failed(s.error!!, unreachable = false)
                else -> DockerUi.Loading
            }
        } catch (e: SshException) {
            // Keep the last stacks on screen when the link drops; with nothing to show, explain.
            _docker.value = if (previous is DockerUi.Ready) DockerUi.Ready(previous.snapshot, previous.updatedAt, e.message, previous.busy, previous.busyStacks, previous.actionError, extraStacks())
            else DockerUi.Failed(e.message ?: "Connection failed", unreachable = e is SshException.Unreachable)
        }
    }

    // MARK: compose.yaml and .env editor (drafts live here, so rotating the phone or leaving the screen never loses typing)

    private var editor: StackEditor? = null
    private var editorJob: Job? = null
    private val _editorState = MutableStateFlow(EditorState())
    val editorState: StateFlow<EditorState> = _editorState.asStateFlow()

    /** The file on screen in the editor, or null when the editor is closed. */
    private val _editorFile = MutableStateFlow<EditableFile?>(null)
    val editorFile: StateFlow<EditableFile?> = _editorFile.asStateFlow()
    private var editorStack: DockerStack? = null

    /** Set when the user leaves with unsaved changes: the screen asks before throwing them away. */
    private val _confirmDiscard = MutableStateFlow(false)
    val confirmDiscard: StateFlow<Boolean> = _confirmDiscard.asStateFlow()

    fun editorStackName(): String? = editorStack?.name

    fun openEditor(stack: DockerStack, file: EditableFile) {
        val l = live ?: return
        if (editor == null || editorStack?.id != stack.id) {
            editor?.close(); editorJob?.cancel()
            val ed = StackEditor(StackFileSession(l.transport, stack, policy), stack, l.server.name, viewModelScope, { _readOnly.value })
            editor = ed; editorStack = stack
            editorJob = viewModelScope.launch { ed.state.collect { _editorState.value = it } }
        }
        editor?.open(file)
        _editorFile.value = file
    }

    fun showEditorFile(file: EditableFile) { editor?.open(file); _editorFile.value = file }
    fun editorFiles(): List<EditableFile> = editor?.files ?: emptyList()
    fun editorText(file: EditableFile, text: String) { editor?.setText(file, text) }
    fun editorRevert(file: EditableFile) { editor?.revert(file) }
    fun editorReload(file: EditableFile) { editor?.reload(file) }
    fun editorDismissNotice() { editor?.dismissNotice() }
    fun editorRows(file: EditableFile) = editor?.rows(file, _editorState.value) ?: emptyList()
    fun editorCanSave(file: EditableFile) = editor?.canSave(file, _editorState.value) == true
    fun editorCanRedeploy(file: EditableFile) = editor?.canRedeploy(file, _editorState.value) == true
    fun editorBlockedReason(file: EditableFile) = editor?.saveBlockedReason(file, _editorState.value)

    /** Back from the editor: asks first when there are unsaved changes. */
    fun closeEditor() {
        if (editor?.hasUnsavedChanges == true) _confirmDiscard.value = true else closeEditorNow()
    }

    fun keepEditing() { _confirmDiscard.value = false }

    fun closeEditorNow() {
        _confirmDiscard.value = false
        editor?.close(); editorJob?.cancel(); editor = null; editorStack = null
        _editorState.value = EditorState(); _editorFile.value = null
    }

    /** Save asks first, showing the diff (the command carries the file encoded, so it isn't readable) and the redeploy command. */
    fun requestEditorSave(redeploy: Boolean) {
        val l = live ?: return
        val ed = editor ?: return
        val file = _editorFile.value ?: return
        val stack = editorStack ?: return
        if (redeploy && !ed.canRedeploy(file)) return
        val edit = ed.editFor(file) ?: return
        val intent = ed.intent(edit) ?: return
        val name = file.fileName
        _pending.value = PendingAction(
            title = if (redeploy) "Save $name and update ${stack.name}?" else "Save $name?",
            message = "The server checks it first, and nothing is written if that fails. The previous version is kept as $name.rackoon.bak." +
                if (redeploy) " Then the stack is updated: containers whose image or settings changed are recreated." else "",
            user = l.endpointUser(), command = if (redeploy) com.bgallagher.rackoon.core.ComposeAction.UP.command(stack).orEmpty() else "", preview = intent.preview,
            run = {
                if (live === l) ed.save(edit, redeploy) {
                    if (redeploy && live === l) {
                        // Leave the editor on the stack page's Output, where the update streams.
                        val target = stack
                        closeEditorNow()
                        runStackAction(l, target, com.bgallagher.rackoon.core.ComposeAction.UP, null)
                    }
                }
            },
        )
    }

    // MARK: add container (a new stack, or a service added to an existing one; the rules live in core's AddContainerDraft)

    private var addDraft: AddContainerDraft? = null
    private var addJob: Job? = null
    private val _addOpen = MutableStateFlow(false)
    val addOpen: StateFlow<Boolean> = _addOpen.asStateFlow()
    private val _addState = MutableStateFlow(AddState())
    val addState: StateFlow<AddState> = _addState.asStateFlow()
    private val _addConfirmLeave = MutableStateFlow(false)
    val addConfirmLeave: StateFlow<Boolean> = _addConfirmLeave.asStateFlow()

    fun draft(): AddContainerDraft? = addDraft

    fun openAddContainer() {
        val l = live ?: return
        if (_readOnly.value) return
        val ready = _docker.value as? DockerUi.Ready ?: return
        val user = l.server.user?.takeIf { it.isNotEmpty() } ?: "root"
        val folder = NewStackDefaults.parentDirectory(ready.stacks, user)
        val d = AddContainerDraft(
            l.transport, policy, l.server.name, viewModelScope, folder,
            stacks = { (_docker.value as? DockerUi.Ready)?.stacks.orEmpty() },
            containers = { (_docker.value as? DockerUi.Ready)?.snapshot?.containers.orEmpty() },
            stackBlockedReason = { stackBlockedReason(it) },
        )
        addDraft = d
        addJob?.cancel()
        addJob = viewModelScope.launch { d.state.collect { _addState.value = it } }
        _addState.value = d.state.value
        _addOpen.value = true
        d.start()
    }

    /** Back from the page: asks first when something was typed. */
    fun closeAddContainer() {
        if (addDraft?.isDirty == true) _addConfirmLeave.value = true else closeAddNow()
    }

    fun keepAdding() { _addConfirmLeave.value = false }

    fun closeAddNow() {
        _addConfirmLeave.value = false
        addDraft?.close(); addJob?.cancel(); addDraft = null; _addOpen.value = false; _addState.value = AddState()
    }

    /** Create / Save asks first (the files, or the diff, and the start command), then writes; "start" then runs `up -d` into Output. */
    fun requestAddDeploy(start: Boolean) {
        val l = live ?: return
        val d = addDraft ?: return
        val request = d.request(start) ?: return
        _pending.value = PendingAction(
            title = request.title, message = request.message, user = l.endpointUser(),
            command = if (start) com.bgallagher.rackoon.core.ComposeAction.UP.command(request.stack).orEmpty() else "", preview = request.preview,
            run = { if (live === l) d.perform(request) { done -> onAddDone(l, done.stack, done.isNew, done.start) } },
        )
    }

    private fun onAddDone(l: Live, stack: DockerStack, isNew: Boolean, start: Boolean) {
        if (live !== l) return
        // A new stack with no containers is invisible to `docker ps`, so it is remembered here until its containers show up.
        if (isNew) { leftoverStacks[stack.id] = stack; publishDocker() }
        closeAddNow()
        _openStack.value = stack.id
        _stackTab.value = StackTab.Containers
        if (start) runStackAction(l, stack, com.bgallagher.rackoon.core.ComposeAction.UP, null) else refreshDockerNow()
    }

    // MARK: delete stack (docker compose down, optionally volumes and the folder; the folder rules live in core's StackRemoval)

    private var lastDockerState: DockerState? = null
    /** By [DockerStack.id], like everything else that remembers a stack (a container may be called like a compose project). */
    private val removingStacks = LinkedHashMap<String, DockerStack>()
    private val leftoverStacks = LinkedHashMap<String, DockerStack>()

    private fun extraStacks(): List<DockerStack> = (leftoverStacks + removingStacks).values.toList()

    private fun publishDocker() {
        val st = lastDockerState ?: return
        val snap = st.snapshot ?: return
        _docker.value = DockerUi.Ready.from(st, snap, extraStacks())
    }

    /** The stack the user is deciding to delete (a sheet), or null. */
    private val _deleting = MutableStateFlow<DockerStack?>(null)
    val deleting: StateFlow<DockerStack?> = _deleting.asStateFlow()
    fun requestDelete(stack: DockerStack) {
        val blocked = if (stack.isStandalone) standaloneBlockedReason(stack) else stackBlockedReason(stack)
        if (blocked == null) _deleting.value = stack
    }
    fun cancelDelete() { _deleting.value = null }

    /** Deletes a stack after the sheet's confirmation, streaming into the stack's Output tab. On success the stack page closes. */
    fun deleteStack(stack: DockerStack, removal: com.bgallagher.rackoon.core.StackRemoval) {
        val l = live ?: return
        _deleting.value = null
        if (_working.value != null || _readOnly.value) return
        removingStacks[stack.id] = stack
        publishDocker()
        launchOutput(
            stack.id, "docker compose down", "Deleting ${stack.name}…", null,
            onDone = { out ->
                removingStacks.remove(stack.id)
                if (out.phase.value == ActionOutput.Phase.Succeeded) {
                    leftoverStacks.remove(stack.id)
                    publishDocker()
                    if (live === l && _openStack.value == stack.id) { _openStack.value = null; _stackTab.value = StackTab.Containers; _output.value = null }
                } else {
                    // Failed or cancelled part way (the containers may be gone but the folder is not): keep the stack on screen, as
                    // "Not started" if docker no longer reports it, so its Output can be read and its files are not orphaned.
                    leftoverStacks[stack.id] = stack.copy(containers = emptyList())
                    publishDocker()
                }
            },
        ) { cols, rows, onEvent ->
            val confirmation = try { l.docker.confirm(removal, stack) } catch (_: PolicyError) { null }
            l.docker.performStreaming(removal, stack, confirmation, cols, rows, onEvent)
        }
    }

    // MARK: standalone containers (started with docker run: one container is the whole stack; Pull and Delete are its own)

    /** Why a standalone container's actions (pull, restart, delete) are unavailable (null when they can run). */
    fun standaloneBlockedReason(stack: DockerStack): String? = ActionPrompts.standaloneBlockedReason(stack, _readOnly.value, _working.value != null)

    /** Pulls a standalone container's image after asking with the exact command. Delete goes through [requestDelete]'s sheet. */
    fun requestPull(stack: DockerStack) {
        val l = live ?: return
        if (standaloneBlockedReason(stack) != null) return
        val intent = StandaloneAction.PullImage.intent(stack) ?: return
        val prompt = ActionPrompts.pull(stack) ?: return
        _pending.value = PendingAction(
            prompt.title, prompt.message, l.endpointUser(), intent.command, destructive = prompt.destructive,
            run = { runStandaloneAction(l, stack, StandaloneAction.PullImage, prompt.working) },
        )
    }

    /**
     * Deletes a standalone container after the sheet's confirmation (typed name, optional anonymous volumes), streaming into
     * its Output tab. On success the page closes; on failure the container is normally still there and stays on screen.
     */
    fun deleteContainer(stack: DockerStack, volumes: Boolean) {
        val l = live ?: return
        _deleting.value = null
        if (_working.value != null || _readOnly.value) return
        removingStacks[stack.id] = stack
        publishDocker()
        runStandaloneAction(l, stack, StandaloneAction.Remove(volumes), "Deleting ${stack.name}…") { out ->
            removingStacks.remove(stack.id)
            publishDocker()
            if (out.phase.value == ActionOutput.Phase.Succeeded && live === l && _openStack.value == stack.id) {
                _openStack.value = null; _stackTab.value = StackTab.Containers; _output.value = null
            }
        }
    }

    private fun runStandaloneAction(l: Live, stack: DockerStack, action: StandaloneAction, working: String, onDone: (ActionOutput) -> Unit = {}) {
        if (live !== l || _working.value != null) return
        val title = when (action) {
            StandaloneAction.PullImage -> "docker pull ${StandaloneAction.pullableImage(stack) ?: stack.name}"
            is StandaloneAction.Remove -> "docker rm ${stack.name}"
        }
        launchOutput(stack.id, title, working, null, onDone) { cols, rows, onEvent ->
            val confirmation = try { l.docker.confirm(action, stack) } catch (_: PolicyError) { null }
            l.docker.performStreaming(action, stack, confirmation, cols, rows, onEvent)
        }
    }

    // MARK: container and stack actions (every one is confirmed, bound to the server it was made for, and streams into Output)

    enum class StackTab { Containers, Logs, Output }

    private val _stackTab = MutableStateFlow(StackTab.Containers)
    val stackTab: StateFlow<StackTab> = _stackTab.asStateFlow()
    fun showStackTab(tab: StackTab) { _stackTab.value = tab }

    /** The latest streamed action, kept until it is closed; the stack page shows it when it belongs to the open stack. */
    private val _logs = MutableStateFlow(LogsState())
    /** The followed logs of the open stack (empty unless the Logs tab is showing). */
    val logs: StateFlow<LogsState> = _logs.asStateFlow()
    private var logsJob: Job? = null

    /** Follows these containers' logs, merged. Called while the Logs tab is on screen. */
    fun followLogs(containers: List<DockerContainer>) { live?.logs?.follow(viewModelScope, containers) }

    /** Stops following (Ctrl-C reaches each remote `docker logs -f`). */
    fun stopLogs() { live?.logs?.stop() }

    private val _output = MutableStateFlow<ActionOutput?>(null)
    val output: StateFlow<ActionOutput?> = _output.asStateFlow()

    /** What is running right now ("Restarting grafana…"), or null. Only one action runs at a time. */
    private val _working = MutableStateFlow<String?>(null)
    val working: StateFlow<String?> = _working.asStateFlow()

    private fun clearDockerActions() { closeAddNow(); removingStacks.clear(); leftoverStacks.clear(); lastDockerState = null; _deleting.value = null; closeEditorNow(); _working.value = null; _output.value?.cancel(); _output.value = null; _stackTab.value = StackTab.Containers }

    /** Why a stack's actions are unavailable (null when they can run). */
    fun stackBlockedReason(stack: DockerStack): String? = ActionPrompts.blockedReason(stack, _readOnly.value, _working.value != null)

    fun requestContainerAction(stack: DockerStack?, container: DockerContainer, action: DockerAction) {
        val l = live ?: return
        if (_readOnly.value || _working.value != null) return
        val intent = action.intent(container.id) ?: return
        val prompt = ActionPrompts.container(action, container)
        if (prompt == null) { runContainerAction(l, container, action); return }   // start runs straight away
        _pending.value = PendingAction(
            prompt.title, prompt.message, l.endpointUser(), intent.command, destructive = prompt.destructive,
            run = { runContainerAction(l, container, action) },
        )
    }

    fun requestStackAction(stack: DockerStack, action: com.bgallagher.rackoon.core.ComposeAction) {
        val l = live ?: return
        if (stackBlockedReason(stack) != null) return
        val intent = action.intent(stack) ?: return
        val prompt = ActionPrompts.stack(action, stack)
        _pending.value = PendingAction(
            prompt.title, prompt.message, l.endpointUser(), intent.command, destructive = prompt.destructive,
            run = { runStackAction(l, stack, action, null) },
        )
    }

    fun requestRebuild(stack: DockerStack, container: DockerContainer) {
        val l = live ?: return
        val service = container.service ?: return
        if (stackBlockedReason(stack) != null) return
        val intent = com.bgallagher.rackoon.core.ComposeAction.REBUILD.intent(stack, service) ?: return
        val prompt = ActionPrompts.rebuild(service, stack)
        _pending.value = PendingAction(
            prompt.title, prompt.message, l.endpointUser(), intent.command,
            run = { runStackAction(l, stack, com.bgallagher.rackoon.core.ComposeAction.REBUILD, service) },
        )
    }

    private fun runStackAction(l: Live, stack: DockerStack, action: com.bgallagher.rackoon.core.ComposeAction, service: String?) {
        if (live !== l || _working.value != null) return
        val prompt = if (service != null) ActionPrompts.rebuild(service, stack) else ActionPrompts.stack(action, stack)
        launchOutput(stack.id, "docker compose ${action.raw}" + (service?.let { " $it" } ?: ""), prompt.working, null) { cols, rows, onEvent ->
            val confirmation = try { l.docker.confirm(action, stack, service) } catch (_: PolicyError) { null }
            l.docker.performStreaming(action, stack, service, confirmation, cols, rows, onEvent)
        }
    }

    private fun runContainerAction(l: Live, container: DockerContainer, action: DockerAction) {
        if (live !== l || _working.value != null) return
        val verb = action.raw
        launchOutput(
            DockerStack.idOf(container), "docker $verb ${container.name}", ActionPrompts.container(action, container)?.working ?: "Starting ${container.name}…",
            "\u001B[2m$ docker $verb ${container.name}\u001B[0m\r\n",
        ) { cols, rows, onEvent ->
            val confirmation = try { l.docker.confirm(action, container.id) } catch (_: PolicyError) { null }
            l.docker.performStreaming(action, container.id, confirmation, cols, rows, onEvent)
        }
    }

    private fun launchOutput(
        scope: String, title: String, working: String, intro: String?,
        onDone: (ActionOutput) -> Unit = {},
        work: suspend (cols: Int, rows: Int, onEvent: (com.bgallagher.rackoon.core.ActionStreamEvent) -> Unit) -> Unit,
    ) {
        _working.value = working
        val out = ActionOutput(scope, title, viewModelScope)
        _output.value = out
        _stackTab.value = StackTab.Output   // the Output tab opens when a run starts (its view reports the size the run needs)
        out.start(intro, work, completion = { _working.value = null; onDone(out) })
    }

    fun cancelOutput() { _output.value?.cancel() }

    fun closeOutput() {
        val o = _output.value ?: return
        if (o.isRunning) return
        _output.value = null
        _stackTab.value = StackTab.Containers
    }

    /** Shell into a container: a terminal tab running `docker exec -it`, like the Mac's Shell button. */
    fun openContainerShell(container: DockerContainer, theme: TerminalTheme) {
        val server = current() ?: return
        if (_readOnly.value) return   // a shell can change anything: gated like the Terminal tab
        val command = DockerSession.shellCommand(container.id) ?: return
        c.terminals.open(server.id, server.name, endpointOf(server), theme, _highlight.value, command, container.name)
        showTab(Tab.Terminal)
    }

    // MARK: Overview polling (the screen runs this only while it is visible)

    /** Polls the selected server until cancelled. A refused host key stops it (nothing is retried against a changed key). */
    suspend fun pollWhileVisible() {
        val l = live ?: return
        while (true) {
            val keepGoing = refreshOnce(l)
            if (!keepGoing) return
            delay(5_000)
        }
    }

    fun refreshNow() {
        val l = live ?: return
        viewModelScope.launch { refreshOnce(l) }
    }

    private suspend fun refreshOnce(l: Live): Boolean {
        try {
            l.transport.connect()
            l.session.refresh()
            val s = l.session.state.value
            _overview.value = when {
                s.overview == null && s.error != null -> OverviewUi.Failed(Issue.Other(s.error!!))
                s.overview != null -> OverviewUi.Ready(s)
                else -> OverviewUi.Connecting
            }
            return true
        } catch (e: SshException) {
            val last = l.session.state.value
            val hostKeyProblem = e is SshException.HostKeyChanged || e is SshException.HostKeyUnknown
            // Keep showing the last reading (marked) when the link drops; a host-key problem always takes over the screen.
            _overview.value = if (last.overview != null && !hostKeyProblem) OverviewUi.Ready(last.copy(error = e.message))
            else OverviewUi.Failed(issueOf(l.server.host, l.server.port ?: 22, e))
            return !hostKeyProblem
        }
    }

    private fun issueOf(host: String, port: Int, e: SshException): Issue = when (e) {
        is SshException.HostKeyChanged -> Issue.KeyChanged(host, e.trusted, e.presented)
        is SshException.HostKeyUnknown -> Issue.KeyUnknown(host, port, e.presented)
        is SshException.AuthFailed -> Issue.AuthFailed(e.detail)
        is SshException.Unreachable -> Issue.Unreachable(e.detail)
        else -> Issue.Other(e.message ?: "Connection failed")
    }

    /** The user trusted a key that an already-saved server presented for the first time (for example after "Forget"). */
    fun trustPresented(issue: Issue.KeyUnknown) {
        c.knownHosts.trust(issue.host, issue.port, issue.presented)
        refreshNow()
    }

    // MARK: add server

    fun startAdd() { _switcher.value = false; _add.value = AddForm() }
    fun cancelAdd() { _add.value = null }
    fun editAdd(change: (AddForm) -> AddForm) { _add.update { it?.let(change) } }

    fun submitAdd() {
        val form = _add.value ?: return
        if (c.isDemo) { editAdd { it.copy(error = "Demo mode: servers can't be added. Restart the app normally to use your own.") }; return }
        val endpoint = SshEndpoint.parse(form.target, auth = form.auth.toStored().toSshAuth())
        if (endpoint == null) { editAdd { it.copy(error = "Enter the user and host, like ubuntu@100.64.12.7") }; return }
        form.auth.problem()?.let { problem -> editAdd { it.copy(error = problem) }; return }
        editAdd { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                if (c.knownHosts.lookup(endpoint.host, endpoint.port) == null) {
                    val key = scanHostKey(endpoint.host, endpoint.port)
                    editAdd { it.copy(busy = false, trust = key) }
                } else {
                    connectAndSave(endpoint)
                }
            } catch (e: SshException) {
                editAdd { it.copy(busy = false, error = e.message) }
            }
        }
    }

    fun trustAndConnect() {
        val form = _add.value ?: return
        val key = form.trust ?: return
        val endpoint = SshEndpoint.parse(form.target, auth = form.auth.toStored().toSshAuth()) ?: return
        c.knownHosts.trust(endpoint.host, endpoint.port, key)
        editAdd { it.copy(trust = null, busy = true) }
        viewModelScope.launch { connectAndSave(endpoint) }
    }

    fun declineTrust() { editAdd { it.copy(trust = null) } }

    private suspend fun connectAndSave(endpoint: SshEndpoint) {
        val form = _add.value ?: return
        val transport = c.connection(endpoint)
        try {
            transport.connect()
            val server = Server(
                id = UUID.randomUUID().toString(), name = form.name.trim().ifEmpty { endpoint.host }, host = endpoint.host,
                user = endpoint.user, port = endpoint.port.takeIf { it != 22 },
            )
            c.secrets.save(server.id, form.auth.toStored())   // before select(): connecting reads it
            _servers.update { it + server }
            c.servers.save(_servers.value)
            _add.value = null
            select(server)
        } catch (e: SshException.HostKeyChanged) {
            editAdd { it.copy(busy = false, blocked = Issue.KeyChanged(endpoint.host, e.trusted, e.presented)) }
        } catch (e: SshException) {
            editAdd { it.copy(busy = false, error = e.message) }
        } finally {
            transport.close()
        }
    }

    // MARK: Reboot (asks the server, then waits until it answers with a different boot id)

    private val _reboot = MutableStateFlow<RebootUi?>(null)
    val reboot: StateFlow<RebootUi?> = _reboot.asStateFlow()
    private var rebootJob: Job? = null

    fun requestReboot() {
        val l = live ?: return
        if (_readOnly.value || _reboot.value?.isActive == true) return
        _pending.value = PendingAction(
            "Reboot ${l.server.name}?",
            "The server restarts in a couple of seconds. Everything running on it stops and comes back with it. Rackoon waits and reconnects when it is up again.",
            l.endpointUser(), RebootSession.rebootCommand, destructive = true, confirmLabel = "Reboot",
            run = { startReboot(l) },
        )
    }

    private fun startReboot(l: Live) {
        if (live !== l || _reboot.value?.isActive == true) return
        _reboot.value = RebootUi.Requesting
        rebootJob = viewModelScope.launch {
            try {
                // The same policy that vetted the request vets it again here; a switch to Read-only in between wins.
                l.reboot.reboot(l.reboot.confirm())
                _reboot.value = RebootUi.Waiting(System.currentTimeMillis())
                when (val outcome = l.reboot.waitForReturn()) {
                    is RebootOutcome.Back -> { _reboot.value = RebootUi.Back(outcome.elapsedMillis); refreshNow(); loadUpdates() }
                    RebootOutcome.TimedOut -> _reboot.value = RebootUi.TimedOut
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: RebootError) {
                _reboot.value = RebootUi.Failed(e.message ?: "The reboot failed.")
            } catch (e: PolicyError) {
                _reboot.value = RebootUi.Failed(e.message ?: "The reboot was refused.")
            } catch (e: Exception) {
                _reboot.value = RebootUi.Failed(e.message ?: e.toString())
            }
        }
    }

    fun dismissReboot() { if (_reboot.value?.isActive != true) _reboot.value = null }

    // MARK: Updates (read when the screen opens and after each action; no polling)

    private val _updatesOpen = MutableStateFlow(false)
    val updatesOpen: StateFlow<Boolean> = _updatesOpen.asStateFlow()
    private val _updates = MutableStateFlow(UpdatesState())
    val updates: StateFlow<UpdatesState> = _updates.asStateFlow()
    private val _updatesLoading = MutableStateFlow(false)
    val updatesLoading: StateFlow<Boolean> = _updatesLoading.asStateFlow()
    /** What an apt action is doing right now ("Installing 5 updates…"), or null. */
    private val _updatesWorking = MutableStateFlow<String?>(null)
    val updatesWorking: StateFlow<String?> = _updatesWorking.asStateFlow()
    /** The latest apt run and what it printed, kept until closed or replaced. */
    private val _updatesOutput = MutableStateFlow<ActionOutput?>(null)
    val updatesOutput: StateFlow<ActionOutput?> = _updatesOutput.asStateFlow()
    private var updatesJob: Job? = null

    fun showUpdates(show: Boolean) {
        _updatesOpen.value = show
        if (show) loadUpdates()
    }

    fun loadUpdates() {
        val l = live ?: return
        if (_updatesLoading.value || _updatesWorking.value != null) return
        _updatesLoading.value = true
        viewModelScope.launch {
            try { l.updates.refresh() } finally { if (live === l) _updatesLoading.value = false }
        }
    }

    /** Why an apt button is off, or null: Read-only, or another action is running. */
    fun aptBlockedReason(): String? = when {
        _readOnly.value -> "Read-only mode is on"
        _updatesWorking.value != null -> "Another update is running"
        else -> null
    }

    fun requestApt(action: AptAction) {
        val l = live ?: return
        if (aptBlockedReason() != null) return
        val intent = action.intent ?: return
        val packages = _updates.value.snapshot?.packages.orEmpty()
        val prompt = UpdatesPresentation.prompt(action, packages.size, packages.count { it.isSecurity })
        _pending.value = PendingAction(prompt.title, prompt.message, l.endpointUser(), intent.command, run = { runApt(l, action, prompt) })
    }

    /** "Install security updates": an explicit, capped list of the security packages, else null. */
    fun securityAction(): AptAction? {
        val packages = _updates.value.snapshot?.packages.orEmpty()
        return if (UpdatesPresentation.canInstallSecurity(packages)) AptAction.Upgrade(UpdatesPresentation.securityNames(packages)) else null
    }

    private fun runApt(l: Live, action: AptAction, prompt: AptPrompt) {
        if (live !== l || _updatesWorking.value != null) return
        _updatesWorking.value = prompt.workingLabel
        val out = ActionOutput("updates", prompt.outputTitle, viewModelScope)
        _updatesOutput.value = out
        out.start(null, { cols, rows, onEvent ->
            // The same policy that vetted the request vets it again here; a switch to Read-only in between wins.
            val confirmation = try { l.updates.confirm(action) } catch (_: PolicyError) { null }
            l.updates.performStreaming(action, confirmation, cols, rows, onEvent)
        }, completion = { if (live === l) _updatesWorking.value = null })
    }

    fun cancelUpdatesOutput() { _updatesOutput.value?.cancel() }

    fun closeUpdatesOutput() {
        val o = _updatesOutput.value ?: return
        if (!o.isRunning) _updatesOutput.value = null
    }

    // MARK: Security (docs/security-plan.md): read when the screen opens (if the last reading is over 5 minutes old) and on
    // Check Now; the opt-in vulnerability lookup sends package names and versions to OSV.dev only when the user turned it on.

    data class SecurityUi(
        val snapshot: SecuritySnapshot? = null,
        val checkedAt: Long? = null,
        val error: String? = null,
        val loading: Boolean = false,
        val vulnerabilities: List<VulnerabilityFinding>? = null,
        val vulnerabilitiesAt: Long? = null,
        val vulnerabilityError: String? = null,
        val lookingUp: Boolean = false,
        val lookupSupported: Boolean = true,
    )

    data class LookupSetting(val all: Boolean, val servers: Set<String>) {
        fun isOn(id: String) = all || id in servers
    }

    private val _securityOpen = MutableStateFlow(false)
    val securityOpen: StateFlow<Boolean> = _securityOpen.asStateFlow()
    private val _security = MutableStateFlow(SecurityUi())
    val security: StateFlow<SecurityUi> = _security.asStateFlow()
    private val _lookup = MutableStateFlow(LookupSetting(c.prefs.osvLookupAll, c.prefs.osvLookupServers))
    val vulnerabilityLookup: StateFlow<LookupSetting> = _lookup.asStateFlow()

    fun showSecurity(show: Boolean) {
        _securityOpen.value = show
        if (show) {
            loadSecurity()
            val id = _selectedId.value
            if (id != null && _lookup.value.isOn(id) && _security.value.vulnerabilities == null) lookUpVulnerabilities()
        }
    }

    fun loadSecurity(force: Boolean = false) {
        val l = live ?: return
        val s = _security.value
        if (s.loading) return
        if (!force && s.checkedAt != null && System.currentTimeMillis() - s.checkedAt < 5 * 60_000) return
        _security.value = s.copy(loading = true)
        viewModelScope.launch {
            val next = try {
                _security.value.copy(snapshot = SecuritySession.read(l.transport), checkedAt = System.currentTimeMillis(), error = null)
            } catch (e: Exception) {
                _security.value.copy(error = e.message ?: e.toString())
            }
            if (live === l) _security.value = next.copy(loading = false)
        }
    }

    /** The findings for the last reading, with what the Overview poll knows (security updates, reboot flag). */
    fun securityFindings(): List<SecurityFinding> {
        val snapshot = _security.value.snapshot ?: return emptyList()
        val o = (_overview.value as? OverviewUi.Ready)?.state?.overview
        return SecurityRules.evaluate(snapshot, SecurityContext(o?.securityUpdates, o?.rebootRequired))
    }

    fun lookUpVulnerabilities() {
        val l = live ?: return
        if (_security.value.lookingUp) return
        _security.value = _security.value.copy(lookingUp = true)
        viewModelScope.launch {
            var next = _security.value
            try {
                val inventory = PackageInventory.read(l.transport)
                next = if (OSV.ecosystem(inventory.os.id, inventory.os.version) == null) {
                    next.copy(lookupSupported = false, vulnerabilities = null, vulnerabilityError = null)
                } else {
                    val pending = l.updates.refresh().snapshot?.packages.orEmpty().map { PendingPackage(it.name, it.newVersion) }
                    val found = VulnerabilityLookup.run(inventory, pending, c.osv, c.osvCache)
                    next.copy(lookupSupported = true, vulnerabilities = found, vulnerabilitiesAt = System.currentTimeMillis(), vulnerabilityError = null)
                }
            } catch (e: Exception) {
                next = next.copy(vulnerabilityError = e.message ?: e.toString())
            }
            if (live === l) _security.value = next.copy(lookingUp = false)
        }
    }

    /** Turns the lookup on or off for one server (`serverId`) or for every server (null). */
    fun setVulnerabilityLookup(serverId: String?, on: Boolean) {
        val cur = _lookup.value
        val next = if (serverId == null) cur.copy(all = on) else cur.copy(servers = if (on) cur.servers + serverId else cur.servers - serverId)
        _lookup.value = next
        c.prefs.osvLookupAll = next.all
        c.prefs.osvLookupServers = next.servers
        val id = _selectedId.value ?: return
        if (next.isOn(id)) { if (on) lookUpVulnerabilities() }
        else _security.value = _security.value.copy(vulnerabilities = null, vulnerabilitiesAt = null, vulnerabilityError = null)
    }

    private fun clearUpdatesState() {
        _updatesOpen.value = false; _updates.value = UpdatesState(); _updatesLoading.value = false; _updatesWorking.value = null
        _updatesOutput.value?.cancel(); _updatesOutput.value = null
    }

    // MARK: bookmarks (Homepage labels written into the stack's compose file)

    private val _pending = MutableStateFlow<PendingAction?>(null)
    val pending: StateFlow<PendingAction?> = _pending.asStateFlow()
    fun cancelPending() { _pending.value = null }
    fun confirmPending() { val a = _pending.value ?: return; _pending.value = null; a.run() }

    private val _bookmarks = MutableStateFlow(false)
    /** The Bookmarks screen is open. */
    val bookmarksOpen: StateFlow<Boolean> = _bookmarks.asStateFlow()
    fun showBookmarks(show: Boolean) { _bookmarks.value = show }

    private val _bookmarkForm = MutableStateFlow<BookmarkForm?>(null)
    val bookmarkForm: StateFlow<BookmarkForm?> = _bookmarkForm.asStateFlow()

    /** A message for the Bookmarks list (a removal that couldn't go ahead, or why Add did nothing), and a removal in progress. */
    private val _bookmarkMessage = MutableStateFlow<String?>(null)
    val bookmarkMessage: StateFlow<String?> = _bookmarkMessage.asStateFlow()
    fun dismissBookmarkMessage() { _bookmarkMessage.value = null }
    private val _bookmarkBusy = MutableStateFlow<String?>(null)
    val bookmarkBusy: StateFlow<String?> = _bookmarkBusy.asStateFlow()

    /** Everything a bookmark change started on the old server is dropped when the server changes: its confirmation would run on the wrong one. */
    private fun clearBookmarkState() {
        _pending.value = null; _bookmarkForm.value = null; _bookmarks.value = false; _bookmarkMessage.value = null; _bookmarkBusy.value = null
    }

    private fun snapshot(): DockerSnapshot? = (_docker.value as? DockerUi.Ready)?.snapshot
    fun bookmarkChoices(): List<DockerStack> = snapshot()?.bookmarkableStacks ?: emptyList()

    /** Opens the add/edit sheet. With a stack (a card, or Edit) the stack is fixed; without one the user picks. */
    fun openBookmarkSheet(stackName: String? = null, service: String? = null) {
        val snap = snapshot()
        if (snap == null) { _bookmarkMessage.value = "Docker hasn't been read yet. Try again in a moment."; return }
        val stack = stackName?.let { n -> snap.stacks.firstOrNull { it.id == n } }
        if (stackName == null) {
            if (_readOnly.value) { _bookmarkMessage.value = "Read-only mode is on. Turn it off to add a bookmark."; return }
            if (snap.bookmarkableStacks.isEmpty()) {
                _bookmarkMessage.value = "No stack on this server can take a bookmark: it needs a compose file Rackoon can edit."
                return
            }
        }
        _bookmarkMessage.value = null
        _bookmarkForm.value = BookmarkForm(stackLocked = stack != null).let { if (stack != null) it.choosingStack(stack, service) else it }
    }

    fun closeBookmarkSheet() { _bookmarkForm.value = null; _pending.value = null }
    fun editBookmark(change: (BookmarkForm) -> BookmarkForm) { _bookmarkForm.update { it?.let(change)?.copy(notice = null) } }

    fun chooseBookmarkStack(name: String) {
        val stack = snapshot()?.stacks?.firstOrNull { it.id == name } ?: return
        _bookmarkForm.update { it?.choosingStack(stack, null) }
    }

    fun chooseBookmarkService(service: String) {
        val stack = snapshot()?.stacks?.firstOrNull { it.id == _bookmarkForm.value?.stackName } ?: return
        _bookmarkForm.update { it?.choosingService(stack, service) }
    }

    /** Where a bookmark change reports to: the open sheet, or the list (for Remove, which has no sheet). */
    private class Reporter(val busy: (String?) -> Unit, val notice: (String) -> Unit, val finished: () -> Unit)

    /** A reporter for the sheet, which ignores everything once the server it started on is no longer the current one. */
    private fun formReporter(l: Live) = Reporter(
        busy = { b -> if (live === l) _bookmarkForm.update { it?.copy(busy = b) } },
        notice = { n -> if (live === l) _bookmarkForm.update { it?.copy(busy = null, notice = n) } },
        finished = { if (live === l) _bookmarkForm.value = null },
    )

    private fun listReporter(l: Live) = Reporter(
        busy = { b -> if (live === l) _bookmarkBusy.value = b },
        notice = { n -> if (live === l) { _bookmarkBusy.value = null; _bookmarkMessage.value = n } },
        finished = { if (live === l) _bookmarkBusy.value = null },
    )

    fun requestBookmarkSave(apply: Boolean) {
        val form = _bookmarkForm.value ?: return
        val l = live ?: return
        val stack = snapshot()?.stacks?.firstOrNull { it.id == form.stackName } ?: return
        val bookmark = form.bookmark() ?: return
        if (form.saveBlockedReason(_readOnly.value, stack) != null) return
        prepareBookmarkEdit(l, stack, form.service, bookmark.labelChanges, apply, removing = false, formReporter(l))
    }

    /** Remove from the sheet (Edit bookmark > Remove bookmark). */
    fun requestBookmarkRemoval() {
        val form = _bookmarkForm.value ?: return
        val l = live ?: return
        val stack = snapshot()?.stacks?.firstOrNull { it.id == form.stackName } ?: return
        if (form.busy != null) return
        prepareBookmarkEdit(l, stack, form.service, Bookmark.removalChanges, apply = true, removing = true, formReporter(l))
    }

    /** Remove from the list: no edit sheet, just the confirmation (or a message saying why it can't be done). */
    fun requestBookmarkRemovalFor(stackName: String, service: String) {
        val l = live ?: return
        val stack = snapshot()?.stacks?.firstOrNull { it.id == stackName } ?: return
        if (_bookmarkBusy.value != null) return
        _bookmarkMessage.value = null
        prepareBookmarkEdit(l, stack, service, Bookmark.removalChanges, apply = true, removing = true, listReporter(l))
    }

    /** Reads the compose file that defines the service, edits its labels, and asks the user to confirm the diff. */
    private fun prepareBookmarkEdit(
        l: Live, stack: DockerStack, service: String, changes: List<com.bgallagher.rackoon.core.LabelChange>, apply: Boolean, removing: Boolean, report: Reporter,
    ) {
        if (_readOnly.value) { report.notice("Read-only mode is on. Turn it off to change bookmarks."); return }
        if (service.isEmpty() || StackFiles.editable(stack) == null) return
        report.busy("Reading the compose file…")
        viewModelScope.launch {
            try {
                val session = StackFileSession(l.transport, stack, policy)
                when (val plan = BookmarkEditor.plan(session, stack, service, changes, removing, l.server.name)) {
                    is BookmarkPlan.Notice -> report.notice(plan.text)
                    is BookmarkPlan.Ready -> {
                        val edit = plan.edit
                        val intent = session.intent(edit)
                        if (intent == null) { report.notice("That change can't be saved."); return@launch }
                        if (live !== l) return@launch
                        val up = if (apply) ComposeAction.UP.command(stack).orEmpty() else ""
                        val what = if (removing) "Remove the bookmark from $service" else "Bookmark $service"
                        val file = edit.file.fileName
                        report.busy(null)
                        _pending.value = PendingAction(
                            title = if (apply) "$what and update ${stack.name}?" else "$what?",
                            message = "The labels are written into $file; the server checks the file first, and the old one is kept as $file.rackoon.bak." +
                                if (apply) " Then the stack is updated, which recreates $service (a few seconds of downtime) so the change shows up."
                                else " It takes effect the next time the stack is updated.",
                            user = l.endpointUser(), command = up, preview = intent.preview,
                            // The server, session and reporter are the ones this was prepared with, not whatever is current when Run is tapped.
                            run = { performBookmarkSave(l, session, edit, stack, apply, report) },
                        )
                    }
                }
            } catch (e: Exception) {
                report.notice(bookmarkError(e))
            }
        }
    }

    private fun performBookmarkSave(l: Live, session: StackFileSession, edit: FileEdit, stack: DockerStack, apply: Boolean, report: Reporter) {
        if (live !== l) return   // the server was switched after the confirmation was shown: nothing is sent anywhere
        report.busy("Saving ${edit.file.fileName}…")
        viewModelScope.launch {
            try {
                when (val outcome = session.save(edit, session.confirm(edit))) {
                    is SaveOutcome.Saved -> {
                        if (apply) {
                            report.busy("Updating ${stack.name}…")
                            l.docker.perform(ComposeAction.UP, stack, l.docker.confirm(ComposeAction.UP, stack))
                            l.docker.state.value.actionError?.let { err ->
                                report.notice("Saved, but updating ${stack.name} failed: $err")
                                if (live === l) refreshDockerNow()
                                return@launch
                            }
                        }
                        report.finished()
                        if (live === l) refreshDockerNow()
                    }
                    SaveOutcome.ChangedOnServer ->
                        report.notice("${edit.file.fileName} changed on ${l.server.name} after you opened this, so nothing was saved. Close this and try again.")
                    is SaveOutcome.Invalid ->
                        report.notice("${l.server.name} refused the file: " + (outcome.issues.firstOrNull()?.message ?: "it did not pass the compose check"))
                }
            } catch (e: Exception) {
                report.notice(bookmarkError(e))
            }
        }
    }

    private fun bookmarkError(e: Exception): String = when (e) {
        is kotlinx.coroutines.CancellationException -> throw e
        else -> e.message ?: e.toString()
    }

    private fun Live.endpointUser(): String = server.user?.takeIf { it.isNotEmpty() } ?: "root"

    // MARK: server settings

    private val _settings = MutableStateFlow<SettingsForm?>(null)
    val settings: StateFlow<SettingsForm?> = _settings.asStateFlow()

    fun openSettings() {
        val server = current() ?: return
        val stored = c.secrets.load(server.id)
        _settings.value = SettingsForm(
            server = server, name = server.name, auth = AuthFields(stored?.kind ?: AuthKind.Tailscale),
            currentKind = stored?.kind ?: AuthKind.Tailscale, currentKeyName = stored?.keyName,
            hostKey = c.knownHosts.lookup(server.host, server.port ?: 22),
        )
    }

    fun closeSettings() { _settings.value = null }

    fun editSettings(change: (SettingsForm) -> SettingsForm) { _settings.update { it?.let(change) } }

    /** Which sign-in the server uses, for the Overview's advice when a login is refused. */
    fun signInOf(server: Server): ConnectionFailure.SignIn? = when (c.secrets.load(server.id)?.kind) {
        AuthKind.Tailscale -> ConnectionFailure.SignIn.Tailscale
        AuthKind.Key -> ConnectionFailure.SignIn.Key
        AuthKind.Password -> ConnectionFailure.SignIn.Password
        null -> ConnectionFailure.SignIn.Tailscale   // nothing saved means the default, Tailscale SSH
    }

    /**
     * Saves the form. A rename alone is saved at once and changes nothing live. A changed address or sign-in is tried against
     * the server first (asking to trust the host key when the address is new), and only then saved; the selected server
     * reconnects, and what was open against the old address (terminals, the cached reading) is dropped.
     */
    fun saveSettings() {
        val form = _settings.value ?: return
        ServerInput.problem(form.host, form.user, form.port)?.let { problem -> editSettings { it.copy(error = problem) }; return }
        val host = form.host.trim()
        val user = form.user.trim().ifEmpty { "root" }
        val port = form.port.trim().toIntOrNull()?.takeIf { it != 22 }
        val updated = form.server.copy(name = form.name.trim().ifEmpty { host }, host = host, user = user, port = port)
        val addressChanged = !form.server.connectsLike(updated)
        if (!addressChanged && !form.authChanged) {
            updateServer(updated); _settings.value = null; return
        }
        if (c.isDemo) { editSettings { it.copy(error = "Demo mode: connections can't be changed. Restart the app normally to use your own.") }; return }
        if (form.authChanged) form.auth.problem()?.let { problem -> editSettings { it.copy(error = problem) }; return }
        editSettings { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                if (addressChanged && c.knownHosts.lookup(host, port ?: 22) == null) {
                    // A new address has no trusted key yet: show it before any credentials are sent.
                    val key = scanHostKey(host, port ?: 22)
                    editSettings { it.copy(busy = false, trust = key) }
                } else {
                    tryAndCommit(form, updated, addressChanged)
                }
            } catch (e: SshException) {
                editSettings { it.copy(busy = false, error = e.message) }
            }
        }
    }

    fun trustSettingsKey() {
        val form = _settings.value ?: return
        val key = form.trust ?: return
        val host = form.host.trim()
        val port = form.port.trim().toIntOrNull() ?: 22
        c.knownHosts.trust(host, port, key)
        editSettings { it.copy(trust = null, busy = true, error = null) }
        val updated = form.server.copy(
            name = form.name.trim().ifEmpty { host }, host = host, user = form.user.trim().ifEmpty { "root" }, port = port.takeIf { it != 22 },
        )
        viewModelScope.launch {
            try { tryAndCommit(form, updated, addressChanged = true) } catch (e: SshException) { editSettings { it.copy(busy = false, error = e.message) } }
        }
    }

    fun declineSettingsTrust() { editSettings { it.copy(trust = null) } }

    /** Signs in with the new details once; only when that works is anything saved. A failure leaves the old server untouched. */
    private suspend fun tryAndCommit(form: SettingsForm, updated: Server, addressChanged: Boolean) {
        val old = form.server
        val stored = if (form.authChanged) form.auth.toStored() else c.secrets.load(old.id) ?: StoredAuth(AuthKind.Tailscale)
        val endpoint = SshEndpoint(updated.host, updated.port ?: 22, updated.user ?: "root", stored.toSshAuth())
        val test = c.connection(endpoint)
        try {
            test.connect()
        } finally {
            test.close()
        }
        if (form.authChanged) c.secrets.save(old.id, stored)
        if (addressChanged) {
            c.terminals.closeAll(old.id)   // they are ssh sessions to the old address
            if (old.host != updated.host) c.snapshots.remove(old.id)   // another machine's past is not this server's
            // The old address's trusted key goes unless another saved server still connects there.
            if ((old.host != updated.host || old.port != updated.port) && _servers.value.none { it.id != old.id && it.host == old.host && it.port == old.port }) {
                c.knownHosts.forget(old.host, old.port ?: 22)
            }
        }
        updateServer(updated)
        _settings.value = null
        if (old.id == _selectedId.value) {
            _tab.value = Tab.Overview
            openLive(updated)   // reconnect with the new details
        }
    }

    private fun updateServer(updated: Server) {
        _servers.update { list -> list.map { if (it.id == updated.id) updated else it } }
        c.servers.save(_servers.value)
    }

    /** Removes the trusted key. The next connection asks to trust whatever the server presents, so use it after the key really changed. */
    fun forgetHostKey() {
        val server = _settings.value?.server ?: return
        c.knownHosts.forget(server.host, server.port ?: 22)
        _settings.value = null
        _tab.value = Tab.Overview
        if (server.id == _selectedId.value) openLive(server)
    }

    fun removeFromSettings() {
        val server = _settings.value?.server ?: return
        _settings.value = null
        remove(server)
    }

    // Last on purpose: openLive() sets state flows declared above, and property initialisers run in order.
    init { current()?.let(::openLive); watchIdle() }

    override fun onCleared() {
        live?.transport?.close()
    }
}
