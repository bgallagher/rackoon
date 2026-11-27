package com.bgallagher.rackoon.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.Issue
import com.bgallagher.rackoon.OverviewUi
import com.bgallagher.rackoon.Tab
import com.bgallagher.rackoon.RebootUi
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

@Composable
fun RackoonRoot(vm: AppViewModel) {
    val firstRun by vm.firstRun.collectAsStateWithLifecycle()
    val servers by vm.servers.collectAsStateWithLifecycle()
    val selected by vm.selectedServer.collectAsStateWithLifecycle()
    val add by vm.add.collectAsStateWithLifecycle()
    val readOnly by vm.readOnly.collectAsStateWithLifecycle()
    val tab by vm.tab.collectAsStateWithLifecycle()
    val overview by vm.overview.collectAsStateWithLifecycle()
    val switcher by vm.switcher.collectAsStateWithLifecycle()
    val appearance by vm.appearance.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val bookmarksOpen by vm.bookmarksOpen.collectAsStateWithLifecycle()
    val updatesOpen by vm.updatesOpen.collectAsStateWithLifecycle()
    val securityOpen by vm.securityOpen.collectAsStateWithLifecycle()
    val morePage by vm.morePage.collectAsStateWithLifecycle()
    val reboot by vm.reboot.collectAsStateWithLifecycle()
    val editorFile by vm.editorFile.collectAsStateWithLifecycle()
    val addOpen by vm.addOpen.collectAsStateWithLifecycle()
    val bookmarkForm by vm.bookmarkForm.collectAsStateWithLifecycle()
    val pending by vm.pending.collectAsStateWithLifecycle()
    val deleting by vm.deleting.collectAsStateWithLifecycle()
    val themeId by vm.themeId.collectAsStateWithLifecycle()

    val snackbar = remember { androidx.compose.material3.SnackbarHostState() }
    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    Box(Modifier.fillMaxSize().background(Rackoon.colors.background)) {
        when {
            settings != null -> ServerSettingsScreen(settings!!, vm::editSettings, vm::saveSettings, vm::closeSettings, vm::forgetHostKey, vm::removeFromSettings, vm::trustSettingsKey, vm::declineSettingsTrust)
            addOpen -> AddContainerScreen(vm, readOnly)
            editorFile != null -> EditorScreen(vm, editorFile!!, readOnly)
            bookmarksOpen -> BookmarksScreen(vm, readOnly, onBack = { vm.showBookmarks(false) })
            morePage != null -> MorePageScreen(vm, morePage!!)
            updatesOpen -> UpdatesScreen(vm, readOnly, selected?.name.orEmpty(), onBack = { vm.showUpdates(false) })
            securityOpen && selected != null -> SecurityScreen(vm, selected!!.id, selected!!.name, selected!!.user, onBack = { vm.showSecurity(false) })
            appearance -> AppearanceScreen(themeId, onPick = vm::setTheme, onBack = { vm.showAppearance(false) })
            add != null -> AddServerScreen(add!!, vm::editAdd, vm::submitAdd, vm::cancelAdd, vm::trustAndConnect, vm::declineTrust)
            firstRun -> FirstRunScreen(vm::dismissFirstRun)
            selected == null -> Welcome(onAdd = vm::startAdd)
            else -> Shell(vm, selected!!, overview, tab, readOnly, reboot)
        }
        bookmarkForm?.let { BookmarkSheet(vm, it, readOnly) }
        deleting?.let { stack ->
            val user = selected?.user?.takeIf { it.isNotEmpty() } ?: "root"
            if (stack.isStandalone) DeleteContainerSheet(stack, user, onCancel = vm::cancelDelete, onRun = { vm.deleteContainer(stack, it) })
            else DeleteStackSheet(stack, selected?.name.orEmpty(), user, onCancel = vm::cancelDelete, onRun = { vm.deleteStack(stack, it) })
        }
        pending?.let { ConfirmSheet(it, onCancel = vm::cancelPending, onConfirm = vm::confirmPending) }
        if (switcher) ServerSwitcher(
            servers, selected, overview, onPick = vm::select, onAdd = vm::startAdd, onRemove = vm::remove,
            onEdit = { vm.showSwitcher(false); vm.editServer(it) }, onDismiss = { vm.showSwitcher(false) },
        )
        androidx.compose.material3.SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 88.dp)) { data ->
            androidx.compose.material3.Snackbar(data, containerColor = Rackoon.colors.selection, contentColor = Rackoon.colors.textPrimary)
        }
    }
}

