import AppKit
import SwiftUI

/// Borderless, non-activating panel that sits over the notch.
/// The window is a fixed size; the island shape animates inside it and
/// mouse events pass through everywhere except the island itself.
final class NotchPanel: NSPanel {
    init(model: IslandModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: IslandModel.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true // must come before `level`: it resets the level to .floating
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        animationBehavior = .none

        let root = IslandRootView().environment(model)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        contentView = host
    }

    // Don't let AppKit push us below the menu bar — we live inside it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button work even though our app never becomes active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
