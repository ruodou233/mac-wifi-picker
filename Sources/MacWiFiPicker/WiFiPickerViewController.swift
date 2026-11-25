import AppKit
import Foundation

/// The panel keeps to one question for everything on it: does the user decide or do something
/// with this? Signal shows as bars, never as a number, and the list stays strictly strongest first.
@MainActor
public final class WiFiPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Layout {
        static let width: CGFloat = 340
        static let inset: CGFloat = 14
        static let headerHeight: CGFloat = 32
        static let separatorGap: CGFloat = 5
        static let bottomPadding: CGFloat = 6
        static let pagePadding: CGFloat = 12
        static let placeholderHeight: CGFloat = 88
        static let formButtonWidth: CGFloat = 76
    }

    public var onRequestClose: (@MainActor () -> Void)?
    /// The host sets this to 60% of the screen's usable height.
    public var maximumPanelHeight: CGFloat = 600 {
        didSet { updatePanelSize() }
    }
    /// Everything that leaves the panel for System Settings goes through here.
    public var openSystemURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    private let controller: WiFiPickerController
    private let headerLabel = NSTextField(labelWithString: "Wi‑Fi")
    private let pageContainer = NSView()
    private let listPageView = NSView()
    private let credentialsPageView = NSView()
    private let hiddenCredentialsPageView = NSView()
    private let permissionPageView = NSView()
    private let tableView = WiFiNetworkTableView()
    private let listScrollView = NSScrollView()
    private var listHeightConstraint: NSLayoutConstraint!
    private let placeholderView = NSStackView()
    private let placeholderTitleLabel = NSTextField(labelWithString: "")
    private let placeholderButton = FirstClickButton(title: "", target: nil, action: nil)
    private let loginNoticeView = NSStackView()
    private let loginNoticeLine = WiFiNoticeLine()
    private let loginNoticeButton = FirstClickButton(title: "打开登录项设置…", target: nil, action: nil)
    private let joinOtherRow = WiFiTextRow(title: "加入其他网络…")
    private let settingsRow = WiFiTextRow(title: "Wi‑Fi设置…")
    private let credentialsStack = NSStackView()
    private let passwordField = NSSecureTextField()
    private let credentialsNoticeLine = WiFiNoticeLine()
    private let credentialsIndicator = NSProgressIndicator()
    private let credentialsCancelButton = FirstClickButton(title: "取消", target: nil, action: nil)
    private let credentialsJoinButton = FirstClickButton(title: "加入", target: nil, action: nil)
    private let hiddenStack = NSStackView()
    private let hiddenSSIDField = NSTextField()
    private let hiddenPasswordField = NSSecureTextField()
    private let hiddenNoticeLine = WiFiNoticeLine()
    private let hiddenIndicator = NSProgressIndicator()
    private let hiddenCancelButton = FirstClickButton(title: "取消", target: nil, action: nil)
    private let hiddenJoinButton = FirstClickButton(title: "加入", target: nil, action: nil)
    private let permissionStack = NSStackView()
    private let permissionMessageLabel = NSTextField(labelWithString: WiFiPermissionAction.message)
    private let permissionButton = FirstClickButton(title: "", target: nil, action: nil)
    private var rows: [WiFiNetworkChoice] = []
    private var selectedNetworkID: String?
    private var pressedNetworkID: String?
    private var flow = WiFiPanelFlow()
    private var renderedPage: WiFiPanelFlow.Page?
    private var renderedRowFlow: [String?] = []
    private var listIsScanning = true
    private var scanFailureMessage: String?
    private var isPoweredOff = false
    private var isRestoringSelection = false
    private var escapeMonitor: Any?
    /// False while an auto-shown panel waits for a mouse click: Return must not join anything.
    private var keyboardEngaged = false
    private var mouseMonitor: Any?
    private var loginNoticeAction: (@MainActor () -> Void)?

    public init(controller: WiFiPickerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 300))
        buildInterface()
        controller.onStateChange = { [weak self] state in self?.render(state) }
        render(controller.state)
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        // A join that failed while the panel was closed has nothing left to say on reopening,
        // and must not reopen on its password page.
        clearFields()
        flow.panelClosed()
        renderPage()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.panelReceivedMouseDown(event) }
            return event
        }
        // Esc works whoever holds focus: after a refresh, on an empty list, after going back.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleEscape(event) == true }
            return handled ? nil : event
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowFocusChanged),
                           name: NSWindow.didBecomeKeyNotification, object: view.window)
        center.addObserver(self, selector: #selector(windowFocusChanged),
                           name: NSWindow.didResignKeyNotification, object: view.window)
        controller.panelFocusDidChange(isFocused: view.window?.isKeyWindow == true)
        controller.refresh()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        prepareForPopoverClose()
    }

    public func prepareForPopoverClose() {
        clearFields()
        selectedNetworkID = nil
        keyboardEngaged = false
        flow.panelClosed()
        hideLoginNotice()
        renderPage()
    }

    /// Login-item trouble is the one notice that belongs to no row; it brings its own way out.
    public func presentLoginItemNotice(_ message: String, openSettings: @escaping @MainActor () -> Void) {
        loginNoticeLine.message = message
        loginNoticeAction = openSettings
        loginNoticeView.isHidden = false
        renderPage()
    }

    /// The panel takes the keyboard: opened by the user, or an auto-shown panel was clicked.
    public func engageKeyboard() {
        keyboardEngaged = true
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKey()
        if case .list = flow.page { view.window?.makeFirstResponder(tableView) }
    }

    /// Auto-show: visible, but keystrokes keep going to whatever the user is typing in.
    public func presentWithoutKeyboard() {
        keyboardEngaged = false
    }

    private func panelReceivedMouseDown(_ event: NSEvent) {
        guard event.window === view.window else { return }
        controller.userDidInteractWithPicker()
        if !keyboardEngaged { engageKeyboard() }
    }

    /// Esc steps back one level: a form goes to the list, the list closes the panel. A join in
    /// flight cannot be cancelled, so it closes too. An auto-shown panel ignores the keyboard,
    /// and Esc that is cancelling input-method composition stays with the input method.
    private func handleEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.window === view.window, keyboardEngaged else { return false }
        if (view.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        switch flow.page {
        case .list, .permission:
            requestClose()
        case .credentials, .hiddenCredentials:
            if flow.join != nil {
                requestClose()
            } else if case .credentials = flow.page {
                returnToList()
            } else {
                returnFromHiddenCredentials()
            }
        }
        return true
    }

    @objc private func windowFocusChanged() {
        controller.panelFocusDidChange(isFocused: view.window?.isKeyWindow == true)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = WiFiNetworkRowView()
        rowView.isInteractive = !flow.rowsAreLocked
        return rowView
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return WiFiNetworkCellView.height }
        return height(of: rows[row])
    }

    private func height(of network: WiFiNetworkChoice) -> CGFloat {
        flow.rowNotice?.networkID == network.id
            ? WiFiNetworkCellView.height + WiFiNetworkCellView.noticeHeight
            : WiFiNetworkCellView.height
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let network = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("WiFiNetworkCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? WiFiNetworkCellView ?? WiFiNetworkCellView()
        cell.identifier = identifier

        // Just joined: this row is the current one before the next scan could say so.
        let isCurrent = flow.joinedNetworkID.map { $0 == network.id } ?? network.isCurrent
        let isJoining = flow.joiningNetworkID == network.id
        let isUnavailable = flow.rowsAreLocked && !isJoining

        cell.nameLabel.stringValue = network.ssid
        cell.nameLabel.textColor = isUnavailable ? .tertiaryLabelColor : .labelColor
        cell.disc.isCurrent = isCurrent
        cell.disc.isDimmed = isUnavailable
        cell.disc.setSignal(WiFiSignal.symbolValue(rssi: network.rawRSSI))
        cell.lockImageView.isHidden = !network.showsLock || isJoining
        cell.lockImageView.contentTintColor = isUnavailable ? .tertiaryLabelColor : .secondaryLabelColor
        if isJoining {
            cell.joinIndicator.startAnimation(nil)
        } else {
            cell.joinIndicator.stopAnimation(nil)
        }
        if flow.rowNotice?.networkID == network.id, let notice = flow.rowNotice {
            cell.noticeLine.message = notice.message
            cell.noticeLine.isHidden = false
        } else {
            cell.noticeLine.isHidden = true
        }
        cell.needsLayout = true

        cell.setAccessibilityLabel(network.accessibilityLabel(isCurrent: isCurrent))
        switch WiFiJoinPolicy.action(for: network) {
        case .alreadyConnected: cell.setAccessibilityHelp(nil)
        case .openSystemSettings: cell.setAccessibilityHelp("在“Wi‑Fi设置”中加入")
        case .connectWithoutPassword, .askForPassword: cell.setAccessibilityHelp("加入此网络")
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        let selected = tableView.selectedRow
        selectedNetworkID = rows.indices.contains(selected) ? rows[selected].id : nil
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateFormButtons()
    }

    private func buildInterface() {
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buildListPage()
        buildCredentialsPage()
        buildHiddenCredentialsPage()
        buildPermissionPage()

        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        for subview in [headerLabel, headerSeparator, pageContainer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        for page in [listPageView, credentialsPageView, hiddenCredentialsPageView, permissionPageView] {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.inset),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Layout.inset),
            headerLabel.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Layout.headerHeight / 2),
            headerSeparator.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.headerHeight),
            headerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.inset),
            headerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.inset),
            pageContainer.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        renderPage()
    }

    private func buildListPage() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("network"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = WiFiNetworkCellView.height
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.onRowPress = { [weak self] row in self?.networkRowPressed(row) }
        tableView.onRowRelease = { [weak self] row in self?.networkRowReleased(row) }
        tableView.onReturnKey = { [weak self] in self?.joinSelected() }

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.scrollerStyle = .overlay
        listScrollView.borderType = .noBorder
        listScrollView.drawsBackground = false

        placeholderTitleLabel.font = .systemFont(ofSize: 13)
        placeholderButton.bezelStyle = .rounded
        placeholderButton.target = self
        placeholderView.orientation = .vertical
        placeholderView.alignment = .centerX
        placeholderView.spacing = 10
        placeholderView.addArrangedSubview(placeholderTitleLabel)
        placeholderView.addArrangedSubview(placeholderButton)

        loginNoticeButton.bezelStyle = .rounded
        loginNoticeButton.target = self
        loginNoticeButton.action = #selector(runLoginNoticeAction)
        loginNoticeView.orientation = .vertical
        loginNoticeView.alignment = .leading
        loginNoticeView.spacing = 6
        loginNoticeView.addArrangedSubview(loginNoticeLine)
        loginNoticeView.addArrangedSubview(loginNoticeButton)
        loginNoticeView.isHidden = true

        joinOtherRow.target = self
        joinOtherRow.action = #selector(joinHidden)
        settingsRow.target = self
        settingsRow.action = #selector(openWiFiSettings)

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        for subview in [listScrollView, placeholderView, loginNoticeView, footerSeparator, joinOtherRow, settingsRow] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            listPageView.addSubview(subview)
        }
        listHeightConstraint = listScrollView.heightAnchor.constraint(equalToConstant: Layout.placeholderHeight)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: listPageView.topAnchor, constant: Layout.separatorGap),
            listScrollView.leadingAnchor.constraint(equalTo: listPageView.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: listPageView.trailingAnchor),
            listHeightConstraint,
            placeholderView.centerXAnchor.constraint(equalTo: listScrollView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: listScrollView.centerYAnchor),
            placeholderView.widthAnchor.constraint(lessThanOrEqualTo: listPageView.widthAnchor, constant: -2 * Layout.inset),
            loginNoticeView.topAnchor.constraint(equalTo: listScrollView.bottomAnchor, constant: Layout.separatorGap),
            loginNoticeView.leadingAnchor.constraint(equalTo: listPageView.leadingAnchor, constant: Layout.inset),
            loginNoticeView.trailingAnchor.constraint(equalTo: listPageView.trailingAnchor, constant: -Layout.inset),
            footerSeparator.bottomAnchor.constraint(equalTo: joinOtherRow.topAnchor, constant: -Layout.separatorGap),
            footerSeparator.leadingAnchor.constraint(equalTo: listPageView.leadingAnchor, constant: Layout.inset),
            footerSeparator.trailingAnchor.constraint(equalTo: listPageView.trailingAnchor, constant: -Layout.inset),
            joinOtherRow.leadingAnchor.constraint(equalTo: listPageView.leadingAnchor, constant: 6),
            joinOtherRow.trailingAnchor.constraint(equalTo: listPageView.trailingAnchor, constant: -6),
            settingsRow.topAnchor.constraint(equalTo: joinOtherRow.bottomAnchor),
            settingsRow.leadingAnchor.constraint(equalTo: joinOtherRow.leadingAnchor),
            settingsRow.trailingAnchor.constraint(equalTo: joinOtherRow.trailingAnchor),
            settingsRow.bottomAnchor.constraint(equalTo: listPageView.bottomAnchor, constant: -Layout.bottomPadding)
        ])
    }

    /// A form: its fields, a reason under them when a join failed, then "取消" and "加入".
    private func buildForm(
        in page: NSView,
        stack: NSStackView,
        fields: [NSTextField],
        notice: WiFiNoticeLine,
        indicator: NSProgressIndicator,
        cancel: FirstClickButton,
        cancelAction: Selector,
        join: FirstClickButton,
        joinAction: Selector
    ) {
        for field in fields {
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
        }
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = cancelAction
        join.bezelStyle = .rounded
        join.target = self
        join.action = joinAction
        join.keyEquivalent = "\r"
        notice.isHidden = true

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, indicator, cancel, join])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in fields + [notice, footer] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)

        NSLayoutConstraint.activate(fields.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) } + [
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: Layout.inset),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -Layout.inset),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: Layout.pagePadding),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.formButtonWidth),
            join.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.formButtonWidth)
        ])
    }

    private func buildCredentialsPage() {
        passwordField.placeholderString = "密码"
        passwordField.target = self
        passwordField.action = #selector(submitCredentials)
        buildForm(
            in: credentialsPageView, stack: credentialsStack, fields: [passwordField],
            notice: credentialsNoticeLine, indicator: credentialsIndicator,
            cancel: credentialsCancelButton, cancelAction: #selector(returnToList),
            join: credentialsJoinButton, joinAction: #selector(submitCredentials)
        )
    }

    private func buildHiddenCredentialsPage() {
        hiddenSSIDField.placeholderString = "网络名称"
        hiddenPasswordField.placeholderString = "密码（没有可留空）"
        hiddenPasswordField.target = self
        hiddenPasswordField.action = #selector(submitHiddenCredentials)
        buildForm(
            in: hiddenCredentialsPageView, stack: hiddenStack, fields: [hiddenSSIDField, hiddenPasswordField],
            notice: hiddenNoticeLine, indicator: hiddenIndicator,
            cancel: hiddenCancelButton, cancelAction: #selector(returnFromHiddenCredentials),
            join: hiddenJoinButton, joinAction: #selector(submitHiddenCredentials)
        )
    }

    private func buildPermissionPage() {
        permissionMessageLabel.font = .systemFont(ofSize: 13)
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionStack.orientation = .vertical
        permissionStack.alignment = .centerX
        permissionStack.spacing = 10
        permissionStack.addArrangedSubview(permissionMessageLabel)
        permissionStack.addArrangedSubview(permissionButton)
        permissionStack.translatesAutoresizingMaskIntoConstraints = false
        permissionPageView.addSubview(permissionStack)
        NSLayoutConstraint.activate([
            permissionStack.centerXAnchor.constraint(equalTo: permissionPageView.centerXAnchor),
            permissionStack.topAnchor.constraint(equalTo: permissionPageView.topAnchor, constant: Layout.pagePadding * 2)
        ])
    }

    private func render(_ state: WiFiPickerState) {
        var selectFailedField = false
        switch state {
        case .permissionRequired:
            clearFields()
            setRows([])
            listIsScanning = false
            flow.permissionChanged(required: true)
        case let .scanning(previous):
            if let previous { setRows(previous.networks) }
            listIsScanning = true
            scanFailureMessage = nil
            isPoweredOff = false
            flow.permissionChanged(required: false)
        case let .ready(snapshot):
            setRows(snapshot.networks)
            listIsScanning = false
            scanFailureMessage = nil
            isPoweredOff = false
            flow.permissionChanged(required: false)
        case let .stale(snapshot, _):
            // The old list is still good to click, so a failed refresh says nothing.
            setRows(snapshot.networks)
            listIsScanning = false
        case .connecting:
            break
        case .connected:
            flow.joinSucceeded()
            clearFields()
        case let .failed(message, previous):
            if let previous { setRows(previous.networks) }
            listIsScanning = false
            if flow.join != nil {
                flow.joinFailed(message: message)
                selectFailedField = true
            } else if rows.isEmpty {
                scanFailureMessage = message
            }
        case let .savedNetworkNeedsPassword(network):
            clearFields()
            flow.savedNetworkNeedsPassword(network)
        case .poweredOff:
            setRows([])
            listIsScanning = false
            isPoweredOff = true
            scanFailureMessage = nil
        }
        renderPage()
        if selectFailedField { selectFieldAfterFailure(message: flow.pageNotice) }
    }

    private func renderPage() {
        // Hiding the page that holds the keyboard focus drops it, so only other pages are hidden.
        let visiblePage: NSView
        switch flow.page {
        case .list: visiblePage = listPageView
        case .credentials: visiblePage = credentialsPageView
        case .hiddenCredentials: visiblePage = hiddenCredentialsPageView
        case .permission: visiblePage = permissionPageView
        }
        for page in [listPageView, credentialsPageView, hiddenCredentialsPageView, permissionPageView] {
            page.isHidden = page !== visiblePage
        }

        // Scans re-render every few seconds; only arriving on a page may move the focus.
        let arrived = renderedPage != flow.page
        renderedPage = flow.page

        switch flow.page {
        case .list:
            headerLabel.stringValue = "Wi‑Fi"
            reloadRowsIfFlowChanged()
            restoreSelection()
            renderPlaceholder()
            // With Wi-Fi off a hidden network can only fail, so the row turns grey.
            joinOtherRow.isEnabled = flow.join == nil && !isPoweredOff
            focusTableIfNeeded()
        case let .credentials(target):
            headerLabel.stringValue = "加入 \(target.ssid)"
            renderForm(notice: credentialsNoticeLine, indicator: credentialsIndicator)
            if arrived { focusField(passwordField) }
        case .hiddenCredentials:
            headerLabel.stringValue = "加入其他网络"
            renderForm(notice: hiddenNoticeLine, indicator: hiddenIndicator)
            if arrived { focusField(hiddenSSIDField) }
        case .permission:
            headerLabel.stringValue = "Wi‑Fi"
            renderPermission()
        }
        updatePanelSize()
    }

    private func renderForm(notice: WiFiNoticeLine, indicator: NSProgressIndicator) {
        notice.message = flow.pageNotice ?? ""
        notice.isHidden = flow.pageNotice == nil
        if flow.join != nil {
            indicator.startAnimation(nil)
        } else {
            indicator.stopAnimation(nil)
        }
        for field in [passwordField, hiddenSSIDField, hiddenPasswordField] {
            field.isEnabled = flow.join == nil
        }
        updateFormButtons()
    }

    private func renderPermission() {
        let action = WiFiPermissionAction(location: controller.locationState)
        permissionButton.title = action.title
        switch action {
        case .request: permissionButton.action = #selector(requestPermission)
        case .openSettings: permissionButton.action = #selector(openLocationSettings)
        }
    }

    private func reloadRowsIfFlowChanged() {
        let signature = [flow.joiningNetworkID, flow.rowNotice?.networkID, flow.joinedNetworkID,
                         flow.rowsAreLocked ? "locked" : nil]
        guard signature != renderedRowFlow else { return }
        renderedRowFlow = signature
        tableView.reloadData()
    }

    /// Back on the list, arrows and Return need the table, also when rows only just appeared
    /// or focus was left on a field of a page that is now hidden.
    private func focusTableIfNeeded() {
        guard keyboardEngaged, !listScrollView.isHidden, let window = view.window,
              (window.firstResponder as? NSView)?.isDescendant(of: listPageView) != true else { return }
        window.makeFirstResponder(tableView)
    }

    private func renderPlaceholder() {
        listScrollView.isHidden = rows.isEmpty
        placeholderView.isHidden = !rows.isEmpty
        guard rows.isEmpty else { return }
        placeholderButton.isHidden = false
        placeholderButton.action = #selector(retryScan)
        if isPoweredOff {
            placeholderTitleLabel.stringValue = "Wi‑Fi已关闭"
            placeholderButton.title = "打开Wi‑Fi"
            placeholderButton.action = #selector(turnWiFiOn)
        } else if let scanFailureMessage {
            placeholderTitleLabel.stringValue = scanFailureMessage
            placeholderButton.title = "重试"
        } else {
            // The list scans by itself, so an empty one needs no button.
            placeholderTitleLabel.stringValue = listIsScanning ? "正在扫描…" : "未找到网络"
            placeholderButton.isHidden = true
        }
    }

    /// Grows with the network count, up to `maximumPanelHeight`; the list scrolls past that.
    private func updatePanelSize() {
        let chromeHeight = Layout.headerHeight + 1
        let height: CGFloat
        switch flow.page {
        case .list:
            let noticeHeight = loginNoticeView.isHidden
                ? 0
                : ceil(loginNoticeView.fittingSize.height) + Layout.separatorGap
            let fixed = chromeHeight + Layout.separatorGap + noticeHeight + Layout.separatorGap + 1
                + Layout.separatorGap + 2 * WiFiTextRow.height + Layout.bottomPadding
            let wanted = rows.isEmpty
                ? Layout.placeholderHeight
                : rows.reduce(0) { $0 + self.height(of: $1) }
            let listHeight = min(wanted, max(Layout.placeholderHeight, maximumPanelHeight - fixed))
            listHeightConstraint?.constant = listHeight
            height = fixed + listHeight
        case .credentials:
            height = chromeHeight + ceil(credentialsStack.fittingSize.height) + 2 * Layout.pagePadding
        case .hiddenCredentials:
            height = chromeHeight + ceil(hiddenStack.fittingSize.height) + 2 * Layout.pagePadding
        case .permission:
            height = chromeHeight + ceil(permissionStack.fittingSize.height) + 4 * Layout.pagePadding
        }
        preferredContentSize = NSSize(width: Layout.width, height: height)
    }

    private func setRows(_ newRows: [WiFiNetworkChoice]) {
        rows = newRows
        tableView.reloadData()
        restoreSelection()
    }

    private func restoreSelection() {
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        if let selectedNetworkID,
           let index = rows.firstIndex(where: { $0.id == selectedNetworkID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            selectedNetworkID = nil
            tableView.deselectAll(nil)
        }
    }

    private func updateFormButtons() {
        let isIdle = flow.join == nil
        credentialsCancelButton.isEnabled = isIdle
        credentialsJoinButton.isEnabled = isIdle && !passwordField.stringValue.isEmpty
        hiddenCancelButton.isEnabled = isIdle
        hiddenJoinButton.isEnabled = isIdle && !hiddenSSIDField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clicked(_ network: WiFiNetworkChoice) {
        switch flow.rowClicked(network) {
        case .ignored:
            return
        case .openSettings:
            openWiFiSettings()
        case .join:
            renderPage()
            controller.connect(to: network, password: nil)
        case .askForPassword:
            clearFields()
            renderPage()
        }
    }

    private func networkRowPressed(_ row: Int) {
        pressedNetworkID = rows.indices.contains(row) ? rows[row].id : nil
        controller.userDidInteractWithPicker()
        if !keyboardEngaged { engageKeyboard() }
    }

    private func networkRowReleased(_ row: Int) {
        defer { pressedNetworkID = nil }
        guard rows.indices.contains(row), rows[row].id == pressedNetworkID else { return }
        // Selection is the keyboard's cursor; a click acts without leaving one behind.
        selectedNetworkID = nil
        restoreSelection()
        clicked(rows[row])
    }

    private func joinSelected() {
        guard keyboardEngaged, let selectedNetworkID,
              let network = rows.first(where: { $0.id == selectedNetworkID }) else { return }
        clicked(network)
    }

    @objc private func retryScan() {
        controller.refresh(force: true)
    }

    @objc private func turnWiFiOn() {
        controller.turnWiFiOn()
    }

    /// Leaving for Settings closes the panel, as choosing an item in the system's menu does.
    @objc private func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            _ = openSystemURL(url)
        }
        requestClose()
    }

    @objc private func submitCredentials() {
        guard case let .credentials(target) = flow.page, flow.join == nil else { return }
        let password = passwordField.stringValue
        guard !password.isEmpty else { return }
        flow.passwordSubmitted()
        // The field keeps the text until the result: a wrong password stays selected for retyping.
        view.window?.makeFirstResponder(nil)
        renderPage()
        controller.connect(to: target, password: password)
    }

    @objc private func returnToList() {
        guard case let .credentials(target) = flow.page, flow.join == nil else { return }
        selectedNetworkID = target.id
        clearFields()
        flow.returnToList()
        renderPage()
        controller.refresh(force: true)
    }

    @objc private func requestClose() {
        clearFields()
        selectedNetworkID = nil
        onRequestClose?()
    }

    @objc private func joinHidden() {
        clearFields()
        flow.openHiddenCredentials()
        renderPage()
    }

    @objc private func submitHiddenCredentials() {
        guard flow.page == .hiddenCredentials, flow.join == nil else { return }
        let ssid = hiddenSSIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            view.window?.makeFirstResponder(hiddenSSIDField)
            return
        }
        let password = hiddenPasswordField.stringValue.isEmpty ? nil : hiddenPasswordField.stringValue
        flow.hiddenCredentialsSubmitted()
        view.window?.makeFirstResponder(nil)
        renderPage()
        controller.connectHidden(ssid: ssid, password: password)
    }

    @objc private func returnFromHiddenCredentials() {
        guard flow.page == .hiddenCredentials, flow.join == nil else { return }
        clearFields()
        flow.returnToList()
        renderPage()
        controller.refresh(force: true)
    }

    @objc private func requestPermission() {
        controller.requestLocationPermission()
    }

    @objc private func openLocationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ]
        for value in urls {
            if let url = URL(string: value), openSystemURL(url) { return }
        }
    }

    /// Leaving for Settings closes the panel, as the Wi-Fi settings row does.
    @objc private func runLoginNoticeAction() {
        loginNoticeAction?()
        hideLoginNotice()
        requestClose()
    }

    private func hideLoginNotice() {
        loginNoticeView.isHidden = true
        loginNoticeAction = nil
    }

    private func clearFields() {
        passwordField.stringValue = ""
        hiddenSSIDField.stringValue = ""
        hiddenPasswordField.stringValue = ""
    }

    /// The field waited disabled for the result: hand it back with its text selected, so typing
    /// replaces it. A missing password points at the password field, anything else at the name.
    private func selectFieldAfterFailure(message: String?) {
        switch flow.page {
        case .credentials:
            focusField(passwordField)
        case .hiddenCredentials:
            let needsPassword = message == WiFiPickerError.passwordRequired.localizedDescription
            focusField(needsPassword ? hiddenPasswordField : hiddenSSIDField)
        case .list, .permission:
            break
        }
    }

    private func focusField(_ field: NSTextField) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !field.isHiddenOrHasHiddenAncestor, self.keyboardEngaged else { return }
            self.view.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }
}