@Composable
private fun Welcome(onAdd: () -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("🦝", fontSize = 56.sp)
        Text("Add your first server", fontSize = 24.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.padding(top = 16.dp))
        Text(
            "Rackoon connects over SSH and runs standard commands. Nothing is installed on the server.",
            color = Rackoon.colors.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
        )
        PrimaryButton("Add server", onAdd, Modifier.fillMaxWidth())
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Shell(vm: AppViewModel, server: Server, overview: OverviewUi, tab: Tab, readOnly: Boolean, reboot: RebootUi?) {
    // The keyboard lifts the whole screen once; the bottom bar steps aside while it is open on the terminal (it would only waste space).
    val keyboardOpen = WindowInsets.isImeVisible
    // Tablets, unfolded foldables and landscape phones get a rail on the left instead of a bar at the bottom.
    val wide = LocalConfiguration.current.screenWidthDp >= 840
    // The More tab carries a dot when something needs attention there (Updates lives in More), from the Overview's own counts.
    val moreAlert = moreAlertText((overview as? OverviewUi.Ready)?.state?.overview)
    // Back from any other tab goes to Overview; only from Overview does it leave the app. This is registered before the screens inside,
    // so their own handlers (an open stack, full-screen logs) still get the first back press.
    androidx.activity.compose.BackHandler(enabled = tab != Tab.Overview) { vm.showTab(Tab.Overview) }
    // An open stack has its own app bar (name, status, server, Read-only chip), so the shared one steps aside.
    val openStack by vm.openStack.collectAsStateWithLifecycle()
    val stackOpen = tab == Tab.Docker && openStack != null
    Row(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
        if (wide) NavRail(tab, vm::showTab, moreAlert)
        Column(Modifier.weight(1f).fillMaxSize()) {
            if (!stackOpen) TopBar(server.name, statusColor(overview), readOnly, onSwitcher = { vm.showSwitcher(true) }, onReadOnly = vm::toggleReadOnly)
            Box(Modifier.weight(1f)) {
                when (tab) {
                    Tab.Overview -> {
                        val lifecycle = LocalLifecycleOwner.current.lifecycle
                        // Poll only while the screen is visible: no background work, no battery cost when the phone is in a pocket.
                        LaunchedEffect(server.id) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollWhileVisible() } }
                        OverviewScreen(overview, wide, reboot, serverName = server.name, readOnly = readOnly, onReboot = vm::requestReboot, onDismissReboot = vm::dismissReboot, onRefresh = vm::refreshNow, onTrustFirstKey = vm::trustPresented, onEditConnection = vm::openSettings, signIn = remember(server.id, overview) { vm.signInOf(server) }, onBack = { vm.showSwitcher(true) }, onOpenFix = { fix -> vm.showTab(when (fix) { "docker" -> Tab.Docker; "terminal" -> Tab.Terminal; else -> Tab.Overview }.also { if (fix == "updates") vm.showUpdates(true) }) })
                    }
                    Tab.Docker -> {
                        val lifecycle = LocalLifecycleOwner.current.lifecycle
                        LaunchedEffect(server.id) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollDockerWhileVisible() } }
                        DockerScreen(vm, server, wide, readOnly)
                    }
                    Tab.Terminal -> TerminalScreen(vm, server, readOnly, onTurnOffReadOnly = vm::toggleReadOnly)
                    Tab.More -> MoreScreen(vm, server.name, updatesNote(overview), themeLabel(vm.themeId.collectAsStateWithLifecycle().value), serversNote = vm.servers.collectAsStateWithLifecycle().value.size)
                }
            }
            if (!wide && !(tab == Tab.Terminal && keyboardOpen)) BottomBar(tab, vm::showTab, moreAlert)
        }
    }
}

private val tabItems get() = listOf(Tab.Overview to ("Overview" to RackoonIcons.Overview), Tab.Docker to ("Docker" to RackoonIcons.Docker), Tab.Terminal to ("Terminal" to RackoonIcons.Terminal), Tab.More to ("More" to RackoonIcons.More))

