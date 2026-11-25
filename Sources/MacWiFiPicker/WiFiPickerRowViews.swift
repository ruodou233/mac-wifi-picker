import AppKit

/// Every control in the panel takes the first click. An auto-shown panel sits in an
/// inactive app so it does not steal the keyboard, and a mouse click on it is still a
/// deliberate choice that must act at once rather than only activate the app.
@MainActor
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A menu-style text row, the footer of a Control Center module.
@MainActor
final class WiFiTextRow: NSControl {
    static let height: CGFloat = 24

    private let label = NSTextField(labelWithString: "")
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet {
            label.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
            needsDisplay = true
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        isEnabled && sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering, isEnabled else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// Rounded hover and keyboard highlight, no zebra stripes or borders. It stays out of hit
/// testing so the table sees every click, including the first click on an inactive panel.
@MainActor
final class WiFiNetworkRowView: NSTableRowView {
    /// False while a join is in flight: the other rows cannot be clicked, so they do not light up.
    var isInteractive = true {
        didSet { if isInteractive != oldValue { needsDisplay = true } }
    }

    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        // The list reloads under a resting mouse on every scan.
        if let window {
            isHovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private var highlightPath: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovering, isInteractive else { return }
        NSColor.quaternaryLabelColor.setFill()
        highlightPath.fill()
    }

    /// Only the arrow keys select now, a click joins, so this is the keyboard's cursor.
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        highlightPath.fill()
    }
}

/// The left of every row: signal bars in a disc, as in the system's Wi-Fi menu. The accent
/// disc means "current"; the bars are the only signal reading the panel shows.
@MainActor
final class WiFiSignalDisc: NSView {
    static let diameter: CGFloat = 24

    private let glyph = NSImageView()

    var isCurrent = false {
        didSet {
            glyph.contentTintColor = isCurrent ? .white : .labelColor
            needsDisplay = true
        }
    }

    var isDimmed = false {
        didSet {
            glyph.alphaValue = isDimmed ? 0.4 : 1
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.contentTintColor = .labelColor
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setSignal(_ value: Double) {
        glyph.image = NSImage(systemSymbolName: "wifi", variableValue: value, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
    }

    override func draw(_ dirtyRect: NSRect) {
        (isCurrent ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// An orange triangle and a phrase in secondary text: color goes on the icon, never the words.
@MainActor
final class WiFiNoticeLine: NSStackView {
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 4
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        icon.contentTintColor = .systemOrange
        icon.setAccessibilityElement(false)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(icon)
        addArrangedSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}

/// One network: signal disc, name, then a lock when there is a password to deal with. While
/// joining, a small spinner takes the lock's place; a failed join adds a line under the name.
@MainActor
final class WiFiNetworkCellView: NSTableCellView {
    static let height: CGFloat = 30
    static let noticeHeight: CGFloat = 18

    let disc = WiFiSignalDisc()
    let nameLabel = NSTextField(labelWithString: "")
    let lockImageView = NSImageView()
    let joinIndicator = NSProgressIndicator()
    let noticeLine = WiFiNoticeLine()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        lockImageView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        lockImageView.contentTintColor = .secondaryLabelColor
        lockImageView.setAccessibilityElement(false)

        joinIndicator.style = .spinning
        joinIndicator.controlSize = .small
        joinIndicator.isDisplayedWhenStopped = false

        noticeLine.isHidden = true

        for subview in [disc, nameLabel, lockImageView, joinIndicator, noticeLine] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        textField = nameLabel

        let firstLineCenter = Self.height / 2
        NSLayoutConstraint.activate([
            disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            disc.centerYAnchor.constraint(equalTo: topAnchor, constant: firstLineCenter),

            nameLabel.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: lockImageView.leadingAnchor, constant: -6),

            lockImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            lockImageView.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            lockImageView.widthAnchor.constraint(equalToConstant: 16),

            joinIndicator.centerXAnchor.constraint(equalTo: lockImageView.centerXAnchor),
            joinIndicator.centerYAnchor.constraint(equalTo: disc.centerYAnchor),

            noticeLine.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noticeLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            noticeLine.topAnchor.constraint(equalTo: topAnchor, constant: Self.height - 3)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A full-name tooltip is only there when the row had to shorten the name.
    override func layout() {
        super.layout()
        let isTruncated = nameLabel.attributedStringValue.size().width > nameLabel.bounds.width
        let wanted = isTruncated ? nameLabel.stringValue : nil
        if toolTip != wanted { toolTip = wanted }
    }
}

/// A click acts on the network under the mouse when it was pressed. The list can re-sort
/// between press and release, so the controller resolves both ends to a network identity.
@MainActor
final class WiFiNetworkTableView: NSTableView {
    var onRowPress: ((Int) -> Void)?
    var onRowRelease: ((Int) -> Void)?
    var onReturnKey: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onRowPress?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        onRowRelease?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturnKey?()
        default: super.keyDown(with: event)
        }
    }
}
