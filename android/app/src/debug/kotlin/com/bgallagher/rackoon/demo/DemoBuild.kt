package com.bgallagher.rackoon.demo

import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ssh.ServerConnection
import com.bgallagher.rackoon.ssh.SshEndpoint

/** Debug builds: demo mode is available. */
object DemoBuild {
    val hooks: DemoHooks? = object : DemoHooks {
        override fun servers(): List<Server> = DemoWorlds.servers
        override fun connection(endpoint: SshEndpoint): ServerConnection = DemoConnection(DemoWorlds.worldFor(endpoint.host))
        override fun osvClient(): com.bgallagher.rackoon.core.OSVClient = DemoOSVClient()
    }
}
