import AppKit

// Custom NSView components in the status bar menu (slider row / confirm row / button / endpoint dots /
// tracking slider). Moved out of StatusMenuController.swift on 2026-09-05: a pure move, zero behavior change.

private enum StatusMenuLayout {
    static let textInsetX: CGFloat = 28
    static let trailingInsetX: CGFloat = 14
}

/// Draft ledger for the system Dock slider. It remembers the value **before the change**, but only to decide
/// "did it actually change": which tier to roll back to on a failed write is decided by
/// `SettingsCoordinator.applyNativeDock` rereading the real system value itself (the starting point held by
/// the UI may have been changed by ⌥⌘D while the draft was pending, see the comment there).
///
/// The confirm row is the only commit source (the slider never writes to the system by itself), and the
/// **atomic** semantics of `consume()` are key: it serves as both gates, "no write if the value is unchanged"
/// and "no write without a starting point", and repeated calls always get nil.
struct PreferenceSliderCommitTracker {
    private var baseline: Double?
    private var pending: Double?

    var hasPending: Bool { pending != nil }

    /// Records the draft's starting point. Only the first call in an adjustment round counts; repeated calls
    /// midway do not overwrite it (it fires repeatedly during a drag).
    mutating func begin(currentDelay: Double) {
        if baseline == nil { baseline = currentDelay }
    }

    mutating func stage(_ value: Double) {
        pending = value
    }

    /// Atomically takes the value pending commit. No starting point, no change, or already consumed -> nil.
    mutating func consume() -> (previous: Double, target: Double)? {
        defer {
            baseline = nil
            pending = nil
        }
        guard let baseline, let pending, baseline != pending else { return nil }
        return (baseline, pending)
    }
}


@MainActor
final class PreferenceSliderMenuItemView: NSView {
    /// Every step change. Immediate-effect sliders (NitiaDock, local values) write the store right here.
    var onDelayChange: ((Double) -> Void)?
    /// The draft settled (mouse released, or each keyboard step). Confirm-type sliders use it to refresh the
    /// confirm row, and it **must never be used to write any persistent state**: the whole point of a draft
    /// is "not in effect yet".
    var onDraftChange: ((Double) -> Void)?
    /// Confirm and commit. **Setting it enables the draft mechanism**: every system Dock write ends with
    /// `killall Dock` and the screen always flashes, which may only happen after the user explicitly
    /// confirms.
    var onDelayCommit: ((_ target: Double) -> Void)?

    /// Color of the small label at the selected end: the accent color **with slight transparency**
    /// (2026-08-03). The solid dot stays at full strength and the label is one step weaker: the dot is the
    /// primary marker, the label its echo. Do not express this through font weight: bold changes the label
    /// width and makes the text at both ends jump sideways.
    static let activeEndpointColor = NSColor.controlAccentColor.withAlphaComponent(0.7)

    /// Color of the small label at the unselected end. **All four use sites must reference it** (one
    /// initialization each for left and right, plus one each in `updateDisplay`); with four separate
    /// literals, a missed one shows only when "dragging to an endpoint and back". Darkened one step from the
    /// tertiary label color to this on 2026-09-01 (the whole block looked too gray). The hollow stroke of the
    /// endpoint **dots** does not change with it: that is a shape, not text.
    static let inactiveEndpointColor = NSColor.secondaryLabelColor

    /// The user has moved the slider and not committed yet. Checked when rereading the real system value
    /// after the menu is shown: a hand that is dragging must not see the slider jump.
    var hasDraft: Bool { commitTracker.hasPending }

    private let accessibilityTitle: String
    private var delay = 0.0
    private var commitTracker = PreferenceSliderCommitTracker()
    private var displayString = "0.0s"
    private let leftEndpointDot = EndpointDotView()
    private let rightEndpointDot = EndpointDotView()
    private let delayLabel = NSTextField(labelWithString: "")
    // The endpoint labels are only 34pt wide (see sliderSideInset in layout()); they are scale marks, not
    // tier names: the full tier name is shown by the large middle line (delayLabel <- delayDisplayName),
    // which has ~190pt. English therefore uses short words: measured, "Always Visible" is 62.5pt at 9pt font
    // size and does not fit in 34pt.
    private let leftEndpointLabel = NSTextField(labelWithString: String(localized: "Always"))
    private let rightEndpointLabel = NSTextField(labelWithString: String(localized: "Never"))
    private let slider = MenuTrackingSlider()

