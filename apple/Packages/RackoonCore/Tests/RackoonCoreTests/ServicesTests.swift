import Foundation
import XCTest
@testable import RackoonCore

final class ServicesTests: XCTestCase {
    /// Every fixture in spec/fixtures/services must parse to its expected JSON.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/services")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") && !$0.lastPathComponent.hasPrefix("raw-") }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 4)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let snapshot = ServicesParser.parse(try String(contentsOf: out, encoding: .utf8))
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
            if !FileManager.default.fileExists(atPath: expectedURL.path),
               ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: expectedURL)
                XCTFail("wrote \(expectedURL.lastPathComponent): review it, then commit")
                continue
            }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    private func fixture(_ name: String) throws -> ServicesSnapshot {
        ServicesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/services/\(name).out.txt"), encoding: .utf8))
    }

    private func service(_ s: ServicesSnapshot, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> DiscoveredService {
        try XCTUnwrap(s.services.first { $0.id == id }, "no \(id) in \(s.services.map(\.id))", file: file, line: line)
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(ServicesSession.command, commands.first { $0["id"] as? String == "services" }?["script"] as? String)
    }

    // MARK: real servers

    func testRunnerHostFindsTheSelfHostedServicesAndHidesThePlumbing() throws {
        let s = try fixture("ubuntu-runner-host")
        XCTAssertTrue(s.hasSystemd)
        XCTAssertFalse(s.isRoot)
        let visible = Set(s.services.filter(\.visibleByDefault).map(\.id))
        for id in ["system/tailscaled.service", "system/wazuh-agent.service", "system/beszel-agent.service", "system/docker.service",
                   "system/actions.runner.example-repo.runner1.service", "system/lab-journal.service", "system/lab-netconsole.service"] {
            XCTAssertTrue(visible.contains(id), id)
        }
        for id in ["system/dbus.service", "system/cron.service", "system/getty@tty1.service", "system/systemd-journald.service",
                   "system/cups.service", "system/containerd.service", "system/ssh.service", "system/user@1000.service"] {
            XCTAssertFalse(visible.contains(id), id)
        }
        // One-shots that ran at boot and are done are not services at all.
        XCTAssertNil(s.services.first { $0.unit == "ufw.service" || $0.unit == "apparmor.service" || $0.unit == "kdump-tools.service" })
        let tailscale = try service(s, "system/tailscaled.service")
        XCTAssertEqual(tailscale.name, "Tailscale")
        XCTAssertEqual(tailscale.product, "tailscale")
        XCTAssertEqual(tailscale.status, .running)
        XCTAssertEqual(tailscale.enabledAtBoot, true)
        XCTAssertNotNil(tailscale.activeSeconds)
        XCTAssertEqual(try service(s, "system/actions.runner.example-repo.runner1.service").name, "GitHub Actions runner")
        XCTAssertEqual(try service(s, "system/wazuh-agent.service").memoryBytes, 851_849_216)
        // A non-root user sees no process names in ss, so no ports are known here.
        XCTAssertTrue(s.services.allSatisfy { $0.ports.isEmpty })
    }

    func testUserUnitsAndHandStartedProcessesWithTheirPorts() throws {
        let s = try fixture("ubuntu-user-units-and-processes")
        let gateway = try service(s, "user/hermes-gateway.service")
        XCTAssertEqual(gateway.kind, .user)
        XCTAssertEqual(gateway.name, "Hermes Agent gateway")
        XCTAssertEqual(gateway.restarts, 1)
        XCTAssertEqual(gateway.ports, [ServicePort(address: "127.0.0.1", port: 38165)])
        XCTAssertTrue(gateway.visibleByDefault)
        // The user's PipeWire and dbus are plumbing.
        XCTAssertFalse(try service(s, "user/pipewire.service").visibleByDefault)
        XCTAssertFalse(try service(s, "user/dbus.service").visibleByDefault)

        let hermes = try service(s, "process/hermes")
        XCTAssertEqual(hermes.kind, .process)
        XCTAssertEqual(hermes.name, "Hermes Agent")
        XCTAssertEqual(hermes.ports, [ServicePort(address: "100.64.0.10", port: 9119)])
        XCTAssertTrue(hermes.visibleByDefault)

        // `npx paperclipai` and the postgres it started in the same login session are one service.
        let paperclip = try service(s, "process/paperclipai")
        XCTAssertEqual(paperclip.name, "Paperclip")
        XCTAssertEqual(paperclip.ports.map(\.port), [3100, 54329])
        XCTAssertNil(s.services.first { $0.id == "process/postgres" })
        XCTAssertTrue(paperclip.visibleByDefault)
        XCTAssertNil(paperclip.unit)
    }

    // MARK: synthetic cases

    func testRootSeesEveryPortAndProblemsAreAlwaysShown() throws {
        let s = try fixture("synthetic-root-failed")
        XCTAssertTrue(s.isRoot)
        let backup = try service(s, "system/backup-sync.service")
        XCTAssertEqual(backup.status, .failed)
        XCTAssertEqual(backup.result, "exit-code")
        XCTAssertEqual(backup.restarts, 5)
        XCTAssertTrue(backup.visibleByDefault)
        XCTAssertTrue(backup.isProblem)

        let tunnel = try service(s, "system/cloudflared.service")
        XCTAssertEqual(tunnel.status, .restarting)
        XCTAssertEqual(tunnel.name, "Cloudflare Tunnel")
        XCTAssertTrue(tunnel.isProblem)

        let beszel = try service(s, "system/beszel-agent.service")
        XCTAssertEqual(beszel.status, .stopped, "enabled but not running")
        XCTAssertNil(beszel.activeSeconds)

        let nginx = try service(s, "system/nginx.service")
        XCTAssertEqual(nginx.ports, [ServicePort(address: "0.0.0.0", port: 80), ServicePort(address: "0.0.0.0", port: 443)])
        XCTAssertEqual(try service(s, "system/pihole-FTL.service").name, "Pi-hole")
        let code = try service(s, "system/code-server@alice.service")
        XCTAssertEqual(code.name, "code-server")
        XCTAssertEqual(code.ports, [ServicePort(address: "127.0.0.1", port: 8080)])
        XCTAssertEqual(code.restarts, 2)
        // ssh holds port 22 on both stacks: one entry, and hidden by default (it is always there).
        let ssh = try service(s, "system/ssh.service")
        XCTAssertEqual(ssh.ports.map(\.port), [22])
        XCTAssertFalse(ssh.visibleByDefault)

        // Docker's own ports and a container's process belong to the Docker screen.
        XCTAssertNil(s.services.first { $0.ports.contains { $0.port == 9000 || $0.port == 8123 } })
        XCTAssertEqual(try service(s, "system/docker.service").ports, [])
        // A root-owned process outside any unit and session, unknown: listed, hidden.
        let frps = try service(s, "process/frps")
        XCTAssertFalse(frps.visibleByDefault)
        XCTAssertEqual(frps.ports.map(\.port), [7000])
        // Not found, and the one-shot ufw, are not listed.
        XCTAssertNil(s.services.first { $0.unit == "old-thing.service" || $0.unit == "ufw.service" })
        XCTAssertEqual(try service(s, "system/tailscaled.service").activeSeconds ?? 0, 86_388.25, accuracy: 0.01)
    }

    func testServerWithoutSystemdListsKnownProcesses() throws {
        let s = try fixture("synthetic-no-systemd")
        XCTAssertFalse(s.hasSystemd)
        XCTAssertTrue(try service(s, "process/syncthing").visibleByDefault)
        XCTAssertEqual(try service(s, "process/smbd").name, "Samba")
        XCTAssertTrue(try service(s, "process/nginx").visibleByDefault)
        XCTAssertFalse(try service(s, "process/sshd").visibleByDefault)
    }

    /// A real Unraid server (root, no systemd): Docker's port helpers are not services, and nginx's master and worker
    /// are one service named after the master.
    func testUnraidHidesDockerHelpersAndMergesWorkers() throws {
        let s = try fixture("unraid-no-systemd-root")
        XCTAssertTrue(s.isRoot)
        XCTAssertFalse(s.hasSystemd)
        XCTAssertNil(s.services.first { $0.name.contains("docker-proxy") })
        let nginx = s.services.filter { $0.name == "nginx" }
        XCTAssertEqual(nginx.count, 1)
        XCTAssertTrue(nginx[0].detail.contains("master process"))
        XCTAssertEqual(nginx[0].ports.map(\.port), [80, 443])
        XCTAssertEqual(Set(s.services.filter(\.visibleByDefault).map(\.name)), ["nginx", "Samba", "Tailscale"])
        XCTAssertEqual(s.services.count, 7)
    }

    // MARK: rules

    func testCgroupHomes() {
        XCTAssertEqual(ServiceDiscovery.home(of: "/system.slice/nginx.service"), .systemUnit("nginx.service"))
        XCTAssertEqual(ServiceDiscovery.home(of: "/user.slice/user-1000.slice/user@1000.service/app.slice/x.service"), .userUnit("x.service"))
        XCTAssertEqual(ServiceDiscovery.home(of: "/user.slice/user-1000.slice/session-3.scope"), .loose("/user.slice/user-1000.slice/session-3.scope"))
        XCTAssertEqual(ServiceDiscovery.home(of: "/system.slice/docker-4f1c.scope"), .container)
        XCTAssertEqual(ServiceDiscovery.home(of: "/kubepods/burstable/pod1/abc"), .container)
        XCTAssertEqual(ServiceDiscovery.home(of: "/"), .loose("/"))
    }

    func testProcessNames() {
        XCTAssertEqual(ServiceDiscovery.processName(comm: "node-MainThread", commandLine: "node /x/.bin/paperclipai onboard --yes"), "paperclipai")
        XCTAssertEqual(ServiceDiscovery.processName(comm: "python3", commandLine: "python3 -m homeassistant --config /config"), "homeassistant")
        XCTAssertEqual(ServiceDiscovery.processName(comm: "python3.12", commandLine: "/usr/bin/python3.12 /opt/app/serve.py"), "serve")
        XCTAssertEqual(ServiceDiscovery.processName(comm: "python3", commandLine: "python3 -I -c import os"), "python3")
        XCTAssertEqual(ServiceDiscovery.processName(comm: "hermes", commandLine: "python3 -c ..."), "hermes")
        XCTAssertEqual(ServiceDiscovery.processName(comm: "java", commandLine: "java -Xmx1g -jar /opt/mc/server.jar"), "java")
    }

    func testCatalogNamesAndPlumbing() {
        XCTAssertEqual(ServiceCatalog.baseName("code-server@alice.service"), "code-server")
        XCTAssertEqual(ServiceCatalog.baseName("wpa_supplicant.service"), "wpa-supplicant")
        XCTAssertEqual(ServiceCatalog.product(for: "pihole-FTL.service")?.id, "pi-hole")
        XCTAssertEqual(ServiceCatalog.product(for: "actions.runner.org-repo.host.service")?.id, "github-runner")
        XCTAssertTrue(ServiceCatalog.isPlumbing("systemd-resolved.service"))
        XCTAssertTrue(ServiceCatalog.isPlumbing("wpa_supplicant.service"))
        XCTAssertFalse(ServiceCatalog.isPlumbing("tailscaled.service"))
        XCTAssertEqual(ServiceDiscovery.displayName("code-server@alice.service"), "code-server (alice)")
        // Product ids are unique.
        XCTAssertEqual(Set(ServiceCatalog.products.map(\.id)).count, ServiceCatalog.products.count)
    }

    /// The Swift catalog must equal spec/service-catalog.json, which the other cores read at runtime. Edit the spec
    /// first, then these constants. Product order matters (the first match wins); the sets are compared as sets.
    func testCatalogMatchesTheSpecFile() throws {
        let url = specDir.appendingPathComponent("service-catalog.json")
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let products: [NSDictionary] = ServiceCatalog.products.map { p in
            var d: [String: Any] = ["id": p.id, "name": p.name, "names": p.names]
            if let icon = p.icon { d["icon"] = icon }
            if !p.prefixes.isEmpty { d["prefixes"] = p.prefixes }
            if p.hiddenByDefault { d["hiddenByDefault"] = true }
            return d as NSDictionary
        }
        XCTAssertEqual(spec["products"] as? [NSDictionary], products)
        func list(_ key: String) -> [String] { spec[key] as? [String] ?? [] }
        XCTAssertEqual(Set(list("plumbing")), ServiceCatalog.plumbing)
        XCTAssertEqual(list("plumbingPrefixes"), ServiceCatalog.plumbingPrefixes)
        XCTAssertEqual(Set(list("plumbingProcesses")), ServiceCatalog.plumbingProcesses)
        XCTAssertEqual(list("containerHelpers"), ServiceCatalog.containerHelpers)
        XCTAssertEqual(list("interpreters"), ServiceDiscovery.interpreters)
        XCTAssertEqual(Set(list("helpers")), ServiceDiscovery.helpers)
        // Each set-valued list is held without duplicates, so the comparison as sets loses nothing.
        for key in ["plumbing", "plumbingProcesses", "helpers"] { XCTAssertEqual(Set(list(key)).count, list(key).count, key) }
    }

    func testPortLinks() {
        XCTAssertEqual(ServicePort(address: "0.0.0.0", port: 80).linkHost(preferred: "100.64.0.10"), "100.64.0.10")
        XCTAssertEqual(ServicePort(address: "*", port: 80).linkHost(preferred: "192.168.1.20"), "192.168.1.20")
        XCTAssertNil(ServicePort(address: "127.0.0.1", port: 80).linkHost(preferred: "x"))
        XCTAssertNil(ServicePort(address: "::1", port: 80).linkHost(preferred: "x"))
        XCTAssertEqual(ServicePort(address: "100.64.0.10", port: 9119).linkHost(preferred: "192.168.1.20"), "100.64.0.10")
        XCTAssertEqual(ServicePort(address: "fd7a::10", port: 80).linkHost(preferred: nil), "[fd7a::10]")
        XCTAssertFalse(ServicePort(address: "0.0.0.0", port: 22).isLikelyWeb)
        XCTAssertTrue(ServicePort(address: "0.0.0.0", port: 3100).isLikelyWeb)
    }

    func testSearchMatches() throws {
        let s = try fixture("synthetic-root-failed")
        let nginx = try service(s, "system/nginx.service")
        XCTAssertTrue(nginx.matches("nginx 443"))
        XCTAssertTrue(nginx.matches("REVERSE proxy"))
        XCTAssertFalse(nginx.matches("nginx 8443"))
    }

    // MARK: showing and hiding

    func testVisibilityOverrides() throws {
        let s = try fixture("synthetic-root-failed")
        let ssh = try service(s, "system/ssh.service"), nginx = try service(s, "system/nginx.service")
        var v = ServiceVisibility()
        XCTAssertFalse(v.isVisible(ssh, server: "a"))
        v.set(true, service: ssh.id, server: "a")
        XCTAssertTrue(v.isVisible(ssh, server: "a"))
        XCTAssertFalse(v.isVisible(ssh, server: "b"))
        XCTAssertTrue(v.isChosen(ssh, server: "a"))

        // Everywhere replaces each server's own choice for that service.
        v.set(false, service: nginx.id, server: "a")
        v.set(true, service: ssh.id, server: "a", everywhere: true)
        XCTAssertTrue(v.isVisible(ssh, server: "b"))
        XCTAssertNil(v.overrides["a|" + ssh.id])
        XCTAssertFalse(v.isVisible(nginx, server: "a"))
        XCTAssertTrue(v.isVisible(nginx, server: "b"))
        // A server's own choice still wins over the everywhere rule.
        v.set(false, service: ssh.id, server: "c")
        XCTAssertFalse(v.isVisible(ssh, server: "c"))

        XCTAssertTrue(v.forget(serverID: "a"))
        XCTAssertTrue(v.isVisible(nginx, server: "a"))
        XCTAssertFalse(v.forget(serverID: "a"))
        v.set(nil, service: ssh.id, server: "*", everywhere: true)
        XCTAssertFalse(v.isVisible(ssh, server: "b"))
    }

    // MARK: actions

    func testActionCommands() throws {
        let s = try fixture("ubuntu-user-units-and-processes")
        let tailscale = try service(s, "system/tailscaled.service")
        let restart = try XCTUnwrap(ServiceActions.command(.restart, for: tailscale))
        XCTAssertTrue(restart.isMutating)
        XCTAssertTrue(restart.root)
        XCTAssertEqual(restart.script, "$S systemctl restart 'tailscaled.service' && echo \"Now: $(systemctl is-active 'tailscaled.service')\"")
        XCTAssertNotNil(restart.preview)
        XCTAssertNotNil(restart.warning, "stopping Tailscale can cut the connection")
        XCTAssertTrue(restart.readableScript().hasPrefix("sudo systemctl restart"))

        let gateway = try service(s, "user/hermes-gateway.service")
        let stop = try XCTUnwrap(ServiceActions.command(.stop, for: gateway))
        XCTAssertFalse(stop.root)
        XCTAssertTrue(stop.script.hasPrefix("systemctl --user stop 'hermes-gateway.service'"))
        XCTAssertEqual(ServiceActions.command(.logs, for: gateway)?.script, "journalctl --user -u 'hermes-gateway.service' -n 200 --no-pager")
        XCTAssertFalse(try XCTUnwrap(ServiceActions.command(.logs, for: tailscale)).isMutating)
        XCTAssertEqual(ServiceActions.followLogsCommand(for: gateway), "journalctl --user -u 'hermes-gateway.service' -f -n 100")
        XCTAssertTrue(ServiceActions.followLogsCommand(for: tailscale)?.contains("sudo journalctl -u 'tailscaled.service' -f") ?? false)

        // Processes started by hand have no actions.
        let paperclip = try service(s, "process/paperclipai")
        XCTAssertNil(ServiceActions.command(.restart, for: paperclip))
        XCTAssertNil(ServiceActions.followLogsCommand(for: paperclip))

        XCTAssertTrue(ServiceActions.isUnitName("systemd-fsck@dev-disk-by\\x2duuid-77ED.service"))
        XCTAssertFalse(ServiceActions.isUnitName("-x.service"))
        XCTAssertFalse(ServiceActions.isUnitName("a b.service"))
        XCTAssertFalse(ServiceActions.isUnitName("a;reboot.service"))
        XCTAssertFalse(ServiceActions.isUnitName("a'b.service"))
        XCTAssertFalse(ServiceActions.isUnitName("nginx"))
        var odd = tailscale
        odd.unit = "x$(reboot).service"
        XCTAssertNil(ServiceActions.command(.restart, for: odd))
    }

    func testActionsThatApply() throws {
        let s = try fixture("synthetic-root-failed")
        let failed = try service(s, "system/backup-sync.service"), running = try service(s, "system/nginx.service")
        XCTAssertTrue(ServiceAction.start.applies(to: failed))
        XCTAssertFalse(ServiceAction.stop.applies(to: failed))
        XCTAssertFalse(ServiceAction.start.applies(to: running))
        XCTAssertTrue(ServiceAction.restart.applies(to: running))
    }

    /// The restart command really does what it says through a shell, with a stub systemctl.
    func testRestartRunsThroughARealShell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("systemctl")
        try "#!/bin/sh\necho \"$@\" >> \"\(dir.path)/calls\"\ncase \"$*\" in *is-active*) echo active;; esac\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let s = try fixture("ubuntu-user-units-and-processes")
        let gateway = try service(s, "user/hermes-gateway.service")
        let script = try XCTUnwrap(ServiceActions.command(.restart, for: gateway)?.fullScript())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "PATH=\"\(dir.path):$PATH\"; " + script.replacingOccurrences(of: #"PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; "#, with: "")]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "Now: active\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8),
                       "--user restart hermes-gateway.service\n--user is-active hermes-gateway.service\n")
    }

    // MARK: icons

    func testServiceIcons() throws {
        let catalog = IconCatalog(names: ["tailscale", "wazuh", "beszel", "pi-hole", "hermes", "github", "nginx", "syncthing", "linux"])
        let s = try fixture("synthetic-root-failed")
        XCTAssertEqual(AppIconGuess.iconID(for: try service(s, "system/tailscaled.service"), in: catalog), "tailscale")
        XCTAssertEqual(AppIconGuess.iconID(for: try service(s, "system/pihole-FTL.service"), in: catalog), "pi-hole")
        XCTAssertEqual(AppIconGuess.iconID(for: try service(s, "system/nginx.service"), in: catalog), "nginx")
        XCTAssertNil(AppIconGuess.iconID(for: try service(s, "system/backup-sync.service"), in: catalog))
        XCTAssertNil(AppIconGuess.iconID(for: try service(s, "system/tailscaled.service"), in: nil))
        let real = try fixture("ubuntu-runner-host")
        XCTAssertEqual(AppIconGuess.iconID(for: try service(real, "system/beszel-agent.service"), in: catalog), "beszel")
        XCTAssertEqual(AppIconGuess.iconID(for: try service(real, "system/actions.runner.example-repo.runner1.service"), in: catalog), "github")
        XCTAssertNil(AppIconGuess.iconID(for: try service(real, "system/dbus.service"), in: catalog), "plumbing gets the letter")
    }

    func testSessionKeepsLastSnapshotOnFailure() async throws {
        let good = try String(contentsOf: specDir.appendingPathComponent("fixtures/services/synthetic-root-failed.out.txt"), encoding: .utf8)
        let transport = FakeTransport([.success(CommandResult(stdout: good)), .success(CommandResult(stdout: "", stderr: "Connection closed", exitCode: 255))])
        let session = ServicesSession(transport: transport)
        let first = await session.refresh()
        XCTAssertNotNil(first.snapshot)
        XCTAssertNil(first.error)
        let second = await session.refresh()
        XCTAssertEqual(second.snapshot, first.snapshot)
        XCTAssertEqual(second.error, "Connection closed")
        XCTAssertEqual(transport.commands.first, ServicesSession.command)
    }
}