@Composable
private fun NavRail(tab: Tab, onTab: (Tab) -> Unit, moreAlert: String?) {
    val c = Rackoon.colors
    androidx.compose.material3.NavigationRail(containerColor = c.sidebar) {
        Spacer(Modifier.weight(1f))
        tabItems.forEach { (t, label) ->
            androidx.compose.material3.NavigationRailItem(
                selected = tab == t, onClick = { onTab(t) }, icon = { TabIcon(t, label.second, moreAlert) }, label = { Text(label.first) },
                colors = androidx.compose.material3.NavigationRailItemDefaults.colors(
                    selectedIconColor = c.accent, selectedTextColor = c.textPrimary, unselectedIconColor = c.textSecondary,
                    unselectedTextColor = c.textSecondary, indicatorColor = c.accent.copy(alpha = 0.2f),
                ),
            )
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun statusColor(ui: OverviewUi) = when (ui) {
    OverviewUi.Connecting -> Rackoon.colors.warn
    is OverviewUi.Ready -> if (ui.state.error != null || ui.state.isStale) Rackoon.colors.warn else Rackoon.colors.ok
    is OverviewUi.Failed -> Rackoon.colors.danger
}

@Composable
private fun TopBar(name: String, dot: androidx.compose.ui.graphics.Color, readOnly: Boolean, onSwitcher: () -> Unit, onReadOnly: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 8.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.height(48.dp).clip(RoundedCornerShape(24.dp)).clickable(onClick = onSwitcher).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusDot(dot)
            Text(name, fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary)
            Icon(RackoonIcons.ChevronDown, "Switch server", tint = Rackoon.colors.textSecondary, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.weight(1f))
        ReadOnlyChip(readOnly, onReadOnly)
    }
}

/**
 * The Read-only chip. Same label and width in both states, so nothing around it moves: ON is the accent fill with a closed lock,
 * OFF is a stronger outline with an open lock (changes are allowed, which is the state to notice).
 */
@Composable
fun ReadOnlyChip(on: Boolean, onClick: () -> Unit, small: Boolean = false) {
    val c = Rackoon.colors
    val shape = RoundedCornerShape(if (small) 8.dp else 10.dp)
    val state = if (on) "Read-only on. Tap to allow changes." else "Read-only off. Tap to turn on."
    Row(
        Modifier.width(if (small) 96.dp else 112.dp).height(if (small) 28.dp else 36.dp).clip(shape)
            .then(if (on) Modifier.background(c.accent) else Modifier.border(BorderStroke(1.dp, c.textMuted.copy(alpha = 0.6f)), shape))
            .clickable(onClick = onClick).semantics { contentDescription = state },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        Icon(if (on) RackoonIcons.Lock else RackoonIcons.LockOpen, null, tint = if (on) c.accentText else c.textSecondary, modifier = Modifier.size(if (small) 12.dp else 14.dp))
        Text("Read-only", color = if (on) c.accentText else c.textPrimary, fontSize = if (small) 12.sp else 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun BottomBar(tab: Tab, onTab: (Tab) -> Unit, moreAlert: String?) {
    val c = Rackoon.colors
    NavigationBar(containerColor = c.sidebar, modifier = Modifier.navigationBarsPaddingFix()) {
        tabItems.forEach { (t, label) ->
            NavigationBarItem(
                selected = tab == t, onClick = { onTab(t) }, icon = { TabIcon(t, label.second, moreAlert) }, label = { Text(label.first) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = c.accent, selectedTextColor = c.textPrimary, unselectedIconColor = c.textSecondary,
                    unselectedTextColor = c.textSecondary, indicatorColor = c.accent.copy(alpha = 0.2f),
                ),
            )
        }
    }
}

/** A tab icon; More gets an amber dot (and a spoken description) when [moreAlert] says something there needs attention. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TabIcon(tab: Tab, icon: androidx.compose.ui.graphics.vector.ImageVector, moreAlert: String?) {
    if (tab == Tab.More && moreAlert != null) {
        androidx.compose.material3.BadgedBox(badge = { androidx.compose.material3.Badge(containerColor = Rackoon.colors.warnRole.mark) }) {
            Icon(icon, "More, $moreAlert")
        }
    } else Icon(icon, null)
}

private fun moreAlertText(o: com.bgallagher.rackoon.core.Overview?): String? {
    o ?: return null
    return when {
        o.securityUpdates > 0 -> "${o.securityUpdates} security update${if (o.securityUpdates == 1) "" else "s"}"
        o.rebootRequired -> "reboot required"
        else -> null
    }
}

// NavigationBar already insets for the system bar; this keeps the call site readable.
private fun Modifier.navigationBarsPaddingFix(): Modifier = this

@Composable
private fun Placeholder(title: String, body: String) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(RackoonIcons.Terminal, null, tint = Rackoon.colors.textMuted, modifier = Modifier.size(40.dp))
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Medium, color = Rackoon.colors.textPrimary, modifier = Modifier.padding(top = 12.dp))
        Text(body, color = Rackoon.colors.textSecondary, lineHeight = 21.sp, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun MoreScreen(vm: AppViewModel, serverName: String, updatesNote: String, themeName: String, serversNote: Int) {
    val c = Rackoon.colors
    val auto = vm.autoReadOnly.collectAsStateWithLifecycle().value
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        MoreSection("SERVER · ${serverName.uppercase()}") {
            MoreRow("Updates", updatesNote) { vm.showUpdates(true) }
            MoreDivider()
            MoreRow("Security", "Common hardening checks and open ports") { vm.showSecurity(true) }
            MoreDivider()
            MoreRow("Bookmarks", "Links to your services") { vm.showBookmarks(true) }
            MoreDivider()
            MoreRow("Server settings", "Name, address and sign-in for $serverName") { vm.openSettings() }
        }
        MoreSection("SERVERS") {
            MoreRow("Servers", "$serversNote saved · switch, add or remove") { vm.showSwitcher(true) }
        }
        MoreSection("APP") {
            MoreRow("Appearance", themeName) { vm.showAppearance(true) }
            MoreDivider()
            MoreRow("Terminal", "Font size, output highlighting") { vm.showMorePage(AppViewModel.MorePage.Terminal) }
            MoreDivider()
            MoreRow("Safety", "Read-only: ${auto.label.replaceFirstChar { it.lowercase() }}") { vm.showMorePage(AppViewModel.MorePage.Safety) }
            MoreDivider()
            MoreRow("About", "Version, credits") { vm.showMorePage(AppViewModel.MorePage.About) }
        }
        Text("Rackoon ${appVersion()}", color = c.textMuted, fontSize = 12.sp, modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 16.dp))
    }
}

@Composable
private fun appVersion(): String {
    val context = androidx.compose.ui.platform.LocalContext.current
    return remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "" }.orEmpty()
}

@Composable
private fun MoreSection(title: String, content: @Composable () -> Unit) {
    Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp, color = Rackoon.colors.textMuted, modifier = Modifier.padding(start = 4.dp, top = 10.dp))
    RCard(Modifier.fillMaxWidth()) { Column { content() } }
}

@Composable
private fun MoreDivider() { Box(Modifier.fillMaxWidth().height(1.dp).background(Rackoon.colors.border)) }

@Composable
private fun MoreRow(title: String, subtitle: String, onClick: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium, color = if (onClick != null) Rackoon.colors.textPrimary else Rackoon.colors.textMuted)
            Text(subtitle, fontSize = 12.sp, color = Rackoon.colors.textMuted)
        }
        if (onClick != null) Icon(RackoonIcons.ChevronRight, null, tint = Rackoon.colors.textMuted, modifier = Modifier.size(18.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ServerSwitcher(servers: List<Server>, selected: Server?, overview: OverviewUi, onPick: (Server) -> Unit, onAdd: () -> Unit, onRemove: (Server) -> Unit, onEdit: (Server) -> Unit, onDismiss: () -> Unit) {
    var removing by remember { mutableStateOf<Server?>(null) }
    val c = Rackoon.colors
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(), containerColor = c.sidebar, scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f)) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Servers", fontSize = 20.sp, fontWeight = FontWeight.Medium, color = c.textPrimary, modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp))
            servers.forEach { s ->
                val isSel = s.id == selected?.id
                // Only the selected server has a live connection, so only it can say more than "Not connected".
                val host = "${s.user ?: "root"}@${s.host}"
                val (dot, status, statusColor, detail) = if (isSel) when (overview) {
                    OverviewUi.Connecting -> Quad(c.warn, "Connecting…", c.warnRole.label, host)
                    is OverviewUi.Ready -> Quad(c.ok, "Connected", c.okRole.label, overview.state.overview?.os?.prettyName ?: host)
                    is OverviewUi.Failed -> Quad(c.danger, failureNote(overview.issue), c.dangerRole.label, host)
                } else Quad(c.idle, "Not connected", c.textMuted, host)
                var menu by remember { mutableStateOf(false) }
                Row(
                    Modifier.fillMaxWidth().heightMin(64).clip(RoundedCornerShape(14.dp)).background(if (isSel) c.selection else androidx.compose.ui.graphics.Color.Transparent)
                        .combinedClickable(onClick = { onPick(s) }, onLongClick = { removing = s }).padding(start = 12.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    StatusDot(dot, 10)
                    Column(Modifier.weight(1f)) {
                        Text(s.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(status, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = statusColor)
                            Text("· $detail", fontSize = 13.sp, color = c.textMuted, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        }
                    }
                    if (isSel) Icon(RackoonIcons.Check, "Current server", tint = c.accent, modifier = Modifier.padding(end = 12.dp).size(20.dp))
                    else Box {
                        IconTap(RackoonIcons.More, "Actions for ${s.name}", c.textSecondary, { menu = true })
                        DropdownMenu(menu, { menu = false }, containerColor = c.selection) {
                            DropdownMenuItem(text = { Text("Connect", color = c.textPrimary) }, onClick = { menu = false; onPick(s) })
                            DropdownMenuItem(text = { Text("Edit", color = c.textPrimary) }, onClick = { menu = false; onEdit(s) })
                            DropdownMenuItem(text = { Text("Remove…", color = c.danger) }, onClick = { menu = false; removing = s })
                        }
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().heightMin(56).padding(top = 4.dp).clip(RoundedCornerShape(14.dp)).border(BorderStroke(1.dp, c.border), RoundedCornerShape(14.dp))
                    .clickable(onClick = onAdd).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Icon(RackoonIcons.Plus, null, tint = c.accent, modifier = Modifier.size(20.dp))
                Text("Add server", color = c.accent, fontWeight = FontWeight.Medium)
            }
        }
    }
    removing?.let { s ->
        AlertDialog(
            onDismissRequest = { removing = null }, containerColor = c.sidebar,
            title = { Text("Remove ${s.name}?", color = c.textPrimary) },
            text = { Text("It is removed from this phone, along with its trusted host key. Nothing changes on the server.", color = c.textSecondary) },
            confirmButton = { TextButton(onClick = { onRemove(s); removing = null }) { Text("Remove", color = c.danger) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel", color = c.textPrimary) } },
        )
    }
}

private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)

private fun Modifier.heightMin(dp: Int): Modifier = this.then(Modifier.defaultMinSize(minHeight = dp.dp))

private fun failureNote(issue: Issue) = when (issue) {
    is Issue.Unreachable -> "Can't reach it"
    is Issue.AuthFailed -> "Sign-in refused"
    is Issue.KeyChanged -> "Host key changed"
    is Issue.KeyUnknown -> "Host key not trusted"
    is Issue.Other -> "Connection failed"
}

private fun themeLabel(id: String): String =
    if (id == com.bgallagher.rackoon.core.ThemeCatalog.AUTOMATIC_ID) "Automatic (follows the system)"
    else com.bgallagher.rackoon.core.ThemeCatalog.bundled().firstOrNull { it.id == id }?.name ?: "Automatic (follows the system)"

/** The More row's subtitle, from the Overview's own counts (so it costs no extra poll). */
private fun updatesNote(overview: OverviewUi): String {
    val o = (overview as? OverviewUi.Ready)?.state?.overview ?: return "Packages waiting to be installed"
    return when {
        o.pendingUpdates == 0 -> "Everything is up to date"
        o.securityUpdates > 0 -> "${o.pendingUpdates} available, ${o.securityUpdates} security"
        else -> "${o.pendingUpdates} available"
    }
}
