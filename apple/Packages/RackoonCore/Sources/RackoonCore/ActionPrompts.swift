import Foundation

/// What the confirmation sheet says about an action, and what the Output tab says while it runs.
public struct ActionPrompt: Sendable, Equatable {
    public var title: String
    public var message: String
    public var working: String
    /// Interrupts something that is running: the sheet's button is red and Return does not press it.
    public var destructive: Bool

    public init(title: String, message: String, working: String, destructive: Bool) {
        self.title = title
        self.message = message
        self.working = working
        self.destructive = destructive
    }
}

/// The words for every container and stack action, and the rules for when they are unavailable. The same as
/// `DockerModel` on the Mac (and `ActionPrompts` in the Kotlin core), so every app asks the same question the same way.
public enum ActionPrompts {
    /// Why the stack's compose actions are unavailable, or nil if they can run.
    public static func blockedReason(_ stack: DockerStack, readOnly: Bool, otherActionRunning: Bool) -> String? {
        if readOnly { return "Read-only mode is on" }
        if otherActionRunning { return "Another stack action is running" }
        if ComposeAction.up.command(for: stack) == nil {
            return stack.isStandalone ? "These containers were not started with Docker Compose"
                                      : "No single compose file was found for this stack"
        }
        return nil
    }

    /// Why a standalone container's actions (pull, restart, delete) are unavailable, or nil if they can run. Compose actions
    /// stay refused for it (`blockedReason`).
    public static func standaloneBlockedReason(_ stack: DockerStack, readOnly: Bool, otherActionRunning: Bool) -> String? {
        if readOnly { return "Read-only mode is on" }
        if otherActionRunning { return "Another stack action is running" }
        if StandaloneAction.remove(volumes: false).command(for: stack) == nil { return "This container can't be addressed safely" }
        return nil
    }

    /// The question before pulling a standalone container's image, or nil when it runs an image that can't be pulled.
    public static func pull(_ stack: DockerStack) -> ActionPrompt? {
        guard let image = StandaloneAction.pullableImage(of: stack) else { return nil }
        return ActionPrompt(
            title: "Pull the latest \(image)?",
            message: "Downloads a newer copy of the image \(stack.name) runs. The container is not touched and keeps running the image it has: it was started with docker run, so it only switches when it is created again with its original settings.",
            working: "Pulling \(image)…", destructive: false)
    }

    /// Stop and restart ask first; start runs straight away (it cannot break anything), so it has no prompt. Both stop and
    /// restart interrupt the container, so a tap on the red button, not Return, confirms them.
    public static func container(_ action: DockerAction, _ container: DockerContainer) -> ActionPrompt? {
        switch action {
        case .start:
            return nil
        case .stop:
            return ActionPrompt(title: "Stop \(container.name)?", message: "\(container.name) will stop until you start it again.",
                                working: "Stopping \(container.name)…", destructive: true)
        case .restart:
            return ActionPrompt(title: "Restart \(container.name)?",
                                message: "\(container.name) will be restarted. Connections to it drop for a moment.",
                                working: "Restarting \(container.name)…", destructive: true)
        }
    }

    public static func stack(_ action: ComposeAction, _ stack: DockerStack) -> ActionPrompt {
        let n = stack.containers.count
        let s = n == 1 ? "" : "s"
        switch action {
        case .pull:
            return ActionPrompt(
                title: "Pull images for \(stack.name)?",
                message: "Downloads newer images for the stack. Running containers are not touched; use Update afterwards to switch to them.",
                working: "Pulling images for \(stack.name)…", destructive: false)
        case .up:
            return ActionPrompt(
                title: "Update \(stack.name)?",
                message: "Recreates only the containers whose image or settings changed, and starts any that are stopped.",
                working: "Updating \(stack.name)…", destructive: false)
        case .restart:
            return ActionPrompt(
                title: "Restart all \(n) container\(s) in \(stack.name)?",
                message: "Restarts the containers in place. They are not recreated, so image and settings changes are not applied; use Update for that.",
                working: "Restarting \(stack.name)…", destructive: true)
        case .rebuild:
            return ActionPrompt(
                title: "Rebuild \(stack.name)?",
                message: "Rebuilds images from the stack's Dockerfiles (services with a build section), then recreates the containers that changed. Services that only use pulled images are left alone. Building can take a while.",
                working: "Rebuilding \(stack.name)…", destructive: false)
        case .recreate:
            return ActionPrompt(
                title: "Recreate all \(n) container\(s) in \(stack.name)?",
                message: "Every container is stopped and recreated from the compose file. Volumes are kept, but anything stored only inside a container is lost.",
                working: "Recreating \(stack.name)…", destructive: true)
        }
    }

    public static func rebuild(service: String, in stack: DockerStack) -> ActionPrompt {
        ActionPrompt(
            title: "Rebuild \(service)?",
            message: "Rebuilds the image for \(service) from its Dockerfile and recreates its container if the image changed. Other services in \(stack.name) are left alone. Building can take a while. If \(service) has no build section, nothing is rebuilt.",
            working: "Rebuilding \(service)…", destructive: false)
    }

    /// Whether the Rebuild button applies to this container: it needs a compose service the stack can address.
    public static func canRebuild(_ container: DockerContainer, in stack: DockerStack) -> Bool {
        container.service.map { ComposeAction.rebuild.command(for: stack, service: $0) != nil } ?? false
    }
}
