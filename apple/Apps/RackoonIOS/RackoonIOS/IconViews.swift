import PhotosUI
import RackoonCore
import SwiftUI
import UIKit

/// A tinted letter standing in for an icon, coloured from the name so an app keeps its colour (Core's `LetterTile`).
struct LetterTileView: View {
    let name: String
    var size: CGFloat = 26

    var body: some View {
        let hue = Double(LetterTile.hue(name)) / 360
        Text(LetterTile.letter(name))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color(hue: hue, saturation: 0.35, brightness: 0.9))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.28), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

private struct IconImage: View {
    let image: UIImage
    let size: CGFloat
    var body: some View {
        Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

extension AppModel {
    /// The address this device reaches a server on, for the site icon and link of an app's web port: its Tailscale address
    /// when it has one, else the address it uses to reach the internet.
    func webHost(for serverID: String) -> String? {
        let overview = fleet.state(for: serverID).overview
        return overview?.tailscaleIP ?? overview?.ipAddress
    }
}

/// A Docker app's icon: the chosen or guessed catalog icon, else its bookmark's site icon, else the site icon of the web page
/// it publishes, else a letter. The same order as the Mac.
struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let stack: DockerStack
    let serverID: String
    var size: CGFloat = 26

    var body: some View {
        let store = model.icons
        let name = store.stackIcon(stack, server: serverID)
        let letter = store.prefersLetter(stack, server: serverID)
        let site = letter ? nil : siteHref
        Group {
            if let name, let image = store.image(name) {
                IconImage(image: image, size: size)
            } else if name == nil, let site, let image = model.favicons.image(for: site) {
                IconImage(image: image, size: size)
            } else {
                LetterTileView(name: stack.name, size: size)
            }
        }
        .task(id: "\(name ?? "-")|\(store.catalog != nil)|\(site ?? "")") {
            store.ensureCatalog()
            if let name { store.ensure([name], urgent: true) }
            else if store.catalog != nil, let web = webHref, !letter { model.favicons.ensure([web]) }
        }
    }

    private var siteHref: String? {
        stack.containers.compactMap { $0.bookmark?.href }.first { model.favicons.image(for: $0) != nil } ?? webHref
    }

    private var webHref: String? {
        guard let host = model.webHost(for: serverID), let port = stack.mainWebPort else { return nil }
        return "http://\(host):\(port)"
    }
}

/// A service's icon: its own (chosen or guessed), else the app's.
struct ServiceIconView: View {
    @Environment(AppModel.self) private var model
    let container: DockerContainer
    let stack: DockerStack
    let serverID: String
    var size: CGFloat = 16

    var body: some View {
        let store = model.icons
        let name = store.serviceIcon(container, in: stack, server: serverID)
        Group {
            if let name, let image = store.image(name) {
                IconImage(image: image, size: size)
            } else {
                AppIconView(stack: stack, serverID: serverID, size: size)
            }
        }
        .task(id: name ?? "") { if let name { store.ensure([name], urgent: true) } }
    }
}

/// An icon that opens the picker when tapped: the app's icon, or one service's when `container` is set.
struct EditableIcon: View {
    let stack: DockerStack
    var container: DockerContainer?
    let serverID: String
    var size: CGFloat = 26
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Group {
                if let container {
                    ServiceIconView(container: container, stack: stack, serverID: serverID, size: size)
                } else {
                    AppIconView(stack: stack, serverID: serverID, size: size)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(container.map { "Icon of \(IconChoices.serviceKey($0)), change" } ?? "Icon of \(stack.name), change")
        .sheet(isPresented: $picking) {
            IconPicker(stack: stack, container: container, serverID: serverID, close: { picking = false })
        }
    }
}

/// A bookmark's site icon, else a bookmark glyph. Tapping it fetches a fresh one.
struct FaviconView: View {
    @Environment(AppModel.self) private var model
    let href: String
    var size: CGFloat = 22

