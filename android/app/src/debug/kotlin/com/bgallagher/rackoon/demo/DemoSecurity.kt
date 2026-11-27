package com.bgallagher.rackoon.demo

import com.bgallagher.rackoon.core.OSVClient
import com.bgallagher.rackoon.core.OSVException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Canned answers for the Security screen in demo mode (the same made-up servers as the Mac and iPhone demos): homelab is
 * mostly hardened, garage-nuc is a default install with no firewall. Nothing is sent anywhere.
 */
object DemoSecurity {
    fun output(hostname: String): String = if (hostname == "homelab") HOMELAB else NUC

    fun packages(hostname: String): String {
        val homelab = hostname == "homelab"
        val os = if (homelab) "id=ubuntu\nlike=debian\nversion=24.04\ncodename=noble" else "id=debian\nlike=\nversion=12\ncodename=bookworm"
        val rows = if (homelab) listOf(
            listOf("curl", "8.5.0-2ubuntu10.5", "curl", "8.5.0-2ubuntu10.5"),
            listOf("libc6", "2.39-0ubuntu8.3", "glibc", "2.39-0ubuntu8.3"),
            listOf("libssl3t64", "3.0.13-0ubuntu3.4", "openssl", "3.0.13-0ubuntu3.4"),
            listOf("openssl", "3.0.13-0ubuntu3.4", "openssl", "3.0.13-0ubuntu3.4"),
            listOf("openssh-server", "1:9.6p1-3ubuntu13.5", "openssh", "1:9.6p1-3ubuntu13.5"),
        ) else listOf(listOf("bash", "5.2.15-2+b7", "bash", "5.2.15-2"), listOf("libc6", "2.36-9+deb12u7", "glibc", "2.36-9+deb12u7"))
        return "##os\n$os\n##packages\n" + rows.joinToString("") { it.joinToString("\t") + "\n" }
    }

    private const val HOMELAB = """##uid
1000
##os
id=ubuntu
like=debian
version=24.04
##sshd
installed=yes
active=1
##sshd_effective
##sshd_files
#file /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
KbdInteractiveAuthentication no
X11Forwarding yes
#file /etc/ssh/sshd_config.d/10-rackoon-demo.conf
PermitRootLogin no
PasswordAuthentication no
##tailscale_ssh
"RunSSH": true
##firewall
ENABLED=yes
ufw=active
firewalld=inactive
nftables=inactive
##guards
fail2ban=active
crowdsec=inactive
sshguard=inactive
##listen
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
tcp LISTEN 0 4096 [::]:22 [::]:*
tcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*
tcp LISTEN 0 4096 0.0.0.0:8096 0.0.0.0:*
##docker
installed=yes
jellyfin	0.0.0.0:8096->8096/tcp
##docker_inspect
/jellyfin|false|bridge||/srv/media;
##unattended
package=install ok installed
APT::Periodic::Unattended-Upgrade "1";
##uid0
root
##shadow_empty
##aslr
2
##ntp
yes
"""

    private const val NUC = """##uid
1000
##os
id=debian
like=
version=12
##sshd
installed=yes
active=1
##sshd_effective
##sshd_files
#file /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
#PermitRootLogin prohibit-password
##tailscale_ssh
##firewall
ufw=inactive
firewalld=inactive
nftables=inactive
##guards
fail2ban=inactive
crowdsec=inactive
sshguard=inactive
##listen
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
tcp LISTEN 0 4096 0.0.0.0:6379 0.0.0.0:*
##docker
installed=no
##docker_inspect
##unattended
package=
##uid0
root
##shadow_empty
##aslr
2
##ntp
no
"""
}

/** Made-up OSV.dev answers (ids in 2099), so demo mode never sends a package list anywhere. */
class DemoOSVClient : OSVClient {
    private val byPackage = mapOf("openssl" to listOf("DEMO-CVE-2099-0101"), "glibc" to listOf("DEMO-CVE-2099-0102"), "openssh" to listOf("DEMO-CVE-2099-0103"))
    private val records = mapOf(
        "DEMO-CVE-2099-0101" to Rec("openssl", "3.0.13-0ubuntu3.5", "medium", "Demo advisory: a made-up OpenSSL issue, fixed in the waiting update"),
        "DEMO-CVE-2099-0102" to Rec("glibc", null, "low", "Demo advisory: a made-up glibc issue with no fix released yet"),
        "DEMO-CVE-2099-0103" to Rec("openssh", "1:9.6p1-3ubuntu13.8", "high", "Demo advisory: a made-up OpenSSH issue, fixed but not in the package lists yet"),
    )

    private class Rec(val pkg: String, val fixed: String?, val priority: String, val summary: String)

    override suspend fun post(url: String, body: String): String {
        val queries = (Json.parseToJsonElement(body) as JsonObject)["queries"] as JsonArray
        return queries.joinToString(",", "{\"results\":[", "]}") { q ->
            val name = ((q as JsonObject)["package"] as JsonObject)["name"]!!.jsonPrimitive.content
            val ids = byPackage[name].orEmpty()
            if (ids.isEmpty()) "{}" else ids.joinToString(",", "{\"vulns\":[", "]}") { "{\"id\":\"$it\",\"modified\":\"2099-01-01T00:00:00Z\"}" }
        }
    }

    override suspend fun get(url: String): String {
        val id = url.substringAfterLast('/')
        val r = records[id] ?: throw OSVException("HTTP 404")
        val events = "{\"introduced\":\"0\"}" + (r.fixed?.let { ",{\"fixed\":\"$it\"}" } ?: "")
        return """{"id":"$id","summary":"${r.summary}","modified":"2099-01-01T00:00:00Z","aliases":["${id.removePrefix("DEMO-")}"],""" +
            """"severity":[{"type":"Ubuntu","score":"${r.priority}"}],"affected":[{"package":{"ecosystem":"Ubuntu:24.04:LTS","name":"${r.pkg}"},""" +
            """"ranges":[{"type":"ECOSYSTEM","events":[$events]}]}]}"""
    }
}
