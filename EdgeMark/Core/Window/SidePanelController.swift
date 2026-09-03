import Cocoa
import OSLog
import SwiftUI

// MARK: - KeyableWindow

/// Custom NSWindow subclass that can become key and main (required for borderless windows).
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

// MARK: - SidePanelController

final class SidePanelController: NSWindowController {
    private let cornerRadius: CGFloat = 10
    private(set) var isShown = false
    private var isAnimating = false
    private var animationGeneration = 0
    private var hideTimer: Timer?
    private var dummyWindow: NSWindow?
    private var trackingArea: NSTrackingArea?
    private var previousApp: NSRunningApplication?
    /// Retained reference to the SwiftUI hosting view for layer updates.
    private var contentHostingView: NSView?
    /// Window-style resize layer: top edge, inner side edge, and their corner.
    private var resizeOverlay: PanelResizeOverlayView?
    /// True while the user is dragging a resize edge (moves during resize are not "moves").
    private var isUserResizing = false
    /// Frame of the floating toggle button window, if shown. Used for hit-testing so
    /// hovering/clicking the button never counts as "outside the panel".
    var floatingButtonFrameProvider: (() -> NSRect?)?
    let edgeDetector: EdgeDetector
    let noteStore = NoteStore()
    let appSettings = AppSettings.shared
    private let peekCoordinator = PeekCoordinator()

    // MARK: - Init

    init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth = ShortcutSettings.shared.panelWidth
        let side = ShortcutSettings.shared.edgeSide
        // First run: start at ~65% of the screen so the top edge is easy to grab.
        if !UserDefaults.standard.bool(forKey: "panelHeightSeeded") {
            UserDefaults.standard.set(true, forKey: "panelHeightSeeded")
            if ShortcutSettings.shared.panelHeight == nil {
                ShortcutSettings.shared.panelHeight = (visibleFrame.height * 0.65).rounded()
            }
        }
        let initialHeight = PanelGeometry.resolvedHeight(
            visibleFrame: visibleFrame,
            height: ShortcutSettings.shared.panelHeight,
            bottomInset: Self.bottomInset,
        )

        // Park the window far off-screen so it can't overlap any monitor.
        // Using a large negative coordinate is guaranteed to miss all monitor arrangements.
        let startX: CGFloat = -panelWidth - 1000

        let window = KeyableWindow(
            contentRect: NSRect(
                x: startX,
                y: visibleFrame.minY,
                width: panelWidth,
                height: initialHeight,
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Drag the panel anywhere by its header background. Buttons and scroll views opt
        // out via mouseDownCanMoveWindow, so controls stay fully interactive.
        window.isMovableByWindowBackground = true

        // Container view — sits between the window and the SwiftUI hosting view so we can
        // layer the resize handle on top without interfering with SwiftUI layout.
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight))

        // Host SwiftUI content — fills the container
        let hostingView = NSHostingView(
            rootView: ContentView()
                .environment(noteStore)
                .environment(appSettings)
                .environment(peekCoordinator)
                .environment(L10n.shared),
        )
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.maskedCorners = Self.maskedCorners(for: side)
        hostingView.layer?.masksToBounds = true
        containerView.addSubview(hostingView)

        // Resize layer — covers the container but only claims hits along the top edge,
        // the inner side edge, and their corner (diagonal). Everything else passes through.
        let overlay = PanelResizeOverlayView()
        overlay.side = side
        overlay.frame = containerView.bounds
        overlay.autoresizingMask = [.width, .height]
        containerView.addSubview(overlay)

        window.contentView = containerView

        edgeDetector = EdgeDetector()

        super.init(window: window)

        contentHostingView = hostingView
        resizeOverlay = overlay

        overlay.onDragBegan = { [weak self] in self?.isUserResizing = true }
        overlay.onDrag = { [weak self] frame in self?.panelDidResize(to: frame) }
        overlay.onDragEnded = { [weak self] in
            self?.isUserResizing = false
            self?.panelResizeEnded()
        }

        // Order the window off-screen immediately so it joins all Spaces.
        // We never orderOut — the window stays ordered (off-screen when hidden)
        // to maintain its .canJoinAllSpaces membership across desktop switches.
        window.orderBack(nil)
        // Start invisible and non-interactive. The parking position for a right-edge panel
        // on screen A lands inside an adjacent screen B's coordinate space — both alpha=0
        // (no visual ghost) and ignoresMouseEvents=true (no click swallowing) are needed.
        window.alphaValue = 0
        window.ignoresMouseEvents = true

