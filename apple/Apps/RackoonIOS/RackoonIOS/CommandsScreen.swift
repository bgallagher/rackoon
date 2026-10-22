import RackoonCore
import SwiftUI
import UIKit

/// A library of handy commands for one server (spec/command-library.json, as on the Mac), plus a box for any command.
/// Reading commands run with live output; changes show their dry run, then ask with the exact command; root entries use
/// sudo (the password sheet, or the password saved behind Face ID); interactive ones open a terminal tab.
struct CommandsScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    /// A search result: open this command's page.
    var open: String?

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.commandsModel(for: server) {
            case .success(let commands):
                if let open, let command = CommandLibrary.all.first(where: { $0.id == open }) {
                    CommandDetailScreen(commands: commands, server: server, command: command)
                } else {
                    CommandsList(commands: commands, server: server)
                }
            case .failure(let reason):
                ContentUnavailableView("Commands can't run yet", systemImage: "command", description: Text(reason.message))
                    .navigationTitle("Commands")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private enum CommandRoute: Hashable { case library(String), custom }

private struct CommandsList: View {
    @Environment(AppModel.self) private var model
    let commands: CommandsModel
    let server: Server
    @State private var query = ""

    var body: some View {
        let t = model.tokens
        let groups = CommandLibrary.visibleGroups(matching: query)
        List {
            if query.isEmpty {
                Section {
                    NavigationLink {
                        destination(.custom)
                    } label: {
                        Label("Run a command…", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("customCommand")
                } footer: {
                    Text("Anything typed asks first, every time.")
                }
                .listRowBackground(t.card)
            }
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.commands) { command in
                        NavigationLink { destination(.library(command.id)) } label: { CommandRow(command: command, commands: commands) }
                            .accessibilityIdentifier("command-\(command.id)")
                    }
                }
                .listRowBackground(t.card)
            }
            if groups.isEmpty {
                Section { Text("No commands match.").foregroundStyle(t.secondary) }.listRowBackground(t.card)
            }
        }
        .themedList(t)
        .searchable(text: $query, prompt: "Commands")
        .navigationTitle("Commands")
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder private func destination(_ route: CommandRoute) -> some View {
        switch route {
        case .library(let id):
            if let command = CommandLibrary.all.first(where: { $0.id == id }) {
                CommandDetailScreen(commands: commands, server: server, command: command)
            }
        case .custom:
            CustomCommandScreen(commands: commands, server: server)
        }
    }
}

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: LibraryCommand
    let commands: CommandsModel

    var body: some View {
        let t = model.tokens
        let key = CommandsModel.Selection.library(command.id)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                Text(command.summary).font(.caption).foregroundStyle(t.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if commands.output(for: key)?.isRunning == true {
                ProgressView().controlSize(.small)
            } else if command.isMutating {
                Image(systemName: "exclamationmark.shield").foregroundStyle(t.warn).accessibilityLabel("Changes the server")
            } else if command.interactive {
                Image(systemName: "terminal").foregroundStyle(t.muted).accessibilityLabel("Opens a terminal")
            }
        }
    }
}

/// One library entry: what it does and runs, its parameters, Run, and its last output.
private struct CommandDetailScreen: View {
    @Environment(AppModel.self) private var model
    let commands: CommandsModel
    let server: Server
    let command: LibraryCommand