    init(accessibilityTitle: String) {
        self.accessibilityTitle = accessibilityTitle
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        autoresizingMask = [.width]
        configureSubviews()
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        displayString
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let width = window?.frame.width, width > frame.width {
            frame.size.width = width
        }
    }

    func sync(delay: Double) {
        let index = AppSettingsStore.sliderIndexFromDelay(delay)
        self.delay = AppSettingsStore.delayFromSliderIndex(index)
        slider.integerValue = index
        updateDisplay()
    }

    private func configureSubviews() {
        wantsLayer = true

        leftEndpointDot.setAccessibilityElement(false)
        addSubview(leftEndpointDot)

        rightEndpointDot.setAccessibilityElement(false)
        addSubview(rightEndpointDot)

        delayLabel.font = .systemFont(ofSize: 11)
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.alignment = .center
        addSubview(delayLabel)

        leftEndpointLabel.font = .systemFont(ofSize: 9)
        leftEndpointLabel.textColor = Self.inactiveEndpointColor
        leftEndpointLabel.alignment = .center
        leftEndpointLabel.setAccessibilityElement(false)
        addSubview(leftEndpointLabel)

        rightEndpointLabel.font = .systemFont(ofSize: 9)
        rightEndpointLabel.textColor = Self.inactiveEndpointColor
        rightEndpointLabel.alignment = .center
        rightEndpointLabel.setAccessibilityElement(false)
        addSubview(rightEndpointLabel)

        slider.minValue = 0
        slider.maxValue = Double(AppSettingsStore.sliderIndexMax)
        slider.integerValue = AppSettingsStore.sliderIndexFromDelay(delay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackingStarted = { [weak self] in
            guard let self else { return }
            self.commitTracker.begin(currentDelay: self.delay)
        }
        slider.onTrackingEnded = { [weak self] in
            // The confirm row is not touched during a drag: adding/removing a menu item at every step would
            // relayout the whole menu repeatedly. It is refreshed once, on release.
            guard let self else { return }
            self.onDraftChange?(self.delay)
        }
        addSubview(slider)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = 8
        let contentX = StatusMenuLayout.textInsetX
        let contentWidth = bounds.width - contentX - StatusMenuLayout.trailingInsetX
        let labelY: CGFloat = 28
        let sliderY: CGFloat = 10

        let sliderSideInset: CGFloat = 34
        let sliderX = contentX + sliderSideInset
        let sliderWidth = max(0, contentWidth - sliderSideInset * 2)
        delayLabel.frame = NSRect(x: sliderX, y: labelY, width: sliderWidth, height: 14)

        let dotY = sliderY + 6
        leftEndpointDot.frame = NSRect(x: contentX + 14, y: dotY, width: dotSize, height: dotSize)
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 20)
        rightEndpointDot.frame = NSRect(x: slider.frame.maxX + 12, y: dotY, width: dotSize, height: dotSize)
        leftEndpointLabel.frame = NSRect(x: contentX, y: labelY, width: sliderSideInset, height: 14)
        rightEndpointLabel.frame = NSRect(x: slider.frame.maxX, y: labelY, width: sliderSideInset, height: 14)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), AppSettingsStore.sliderIndexMax)
        sender.integerValue = index
        let previousDelay = delay
        delay = AppSettingsStore.delayFromSliderIndex(index)
        updateDisplay()
        onDelayChange?(delay)

        guard onDelayCommit != nil else { return }
        // Keyboard / VoiceOver adjustments do not go through mouseDown and have no tracking start, so one is
        // added here (on the mouse path begin was already called by onTrackingStarted, and a repeated call
        // does not overwrite the starting point).
        commitTracker.begin(currentDelay: previousDelay)
        commitTracker.stage(delay)
        // Keyboard / VoiceOver have no "release" moment, so the confirm row can only be refreshed right away.
        // They therefore take the same confirm path as the mouse, no longer need a debounced auto-commit, and
        // so are no longer silently dropped.
        if !slider.isMouseTracking {
            onDraftChange?(delay)
        }
    }

    /// The user pressed the confirm row. The **only** commit entry: the slider itself never writes to the
    /// system under any circumstances.
    func commitDraft() {
        guard let commit = commitTracker.consume() else { return }
        onDelayCommit?(commit.target)
    }

    /// Discards an unconfirmed draft and moves the slider back to the effective value from before the draft
    /// began. Called **when the menu opens** (`menuWillOpen`), not when it closes; see there for the reason.
    /// If `commitDraft` already consumed it this gets nil, so a just-confirmed new value is not moved back.
    func discardDraft() {
        guard let discarded = commitTracker.consume() else { return }
        sync(delay: discarded.previous)
    }

    private func updateDisplay() {
        let index = slider.integerValue
        displayString = displayString(for: index)
        delay = AppSettingsStore.delayFromSliderIndex(index)
        delayLabel.stringValue = displayString
        // The small "always visible / never reveal" labels at both ends are always shown; when selected the
        // dot becomes solid and **the label takes the accent color too** (2026-08-03: the dot alone was not
        // obvious enough). **Color only, no bold**: bold would change this row's layout width and make the
        // end labels jump sideways. The middle value text is hidden when it reaches an endpoint, to avoid
        // showing the same word twice next to the always-visible end label.
        let isAtLeftEnd = index == 0
        let isAtRightEnd = index == AppSettingsStore.sliderIndexMax
        delayLabel.isHidden = isAtLeftEnd || isAtRightEnd
        leftEndpointDot.isOn = isAtLeftEnd
        rightEndpointDot.isOn = isAtRightEnd
        leftEndpointLabel.textColor = isAtLeftEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        rightEndpointLabel.textColor = isAtRightEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        setAccessibilityLabel("\(accessibilityTitle), \(displayString)")
        setAccessibilityValue(displayString)
        slider.displayString = displayString
    }

    /// Shares one tier definition with the confirm row, so what the confirm row says matches what the slider
    /// shows.
    private func displayString(for index: Int) -> String {
        AutoHideToggleMenuModel.delayDisplayName(sliderIndex: index)
    }
}