    var body: some View {
        let store = model.favicons
        Button { store.refresh(href) } label: {
            ZStack {
                if store.isFetching(href) {
                    ProgressView().controlSize(.small)
                } else if let image = store.image(for: href) {
                    IconImage(image: image, size: size)
                } else {
                    Image(systemName: "bookmark.fill").font(.system(size: size * 0.6)).foregroundStyle(model.tokens.accent)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Site icon, fetch again")
        .task(id: href) { store.ensure([href]) }
    }
}

/// Search both icon collections and pick one, use an image of your own, or go back to the automatic choice.
struct IconPicker: View {
    @Environment(AppModel.self) private var model
    let stack: DockerStack
    let container: DockerContainer?
    let serverID: String
    let close: () -> Void
    @State private var query = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var importProblem: String?

    private var title: String { container.map(IconChoices.serviceKey) ?? stack.name }

    var body: some View {
        let store = model.icons
        let t = model.tokens
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if query.isEmpty, !store.customIcons.isEmpty {
                        section("Your images")
                        grid(store.customIcons)
                    }
                    if let catalog = store.catalog {
                        let ids = query.trimmingCharacters(in: .whitespaces).isEmpty ? suggestions(catalog) : catalog.search(query, limit: 60)
                        section(query.isEmpty ? "Suggested" : "Results")
                        if ids.isEmpty {
                            Text("No icons match. Use an image of your own below.").font(.footnote).foregroundStyle(t.muted)
                        } else {
                            grid(ids)
                        }
                    } else {
                        HStack(spacing: 8) { ProgressView(); Text("Loading the icon list…") }.font(.footnote).foregroundStyle(t.muted)
                    }
                    if let importProblem { Text(importProblem).font(.footnote).foregroundStyle(t.danger) }
                    VStack(spacing: 10) {
                        Button(automaticLabel) { store.choose(nil, for: stack, service: container, server: serverID); close() }
                            .disabled(!store.isChosen(stack, service: container, server: serverID))
                        Button(container == nil ? "Use Letter" : "Use App's Icon") {
                            store.choose("", for: stack, service: container, server: serverID); close()
                        }
                        let busy = importing
                        PhotosPicker(selection: $photo, matching: .images) {
                            if busy { ProgressView() } else { Label("Use a Photo…", systemImage: "photo") }
                        }
                        .disabled(importing)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    Text("Icons from dashboard-icons (Apache-2.0) and selfh.st (CC BY 4.0). Your choice and your images stay on this \(model.deviceName).")
                        .font(.caption).foregroundStyle(t.muted)
                }
                .padding(16)
            }
            .background(t.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search \(store.catalog.map { "\($0.count.formatted()) " } ?? "")icons")
            .navigationTitle("Icon for \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
            .onAppear { store.ensureCatalog() }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await use(item) }
            }
        }
    }

    private func section(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(model.tokens.muted)
    }

    private func grid(_ ids: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in cell(id) }
        }
    }

    private var automaticLabel: String {
        let store = model.icons
        let guess = container.map { store.guessedServiceIcon($0) } ?? store.guessedStackIcon(stack)
        guard let guess, let ref = AppIconRef(id: guess) else { return "Automatic" }
        if case .remote = ref { return "Automatic (Unraid template)" }
        return "Automatic (\(ref.displayName))"
    }

    /// The automatic icon first (an Unraid template icon included), then guesses from the names involved.
    private func suggestions(_ catalog: IconCatalog) -> [String] {
        let store = model.icons
        var out: [String] = []
        if let container, let guess = store.guessedServiceIcon(container) { out.append(guess) }
        if let guess = store.guessedStackIcon(stack) { out.append(guess) }
        out += stack.containers.compactMap { AppIconGuess.iconID(for: $0, in: catalog) }
        out += catalog.search(stack.name, limit: 10)
        if let container { out += catalog.search(IconChoices.serviceKey(container), limit: 10) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func use(_ item: PhotosPickerItem) async {
        importing = true
        importProblem = nil
        defer { importing = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let id = await model.icons.importImage(data) else {
            importProblem = "That image can't be read (or it is over 8 MB)."
            return
        }
        model.icons.choose(id, for: stack, service: container, server: serverID)
        close()
    }

    private func cell(_ id: String) -> some View {
        let store = model.icons
        let t = model.tokens
        let current = container.map { store.serviceIcon($0, in: stack, server: serverID) } ?? store.stackIcon(stack, server: serverID)
        let ref = AppIconRef(id: id)
        let isCustom: Bool = if case .custom = ref { true } else { false }
        return Button {
            store.choose(ref?.isChoosable == true ? id : nil, for: stack, service: container, server: serverID)
            close()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let image = store.image(id) {
                        IconImage(image: image, size: 38)
                    } else if store.queue.fetching.contains(id) {
                        ProgressView()
                    } else {
                        LetterTileView(name: ref?.displayName ?? id, size: 38)
                    }
                }
                .frame(width: 38, height: 38)
                Text(ref?.displayName ?? id).font(.caption2).lineLimit(1).truncationMode(.middle).foregroundStyle(t.secondary)
            }
            .frame(width: 68, height: 64)
            .background(current == id ? t.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ref?.displayName ?? id)
        .contextMenu {
            if isCustom { Button("Delete This Image", role: .destructive) { store.deleteCustom(id) } }
        }
        .task(id: id) { store.ensure([id], urgent: true) }
    }
}