        setupDummyWindow()
        setupTrackingArea()

        edgeDetector.onEdgeActivated = { [weak self] screen in
            self?.showPanel(on: screen)
        }
        edgeDetector.startMonitoring()

        // Click-outside dismissal
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, isShown, !self.isMouseInPanel(),
                  ShortcutSettings.shared.hideOnClickOutside,
                  !ShortcutSettings.shared.isPanelPinned else { return }
            hidePanel()
        }

        // Escape key dismissal
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.isShown == true {
                if let fr = self?.window?.firstResponder as? NSTextView, fr.isFieldEditor {
                    return event
                }
                // Create modal takes priority: close it instead of hiding the panel.
                if let store = self?.noteStore, store.isCreateModalPresented {
                    store.isCreateModalPresented = false
                    return nil
                }
                // Selection takes priority over panel-hide: clear it instead of hiding.
                if let store = self?.noteStore, !store.selection.isEmpty {
                    store.clearSelection()
                    return nil
                }
                self?.hidePanel()
            }
            return event
        }

        // List keyboard navigation: ↑ / ↓ / ⇧↑ / ⇧↓ / Return.
        // Runs before any SwiftUI .onKeyPress so it wins over default focus traversal.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown else { return event }
            // Skip while editing text or browsing the editor / trash.
            if let fr = window.firstResponder as? NSTextView, fr.isFieldEditor { return event }
            if noteStore.selectedNote != nil || noteStore.showTrash { return event }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 125: // ↓
                guard noteStore.moveSelection(direction: 1, extending: shift) else { return event }
                refreshPeekForSelection()
                return nil
            case 126: // ↑
                guard noteStore.moveSelection(direction: -1, extending: shift) else { return event }
                refreshPeekForSelection()
                return nil
            case 36, 76: // Return / numpad Enter
                return noteStore.openSelectedItem() ? nil : event
            case 49: // Space — Quick Look preview
                return handleSpacePeek() ? nil : event
            default:
                return event
            }
        }

        // Configurable local shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown else { return event }
            let s = ShortcutSettings.shared
            if s.searchShortcut?.matches(event) == true {
                // Trash overlay: pass through (navigateToHome while Trash is active leaves
                // pendingSearchOnHome stuck).
                if noteStore.showTrash { return event }
                // Note open: show the in-editor find bar instead of navigating to search.
                if noteStore.selectedNote != nil {
                    noteStore.pendingEditorFind = true
                    return nil
                }
                noteStore.searchReturnFolder = noteStore.selectedFolder
                noteStore.pendingSearchOnHome = true
                noteStore.navigateToHome()
                return nil
            }
            if s.pinShortcut?.matches(event) == true {
                s.isPanelPinned.toggle()
                return nil
            }
            if s.newNoteShortcut?.matches(event) == true {
                let note = noteStore.createNote(in: noteStore.selectedFolder?.name ?? "")
                noteStore.pendingRenameNote = note
                return nil
            }
            if s.newFolderShortcut?.matches(event) == true {
                // Only trigger when a list view is mounted. Editor and Trash both have
                // selectedNote == nil but no consumer, so pending would get stuck.
                guard noteStore.selectedNote == nil, !noteStore.showTrash else { return event }
                noteStore.pendingNewFolder = true
                return nil
            }
            return event
        }

        // Clear previousApp on desktop switch so we don't yank the user back
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
        )

        // Update previousApp when user switches apps while panel is shown
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )

        // Listen for settings changes (e.g. edge side) to reconfigure the panel
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .shortcutSettingsChanged,
            object: nil,
        )

        // Listen for pin state changes to toggle window draggability
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePinStateChanged),
            name: .panelPinStateChanged,
            object: nil,
        )

        // Panel height / floating button inset changed from Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelSizeChanged),
            name: .panelSizeChanged,
            object: nil,
        )

        // User dragged the panel — remember where it landed (or dock it if near the edge)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowMoved),
            name: NSWindow.didMoveNotification,
            object: window,
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDockRequested),
            name: .panelDockRequested,
            object: nil,
        )
    }

    // MARK: - Move

    /// How close (pt) the panel's outer edge must be to the screen edge to auto-dock.
    private let dockSnapDistance: CGFloat = 28

    @objc private func handleWindowMoved() {
        guard let window, isShown, !isAnimating, !isUserResizing else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        let side = ShortcutSettings.shared.edgeSide
        let dockedFrames = PanelGeometry.frames(
            visibleFrame: vf, side: side == .right ? .right : .left,
            width: window.frame.width, height: ShortcutSettings.shared.panelHeight, bottomInset: Self.bottomInset,
        )
        let outerDistance = switch side {
        case .right: abs(vf.maxX - window.frame.maxX)
        case .left: abs(window.frame.minX - vf.minX)
        }
        if outerDistance <= dockSnapDistance, window.frame == dockedFrames.shown || abs(window.frame.minY - dockedFrames.shown.minY) <= dockSnapDistance {
            if ShortcutSettings.shared.panelOrigin != nil || window.frame != dockedFrames.shown {
                ShortcutSettings.shared.panelOrigin = nil
                if window.frame != dockedFrames.shown {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        window.animator().setFrame(dockedFrames.shown, display: true)
                    }
                }
                Log.window.info("[SidePanelController] docked to edge")
            }
        } else {
            ShortcutSettings.shared.panelOrigin = window.frame.origin
        }
    }

    @objc private func handleDockRequested() {
        ShortcutSettings.shared.panelOrigin = nil
        handlePanelSizeChanged()
    }

    /// Height reserved below the panel for the floating toggle button.
    static var bottomInset: CGFloat {
        ShortcutSettings.shared.floatingButtonEnabled ? FloatingButtonController.reservedHeight : 0
    }

    // MARK: - Panel Size Change

    @objc private func handlePanelSizeChanged() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let side = ShortcutSettings.shared.edgeSide
        let (shownFrame, _) = panelFrames(visibleFrame: screen.visibleFrame, side: side)
        if isShown, !isAnimating {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(shownFrame, display: true)
            }
        } else if !isShown {
            window.setFrame(parkedFrame(panelWidth: shownFrame.width), display: false)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Settings Change

    @objc private func handleSettingsChanged() {
        guard let window, let containerView = window.contentView else { return }

        // Update corner radius for new edge side
        let side = ShortcutSettings.shared.edgeSide
        Log.window.info("[SidePanelController] settings changed — edge: \(side.rawValue, privacy: .public)")
        contentHostingView?.layer?.maskedCorners = Self.maskedCorners(for: side)

        // Flip the resize zones to the new inner edge
        let panelWidth = ShortcutSettings.shared.panelWidth
        resizeOverlay?.side = side
        _ = containerView

        // If panel is visible, hide it — user re-triggers to see it on the new edge
        peekCoordinator.dismissNow()
        if isShown {
            hidePanel()
        } else {
            // Reposition to safe parked location (edge may have changed so old position is stale)
            window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
        }
    }

    // MARK: - Pin State Change

    @objc private func handlePinStateChanged() {
        guard let window else { return }
        _ = window
        _ = ShortcutSettings.shared.isPanelPinned
    }

    /// Animate the panel back to its configured edge position after unpinning.
    /// If the panel is already at the edge frame, skips the animation.
    private func snapToEdge() {
        guard let window, isShown else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let side = ShortcutSettings.shared.edgeSide
        let (edgeFrame, _) = panelFrames(visibleFrame: screen.visibleFrame, side: side)

        // Already at the edge — nothing to animate
        guard window.frame != edgeFrame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            window.setFrame(edgeFrame, display: true)
            contentHostingView?.layer?.maskedCorners = Self.maskedCorners(for: side)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Space Change

    @objc private func handleSpaceChange() {
        Log.window.debug("[SidePanelController] space changed")
        // Clear previousApp so hidePanel() doesn't activate an app on a
        // different Space and yank the user back.
        previousApp = nil

        // If the panel is shown and the mouse is outside, restart the auto-hide
        // timer with a short delay so the animation plays after the Space
        // transition settles (animations don't render mid-transition).
        guard isShown, !ShortcutSettings.shared.isPanelPinned else { return }
        cancelHideTimer()
        if !isMouseInPanel() {
            let delay = max(ShortcutSettings.shared.hideDelay, 0.5)
            startHideTimer(delay: delay)
        }
    }

    // MARK: - App Activation

    @objc private func handleAppActivation(_ notification: Notification) {
        guard isShown else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        let name = app.localizedName ?? "unknown"
        Log.window.debug(
            "[SidePanelController] app activated while panel shown — updating previousApp to \(name, privacy: .public)",
        )
        previousApp = app
    }

    // MARK: - Dummy Window

    /// A 1×1 invisible window used as a focus chain anchor so the panel can resign
    /// key status without the system sending focus to a random window.
    private func setupDummyWindow() {
        let dummy = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        dummy.isOpaque = false
        dummy.backgroundColor = .clear
        dummy.alphaValue = 0
        dummy.ignoresMouseEvents = true
        dummy.level = .floating
        dummy.collectionBehavior = [.stationary, .ignoresCycle]
        dummy.orderBack(nil)
        dummyWindow = dummy
    }

    // MARK: - Tracking Area (auto-hide)

    private func setupTrackingArea() {
        guard let contentView = window?.contentView else { return }
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        contentView.addTrackingArea(trackingArea!)
    }

    override func mouseExited(with _: NSEvent) {
        guard isShown, !isAnimating, !isEditorFocused,
              ShortcutSettings.shared.autoHideOnMouseExit,
              !ShortcutSettings.shared.isPanelPinned else { return }
        let delay = ShortcutSettings.shared.hideDelay
        if delay == 0 {
            hidePanel()
        } else {
            Log.window.debug("[SidePanelController] mouseExited — hide timer (\(delay)s)")
            startHideTimer(delay: delay)
        }
    }

    override func mouseEntered(with _: NSEvent) {
        cancelHideTimer()
    }

    // MARK: - Show / Hide

    func showPanel(on screen: NSScreen? = nil) {
        guard let window, !isShown else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = targetScreen.visibleFrame
        let side = ShortcutSettings.shared.edgeSide
        Log.window.info("[SidePanelController] showPanel (\(side.rawValue, privacy: .public) edge)")

        // Check for external file changes every time the panel becomes visible
        noteStore.checkForExternalChanges()

        isShown = true
        NotificationCenter.default.post(name: .panelVisibilityChanged, object: nil, userInfo: ["shown": true])
        let gen = animationGeneration &+ 1
        animationGeneration = gen

        let (shownFrame, _) = panelFrames(visibleFrame: visibleFrame, side: side)

        // Save the frontmost app so we can restore focus when hiding
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        if isAnimating {
            // Interrupt hide animation — snap to shown position instantly
            Log.window.debug("[SidePanelController] showPanel interrupted hide animation")
            isAnimating = false
            peekCoordinator.suppressPeek = false
            window.setFrame(shownFrame, display: true)
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            isAnimating = true
            peekCoordinator.suppressPeek = true
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)

            if Self.effectiveAnimationStyle == .slide {
                // Slide: teleport to the off-screen start position, then animate the frame inward.
                // Note: on multi-monitor setups the start position may overlap the adjacent display,
                // causing a brief ghost during the 0.2s travel. Use Fade in Settings to avoid this.
                let (_, startFrame) = panelFrames(visibleFrame: visibleFrame, side: side)
                window.setFrame(startFrame, display: true)
                window.alphaValue = 1

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().setFrame(shownFrame, display: false)
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    isAnimating = false
                    peekCoordinator.suppressPeek = false
                }
            } else {
                // Fade: position at the final frame while invisible, then animate alpha 0 → 1.
                // The window never moves off the triggering screen — no adjacent monitor bleed.
                window.setFrame(shownFrame, display: true)
                window.alphaValue = 0

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    isAnimating = false
                    peekCoordinator.suppressPeek = false
                }
            }

            // Activate after animation is submitted to Core Animation
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hidePanel() {
        guard let window, isShown else { return }
        Log.window.info("[SidePanelController] hidePanel")
        noteStore.saveDirtyNotes()
        peekCoordinator.dismissNow()
        isShown = false
        NotificationCenter.default.post(name: .panelVisibilityChanged, object: nil, userInfo: ["shown": false])
        let gen = animationGeneration &+ 1
        animationGeneration = gen
        cancelHideTimer()
        edgeDetector.pauseDetection()

        let panelWidth = window.frame.width
        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = targetScreen.visibleFrame
        let side = ShortcutSettings.shared.edgeSide
        let (_, hiddenFrame) = panelFrames(visibleFrame: visibleFrame, side: side)

        if isAnimating {
            // Interrupt show animation — snap to parked position instantly
            Log.window.debug("[SidePanelController] hidePanel interrupted show animation")
            isAnimating = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
            restorePreviousApp()
            edgeDetector.resumeDetection()
        } else {
            isAnimating = true
            window.ignoresMouseEvents = true

            if Self.effectiveAnimationStyle == .slide {
                // Slide out, then park far off-screen so the invisible window can't block clicks.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().setFrame(hiddenFrame, display: false)
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    window.alphaValue = 0
                    window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
                    isAnimating = false
                    restorePreviousApp()
                    edgeDetector.resumeDetection()
                }
            } else {
                // Fade out in place, then park. Window never moves off the current screen.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
                    isAnimating = false
                    restorePreviousApp()
                    edgeDetector.resumeDetection()
                }
            }
        }
    }

    func togglePanel() {
        let state = isShown ? "shown" : "hidden"
        Log.window.debug("[SidePanelController] togglePanel (currently \(state, privacy: .public))")
        if isShown {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Resize

    /// Live drag from the resize layer: clamp the proposed frame and apply it.
    private func panelDidResize(to proposed: NSRect) {
        guard let window else { return }
        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let vf = targetScreen.visibleFrame
        var frame = proposed
        // Width: keep between min and screen width; keep the anchored edge in place.
        let w = min(max(frame.width, PanelGeometry.minWidth), vf.width - 100)
        if frame.width != w {
            if frame.minX != window.frame.minX { frame.origin.x = frame.maxX - w } // inner edge on the left moved
            frame.size.width = w
        }
        // Height: never below the minimum, never past the top of the screen or below its bottom.
        let h = min(max(frame.height, PanelGeometry.minHeight), vf.maxY - max(frame.minY, vf.minY))
        if frame.height != h {
            if frame.minY != window.frame.minY { frame.origin.y = frame.maxY - h } // bottom edge moved
            frame.size.height = h
        }
        frame.origin.y = max(frame.origin.y, vf.minY)
        window.setFrame(frame, display: true)
    }

    /// Persist width, height, and (for a free-floating panel) origin after a drag ends.
    private func panelResizeEnded() {
        guard let window else { return }
        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let settings = ShortcutSettings.shared
        settings.panelWidth = window.frame.width
        if settings.panelOrigin != nil {
            settings.panelOrigin = window.frame.origin
            settings.panelHeight = window.frame.height + Self.bottomInset
        } else {
            let docked = PanelGeometry.frames(
                visibleFrame: targetScreen.visibleFrame, side: settings.edgeSide == .right ? .right : .left,
                width: window.frame.width, height: settings.panelHeight, bottomInset: Self.bottomInset,
            ).shown
            if abs(window.frame.minY - docked.minY) > 1 {
                // Bottom edge was dragged while docked — the panel is now free-floating.
                settings.panelOrigin = window.frame.origin
                settings.panelHeight = window.frame.height + Self.bottomInset
            } else {
                settings.panelHeight = PanelGeometry.storedHeightAfterDrag(
                    frameTop: window.frame.maxY,
                    frameHeight: window.frame.height,
                    visibleFrame: targetScreen.visibleFrame,
                    bottomInset: Self.bottomInset,
                )
            }
        }
        Log.window.info("[SidePanelController] panel resized to \(window.frame.width, privacy: .public)×\(window.frame.height, privacy: .public)")
    }

    // MARK: - Frame Calculation

    /// A safe off-screen parking position that can't overlap any monitor in any arrangement.
    /// The window is invisible (alphaValue = 0) and ignoresMouseEvents when parked here.
    private func parkedFrame(panelWidth: CGFloat) -> NSRect {
        let height = window?.frame.height ?? 100
        return NSRect(x: -panelWidth - 1000, y: -10000, width: panelWidth, height: height)
    }

    /// Slide animations only make sense from a docked edge; a free-floating panel fades.
    private static var effectiveAnimationStyle: AnimationStyle {
        ShortcutSettings.shared.panelOrigin == nil ? ShortcutSettings.shared.animationStyle : .fade
    }

    /// Returns (shown, hidden) frames. Docked: computed from the edge. Free-floating: the
    /// remembered origin, clamped so the whole panel stays on the screen that contains it.
    private func panelFrames(visibleFrame: NSRect, side: EdgeSide) -> (shown: NSRect, hidden: NSRect) {
        let width = ShortcutSettings.shared.panelWidth
        if let origin = ShortcutSettings.shared.panelOrigin {
            let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? visibleFrame
            let height = PanelGeometry.resolvedHeight(visibleFrame: vf, height: ShortcutSettings.shared.panelHeight, bottomInset: Self.bottomInset)
            var frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
            frame.origin.x = min(max(frame.origin.x, vf.minX), vf.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, vf.minY), vf.maxY - frame.height)
            return (frame, frame)
        }
        let frames = PanelGeometry.frames(
            visibleFrame: visibleFrame,
            side: side == .right ? .right : .left,
            width: width,
            height: ShortcutSettings.shared.panelHeight,
            bottomInset: Self.bottomInset,
        )
        return (frames.shown, frames.hidden)
    }

    /// Corner mask for the given edge side.
    private static func maskedCorners(for side: EdgeSide) -> CACornerMask {
        switch side {
        case .right:
            // Right edge → round left corners
            [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .left:
            // Left edge → round right corners
            [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    // MARK: - Helpers

    /// Reactivate the app that was frontmost before the panel appeared,
    /// so its mouse events go through the global monitor again.
    /// Skips restoration if another EdgeMark window (e.g. Settings, Update) is key.
    private func restorePreviousApp() {
        let hasOtherKeyWindow = NSApp.windows.contains { $0 !== window && $0.isKeyWindow }
        if !hasOtherKeyWindow {
            if let app = previousApp {
                let name = app.localizedName ?? "unknown"
                Log.window.debug("[SidePanelController] restoring focus to \(name, privacy: .public)")
            } else {
                Log.window.debug("[SidePanelController] no previousApp to restore")
            }
            previousApp?.activate()
        }
        previousApp = nil
    }

    private func isMouseInPanel() -> Bool {
        guard let window else { return false }
        let cursor = NSEvent.mouseLocation
        // 1. Inside the panel window itself
        if window.frame.contains(cursor) { return true }
        // 2. Inside the peek preview window
        if let peekFrame = peekCoordinator.peekWindowFrame, peekFrame.contains(cursor) { return true }
        // 3. Inside the 12pt gap strip between the panel and the preview
        let gap = PeekWindowController.gap
        let side = ShortcutSettings.shared.edgeSide
        let gapStrip = switch side {
        case .right:
            NSRect(x: window.frame.minX - gap, y: window.frame.minY,
                   width: gap, height: window.frame.height)
        case .left:
            NSRect(x: window.frame.maxX, y: window.frame.minY,
                   width: gap, height: window.frame.height)
        }
        if gapStrip.contains(cursor) { return true }
        // 4. Over the floating toggle button
        if let buttonFrame = floatingButtonFrameProvider?(), buttonFrame.contains(cursor) { return true }
        return false
    }

    private func startHideTimer(delay: Double) {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, isShown, !isMouseInPanel() else { return }
            hidePanel()
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// Whether an NSTextView in the panel is the first responder (user is editing).
    private var isEditorFocused: Bool {
        window?.firstResponder is NSTextView
    }

    /// Handle Space-to-preview (Quick Look). Returns true if the event was consumed.
    private func handleSpacePeek() -> Bool {
        guard AppSettings.shared.spaceToPreviewEnabled, !peekCoordinator.suppressPeek else { return false }
        guard noteStore.pendingEditorFind == false else { return false }
        guard noteStore.selection.count == 1 else { return false }
        guard let win = window else { return false }
        let panelFrame = win.convertToScreen(win.contentView?.bounds ?? win.frame)

        let item = noteStore.selection.first!
        let content: PeekContent
        switch item {
        case let .folder(name):
            guard let folder = noteStore.folders.first(where: { $0.name == name }) else { return false }
            content = .folder(folder, noteStore.subfolders(of: folder), noteStore.recentNotes(in: folder))
        case let .note(id):
            guard let note = noteStore.notes.first(where: { $0.id == id }) else { return false }
            content = .note(note)
        }
        peekCoordinator.triggerPeek(content: content, panelFrame: panelFrame)
        return true
    }

    /// If the peek preview was keyboard-triggered and showing, update its
    /// content to match the new selection after arrow-key navigation.
    private func refreshPeekForSelection() {
        guard peekCoordinator.isKeyboardTriggered else { return }
        guard noteStore.selection.count == 1 else { return }
        let item = noteStore.selection.first!
        let content: PeekContent
        switch item {
        case let .folder(name):
            guard let folder = noteStore.folders.first(where: { $0.name == name }) else { return }
            content = .folder(folder, noteStore.subfolders(of: folder), noteStore.recentNotes(in: folder))
        case let .note(id):
            guard let note = noteStore.notes.first(where: { $0.id == id }) else { return }
            content = .note(note)
        }
        peekCoordinator.updateForSelectionChange(content: content)
    }
}

// MARK: - PanelResizeOverlayView

/// Transparent layer over the panel that behaves like a window's resize border.
/// Grab zones: top edge, bottom edge, inner side edge, and the corners where they meet.
/// Points outside the zones are not hit-tested, so clicks fall through to SwiftUI.
private final class PanelResizeOverlayView: NSView {
    struct Zone: OptionSet {
        let rawValue: Int
        static let top = Zone(rawValue: 1)
        static let bottom = Zone(rawValue: 2)
        static let side = Zone(rawValue: 4)
    }

    var side: EdgeSide = .right
    var onDragBegan: (() -> Void)?
    /// Proposed new window frame (screen coordinates) during a drag.
    var onDrag: ((NSRect) -> Void)?
    var onDragEnded: (() -> Void)?

    /// Visible card insets from PageLayout: 12pt horizontal, 8pt top, 12pt bottom.
    private let cardInsetX: CGFloat = 12
    private let cardInsetTop: CGFloat = 8
    private let cardInsetBottom: CGFloat = 12
    /// Grab band extends this far on each side of the visible card edge.
    private let grab: CGFloat = 7

    private var activeZone: Zone = []
    private var dragStart = NSPoint.zero
    private var startFrame = NSRect.zero

    func zone(at point: NSPoint) -> Zone {
        let topEdge = bounds.height - cardInsetTop
        let bottomEdge = cardInsetBottom
        let innerEdge: CGFloat = switch side {
        case .right: cardInsetX
        case .left: bounds.width - cardInsetX
        }
        // Distance "beyond" an edge counts as on it, so the transparent margin is grabbable too.
        let dTop = point.y > topEdge ? 0 : topEdge - point.y
        let dBottom = point.y < bottomEdge ? 0 : point.y - bottomEdge
        let dSide: CGFloat = switch side {
        case .right: point.x < innerEdge ? 0 : point.x - innerEdge
        case .left: point.x > innerEdge ? 0 : innerEdge - point.x
        }
        var z: Zone = []
        let wide = grab * 2
        if dTop <= grab || (dTop <= wide && dSide <= wide) { z.insert(.top) }
        if dBottom <= grab || (dBottom <= wide && dSide <= wide) { z.insert(.bottom) }
        if dSide <= grab || (dSide <= wide && (dTop <= wide || dBottom <= wide)) { z.insert(.side) }
        if z.contains(.top), z.contains(.bottom) { z.remove(.bottom) } // tiny panels: prefer top
        return z
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return zone(at: local).isEmpty ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        activeZone = zone(at: convert(event.locationInWindow, from: nil))
        guard !activeZone.isEmpty else { return }
        dragStart = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        onDragBegan?()
    }

    override func mouseDragged(with _: NSEvent) {
        guard !activeZone.isEmpty else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = now.y - dragStart.y
        var f = startFrame
        if activeZone.contains(.side) {
            switch side {
            case .right: // inner edge is the left edge
                f.origin.x = startFrame.minX + dx
                f.size.width = startFrame.width - dx
            case .left: // inner edge is the right edge
                f.size.width = startFrame.width + dx
            }
        }
        if activeZone.contains(.top) {
            f.size.height = startFrame.height + dy
        }
        if activeZone.contains(.bottom) {
            f.origin.y = startFrame.minY + dy
            f.size.height = startFrame.height - dy
        }
        onDrag?(f)
    }

    override func mouseUp(with _: NSEvent) {
        guard !activeZone.isEmpty else { return }
        activeZone = []
        onDragEnded?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(for: event)
    }

    private func applyCursor(for event: NSEvent) {
        let z = activeZone.isEmpty ? zone(at: convert(event.locationInWindow, from: nil)) : activeZone
        let innerIsLeft = side == .right
        let position: NSCursor.FrameResizePosition? = switch z {
        case [.top, .side]: innerIsLeft ? .topLeft : .topRight
        case [.bottom, .side]: innerIsLeft ? .bottomLeft : .bottomRight
        case [.top]: .top
        case [.bottom]: .bottom
        case [.side]: innerIsLeft ? .left : .right
        default: nil
        }
        if let position {
            NSCursor.frameResize(position: position, directions: .all).set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