/// Confirm button row for the system Dock slider. Making it a **button** rather than a plain menu text row is
/// intentional: a menu row has the same visual weight as its neighbors, and a user who just dragged the
/// slider is still looking at it and easily misses the whole row; having missed it they close the menu, and
/// the result is "thought it was set, but it never took effect", worse than the flash itself. The button form
/// itself says "this is something to click".
///
/// The small gray sentence on the left is not decoration: the `killall Dock` flash cannot be removed, and
/// saying so up front keeps it from looking odd.
@MainActor
final class NativeDockApplyRowView: NSView {
    var onApply: (() -> Void)?

    private let hintLabel = NSTextField(labelWithString: String(localized: "The Dock will restart"))
    private let applyButton = MenuActionButton(title: String(localized: "Apply"))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 42))
        autoresizingMask = [.width]
        configureSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The button title is always "Apply"; the target tier is exposed only through accessibility: the slider
    /// already shows the tier, but VoiceOver users cannot hear the slider, so this sentence is their only
    /// source of information.
    func updateTarget(description: String) {
        applyButton.setAccessibilityLabel(description)
        setAccessibilityLabel(description)
    }

    /// Every appearance starts from the resting state: the previous round may have ended in the hover state,
    /// and the mouse is not necessarily still on the button when the menu reopens.
    func resetInteractionState() {
        applyButton.resetInteractionState()
    }

    private func configureSubviews() {
        wantsLayer = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.setAccessibilityElement(false)
        addSubview(hintLabel)

        applyButton.onClick = { [weak self] in
            self?.onApply?()
        }
        addSubview(applyButton)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let contentX = StatusMenuLayout.textInsetX
        let rightEdge = bounds.width - StatusMenuLayout.trailingInsetX

        let buttonSize = applyButton.intrinsicContentSize
        applyButton.frame = NSRect(
            x: rightEdge - buttonSize.width,
            y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )

        let hintWidth = max(0, applyButton.frame.minX - 8 - contentX)
        hintLabel.frame = NSRect(x: contentX, y: (bounds.height - 14) / 2, width: hintWidth, height: 14)
    }

}

