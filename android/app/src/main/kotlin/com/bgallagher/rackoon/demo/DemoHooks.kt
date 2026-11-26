package com.bgallagher.rackoon.demo

import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ssh.ServerConnection
import com.bgallagher.rackoon.ssh.SshEndpoint

/**
 * Demo mode: the whole app against made-up servers, for screenshots and for trying actions with no server at all. The real
 * implementation exists only in debug builds (see `src/debug`); a release build has [DemoBuild.hooks] = null, so a release APK
 * can never be put into demo mode.
 */
interface DemoHooks {
    /** The made-up servers the app starts with. */
    fun servers(): List<Server>

    /** A fake connection to one of them (no network, nothing is ever sent anywhere). */
    fun connection(endpoint: SshEndpoint): ServerConnection

    /** Made-up OSV.dev answers for the vulnerability lookup (nothing is sent). */
    fun osvClient(): com.bgallagher.rackoon.core.OSVClient
}