    var body: some View {
        let t = model.tokens
        let key = CommandsModel.Selection.library(command.id)
        let blocked = commands.blockedReason(for: command)
        VStack(spacing: 0) {
            List {
                Section {
                    Text(command.summary)
                    if let warning = command.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(t.warn)
                    }
                    if command.isMutating {
                        Text("Changes the server: its dry run is shown first, then it asks.").font(.caption).foregroundStyle(t.secondary)
                    }
                    if command.root {
                        Text("Runs as root with sudo; if sudo wants a password you are asked for it.").font(.caption).foregroundStyle(t.secondary)
                    }
                }
                .listRowBackground(t.card)
                if !command.params.isEmpty {
                    Section("Values") {
                        ForEach(command.params, id: \.id) { param in
                            ParamField(commands: commands, param: param)
                        }
                    }
                    .listRowBackground(t.card)
                }
                Section {
                    Button {
                        commands.selection = key
                        commands.run(command)
                    } label: {
                        HStack {
                            Label(command.interactive ? "Open in Terminal" : (command.isMutating ? "Run…" : "Run"),
                                  systemImage: command.interactive ? "terminal" : "play.fill")
                            Spacer()
                            if commands.isPreviewing(key) { ProgressView().controlSize(.small) }
                        }
                    }
                    .foregroundStyle(blocked == nil ? t.accent : t.muted)
                    .disabled(blocked != nil)
                    .accessibilityIdentifier("runCommand")
                } footer: {
                    if let blocked { Text(blocked) }
                }
                .listRowBackground(t.card)
                if let message = commands.message(for: key) {
                    Section { Label(message, systemImage: "info.circle.fill").foregroundStyle(t.secondary) }
                        .listRowBackground(t.card)
                }
                Section("What it runs") {
                    Text(command.readableScript(params: commands.params)).font(.caption.monospaced()).textSelection(.enabled)
                    if command.isMutating, let preview = command.preview {
                        DisclosureGroup("Dry run") {
                            Text(command.readableScript(preview, params: commands.params)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    DisclosureGroup("Exact script") {
                        Text(command.fullScript(params: commands.params) ?? "Fill in the values first.").font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            if let output = commands.output(for: key) {
                OutputPanel(output: output, cancel: { commands.cancelOutput(key) }, close: { commands.dismissOutput(key) })
                    .padding(.top, 8)
                    .frame(height: 320)
                    .background(t.background)
                    .contextMenu {
                        Button("Copy Output") { UIPasteboard.general.string = commands.outputText(key) }
                    }
            }
        }
        .background(t.background)
        .navigationTitle(command.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if commands.output(for: key) != nil {
                Button { UIPasteboard.general.string = commands.outputText(key) } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy output")
            }
        }
        .confirmAction(Binding(get: { commands.pending }, set: { commands.pending = $0 }))
        .sudoPassword(Binding(get: { commands.sudoRequest }, set: { commands.sudoRequest = $0 }))
        .navigationDestination(isPresented: Binding(get: { commands.openedTerminal }, set: { commands.openedTerminal = $0 })) {
            TerminalScreen(serverID: server.id)
        }
        .onAppear { commands.selection = key }
    }
}

/// A container or host name the command needs. Containers can be picked from the ones Docker listed.
private struct ParamField: View {
    @Environment(AppModel.self) private var model
    let commands: CommandsModel
    let param: LibraryParam
    @State private var text = ""

    var body: some View {
        let t = model.tokens
        HStack {
            TextField(param.placeholder.isEmpty ? param.label : param.placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onChange(of: text) { _, new in commands.params[param.id] = new }
            if param.kind == .container, !commands.knownContainers.isEmpty {
                Menu {
                    ForEach(commands.knownContainers, id: \.self) { name in Button(name) { text = name } }
                } label: {
                    Image(systemName: "list.bullet").foregroundStyle(t.accent)
                }
                .accessibilityLabel("Pick a container")
            }
        }
        .onAppear { text = commands.params[param.id] ?? "" }
        if !text.isEmpty, param.quoted(text) == nil {
            Text("Not a valid \(param.label.lowercased()).").font(.caption).foregroundStyle(t.danger)
        }
    }
}

/// Any command, typed. It always asks first (nothing can tell what it does) and is blocked in Read-only mode. The last
/// 20 are listed for this session only.
private struct CustomCommandScreen: View {
    @Environment(AppModel.self) private var model
    let commands: CommandsModel
    let server: Server
    @State private var text = ""

    var body: some View {
        let t = model.tokens
        let blocked = commands.customBlockedReason
        VStack(spacing: 0) {
            List {
                Section {
                    TextField("Command", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: text) { _, new in commands.customText = new }
                        .accessibilityIdentifier("customCommandText")
                    Button {
                        commands.selection = .custom
                        commands.runCustom()
                    } label: {
                        Label("Run…", systemImage: "play.fill")
                    }
                    .foregroundStyle(blocked == nil ? t.accent : t.muted)
                    .disabled(blocked != nil)
                } footer: {
                    Text(blocked ?? "Runs as \(server.user ?? "root") on \(server.name), with no input. It asks first.")
                }
                .listRowBackground(t.card)
                if let message = commands.message(for: .custom) {
                    Section { Label(message, systemImage: "info.circle.fill").foregroundStyle(t.secondary) }
                        .listRowBackground(t.card)
                }
                if !commands.history.items.isEmpty {
                    Section {
                        ForEach(commands.history.items, id: \.self) { item in
                            Button { text = item } label: { Text(item).font(.caption.monospaced()).lineLimit(2) }
                                .foregroundStyle(t.text)
                        }
                        Button("Clear", role: .destructive) { commands.clearHistory() }
                    } header: {
                        Text("This session")
                    } footer: {
                        Text("Kept in memory only, never saved: a command can hold a password or a token.")
                    }
                    .listRowBackground(t.card)
                }
            }
            .themedList(t)
            if let output = commands.output(for: .custom) {
                OutputPanel(output: output, cancel: { commands.cancelOutput(.custom) }, close: { commands.dismissOutput(.custom) })
                    .padding(.top, 8)
                    .frame(height: 320)
                    .background(t.background)
            }
        }
        .background(t.background)
        .navigationTitle("Run a Command")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .confirmAction(Binding(get: { commands.pending }, set: { commands.pending = $0 }))
        .onAppear {
            commands.selection = .custom
            text = commands.customText
        }
    }
}