/// Accent button in the menu, **self-drawn**.
///
/// `NSButton` was tried: once `bezelColor` changes the background to the accent color, AppKit's own pressed
/// darkening is mostly covered; and while a menu is open the run loop is in event-tracking mode, where a
/// standard button's hover / pressed states are unreliable, so pressing it feels like a dead image
/// (2026-08-02 report: "the button gives no feedback"). Self-drawn, all three states are fully controlled:
/// resting / hover (brighter) / pressed (darker).
final class MenuActionButton: NSView {
    var onClick: (() -> Void)?

    private let title: String
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 12
    private static let iconTitleGap: CGFloat = 5
    private static let height: CGFloat = 25

    /// Translucent rather than solid (decided 2026-08-02): the menu itself is a translucent material, and a
    /// solid accent-color block on top of it looks thick and heavy. A faint accent backing + accent-color
    /// text keeps the color and lowers the weight.
    private static let restingAlpha: CGFloat = 0.16
    private static let hoverAlpha: CGFloat = 0.30
    private static let pressedAlpha: CGFloat = 0.42

    init(title: String) {
        self.title = title
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: Self.height))
        wantsLayer = true

        // Regular font weight (decided 2026-08-02); the text uses the accent color itself rather than white:
        // white text needs a solid backing to hold up, and on a translucent backing only accent-color text is
        // clear enough.
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .controlAccentColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = .controlAccentColor
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let iconWidth = iconView.image?.size.width ?? 0
        return NSSize(
            width: Self.horizontalPadding * 2 + iconWidth + Self.iconTitleGap + titleWidth,
            height: Self.height
        )
    }

    /// A custom view in a menu does not belong to the key window; without this override the first click is
    /// swallowed entirely and the user thinks the button is broken. Same for `MenuTrackingSlider`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Subviews (text, icon) must not intercept mouse events, or the middle of the button cannot be clicked.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func resetInteractionState() {
        isHovering = false
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: the menu panel is not the key window, so `.activeInKeyWindow` never fires here.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// During menu event tracking `mouseUp` does not naturally come back here, so the view must run its own
    /// tracking loop, the same reason `MenuTrackingSlider` relies on `super.mouseDown` blocking until
    /// release. Meanwhile it tracks whether the pointer is inside the button: dragging out and releasing =
    /// cancel, matching system buttons.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        var releasedInside = true

        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { trackedEvent, stop in
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            let local = self.convert(trackedEvent.locationInWindow, from: nil)
            releasedInside = self.bounds.contains(local)
            self.isPressed = releasedInside
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
            }
        }

        isPressed = false
        isHovering = releasedInside
        if releasedInside {
            onClick?()
        }
    }

    /// Unit test entry: the real path is the tracking loop above, and a test environment cannot run an event
    /// loop.
    func performClickForTesting() {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The three states change only opacity, not hue: the backing is always the same accent color, and
        // pressing just makes it "more solid".
        let alpha: CGFloat
        if isPressed {
            alpha = Self.pressedAlpha
        } else if isHovering {
            alpha = Self.hoverAlpha
        } else {
            alpha = Self.restingAlpha
        }
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        shape.fill()
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        let titleSize = titleLabel.intrinsicContentSize
        let contentWidth = iconSize.width + Self.iconTitleGap + titleSize.width
        let startX = (bounds.width - contentWidth) / 2

        iconView.frame = NSRect(
            x: startX,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        titleLabel.frame = NSRect(
            x: iconView.frame.maxX + Self.iconTitleGap,
            y: (bounds.height - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )
    }
}

final class EndpointDotView: NSView {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(ovalIn: rect)
        (isOn ? NSColor.controlAccentColor : .clear).setFill()
        path.fill()
        (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

final class MenuTrackingSlider: NSSlider {
    var displayString = "0.0s"
    var onTrackingStarted: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    /// `mouseDown` does not return for the whole drag, so this flag is the exact answer to "is this a mouse
    /// drag right now", used to route the keyboard / Accessibility path to the debounced commit.
    private(set) var isMouseTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isMouseTracking = true
        onTrackingStarted?()
        super.mouseDown(with: event)
        isMouseTracking = false
        onTrackingEnded?()
    }

    override func accessibilityValue() -> Any? {
        displayString
    }
}
