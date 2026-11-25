import Foundation
import Network
import os

private let log = Logger(subsystem: "io.github.ruodou233.MacWiFiPicker", category: "picker")

public enum WiFiPickerState: Equatable, Sendable {
    case permissionRequired
    case scanning(previous: WiFiScanSnapshot?)
    case ready(WiFiScanSnapshot)
    case stale(snapshot: WiFiScanSnapshot, message: String)
    case connecting(ssid: String)
    case connected(ssid: String?)
    case failed(message: String, previous: WiFiScanSnapshot?)
    case savedNetworkNeedsPassword(network: WiFiNetworkChoice)
    case poweredOff
}

public enum WiFiPickerVisibilityRequest: Equatable, Sendable {
    case show
    case hide
}

@MainActor
public final class WiFiPickerController {
    public var onStateChange: (@MainActor (WiFiPickerState) -> Void)?
    public var onVisibilityRequest: (@MainActor (WiFiPickerVisibilityRequest) -> Void)?
    public var onLinkChange: (@MainActor (WiFiLinkSnapshot) -> Void)?
    /// Quiet period after launch and wake, when a link that is still coming up is not a real disconnect.
    public var presentationGracePeriod: TimeInterval = 10
    /// A forgotten panel must not keep knocking the radio off-channel for scans.
    public var unfocusedScanPause: TimeInterval = 60

    public private(set) var state: WiFiPickerState = .scanning(previous: nil) {
        didSet { onStateChange?(state) }
    }

    private let service: any WiFiServicing
    private let permission: any WiFiLocationProviding
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "io.github.ruodou233.MacWiFiPicker.path", qos: .utility)
    // Timer is not Sendable; all access is main-actor isolated except deinit,
    // where invalidation is required to release the RunLoop registrations.
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var linkTimer: Timer?
    private var currentSnapshot: WiFiScanSnapshot?
    private var scanTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var linkCheckTask: Task<Void, Never>?
    private var disconnectDebounceTask: Task<Void, Never>?
    private var hideAfterConnectionTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var isStarted = false
    private var pickerIsVisible = false
    private var manuallyPresented = false
    private var wasAssociated: Bool?
    private var disconnectedSince: Date?
    private var suppressAutoShowUntil = Date.distantPast
    private var nextAllowedScan = Date.distantPast
    private var scanBackoff: TimeInterval = 8
    private var isConnecting = false
    private var scansPaused = false
    private var focusPauseTask: Task<Void, Never>?
    private var scanStartedAt = Date()
    public private(set) var lastLink: WiFiLinkSnapshot?

    public var locationState: WiFiLocationState { permission.state }
    public var isManuallyPresented: Bool { manuallyPresented }
    public var scansArePaused: Bool { scansPaused }

    public convenience init(service: any WiFiServicing = CoreWLANWiFiService()) {
        self.init(service: service, permission: WiFiLocationPermission())
    }

    public init(service: any WiFiServicing, permission: any WiFiLocationProviding) {
        self.service = service
        self.permission = permission
        permission.onChange = { [weak self] _ in
            self?.handlePermissionChange()
        }
    }

    deinit {
        scanTask?.cancel()
        connectTask?.cancel()
        linkCheckTask?.cancel()
        disconnectDebounceTask?.cancel()
        hideAfterConnectionTask?.cancel()
        focusPauseTask?.cancel()
        refreshTimer?.invalidate()
        linkTimer?.invalidate()
        pathMonitor?.cancel()
    }

    /// Starts the background link observer. A manual launch always presents the picker;
    /// a login launch presents it only when no Wi-Fi link exists.
    public func start(manuallyLaunched: Bool) {
        guard !isStarted else {
            if manuallyLaunched { presentManually() }
            return
        }
        isStarted = true
        lifecycleGeneration &+= 1
        manuallyPresented = manuallyLaunched
        pickerIsVisible = false
        if !manuallyLaunched {
            suppressAutoShowUntil = Date().addingTimeInterval(presentationGracePeriod)
        }

        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleLinkCheck() }
        }
        monitor.start(queue: pathQueue)

        linkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleLinkCheck() }
        }
        scheduleLinkCheck(forcePresentation: manuallyLaunched)
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        connectTask?.cancel()
        connectTask = nil
        linkCheckTask?.cancel()
        linkCheckTask = nil
        disconnectDebounceTask?.cancel()
        disconnectDebounceTask = nil
        hideAfterConnectionTask?.cancel()
        hideAfterConnectionTask = nil
        endScanPause()
        stopRefreshTimer()
        linkTimer?.invalidate()
        linkTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        isConnecting = false
        pickerIsVisible = false
        manuallyPresented = false
        wasAssociated = nil
        disconnectedSince = nil
        nextAllowedScan = .distantPast
        scanBackoff = 8
        onVisibilityRequest?(.hide)
    }

    public func presentManually() {
        hideAfterConnectionTask?.cancel()
        hideAfterConnectionTask = nil
        manuallyPresented = true
        pickerIsVisible = true
        suppressAutoShowUntil = .distantPast
        log.notice("show: opened by user")
        onVisibilityRequest?(.show)
        beginVisibleRefreshCycle()
    }

    /// Once the user has touched an auto-shown panel it is theirs: reconnecting must not close it.
    public func userDidInteractWithPicker() {
        guard pickerIsVisible else { return }
        manuallyPresented = true
    }

    public func noteSystemDidWake() {
        suppressAutoShowUntil = max(
            suppressAutoShowUntil,
            Date().addingTimeInterval(presentationGracePeriod)
        )
        disconnectedSince = nil
        disconnectDebounceTask?.cancel()
        disconnectDebounceTask = nil
    }

    /// Scans continue while the panel has keyboard focus; `unfocusedScanPause` after losing it they
    /// stop, and regaining focus refreshes at once. An auto-shown panel starts out unfocused.
    public func panelFocusDidChange(isFocused: Bool) {
        focusPauseTask?.cancel()
        focusPauseTask = nil
        if isFocused {
            guard scansPaused else { return }
            scansPaused = false
            beginVisibleRefreshCycle()
            return
        }
        guard pickerIsVisible else { return }
        let delay = unfocusedScanPause
        focusPauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scansPaused = true
            self.stopRefreshTimer()
            log.notice("scan: paused after \(delay, format: .fixed(precision: 0), privacy: .public)s without focus")
            self.onStateChange?(self.state)
        }
    }

    public func turnWiFiOn() {
        state = .scanning(previous: nil)
        Task { [weak self, service] in
            do {
                try await service.setPower(on: true)
                self?.nextAllowedScan = .distantPast
                self?.refresh(force: true)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.state = .failed(message: message, previous: nil)
            }
        }
    }

    public func pickerDidCloseByUser() {
        pickerIsVisible = false
        manuallyPresented = false
        endScanPause()
        stopRefreshTimer()
        suppressAutoShowUntil = Date().addingTimeInterval(30)
        disconnectDebounceTask?.cancel()
        disconnectDebounceTask = nil
    }

    public func refresh(force: Bool = false) {
        guard isStarted else { return }
        guard !isConnecting else { return }
        guard force || !scansPaused else { return }
        guard permission.state == .authorized else {
            renderPermissionState()
            return
        }
        guard scanTask == nil else { return }

        let now = Date()
        if !force, now < nextAllowedScan { return }
        if force, now.timeIntervalSince(currentSnapshot?.scannedAt ?? .distantPast) < 2 { return }

        let snapshotIsOld = now.timeIntervalSince(currentSnapshot?.scannedAt ?? .distantPast) > 30
        state = .scanning(previous: currentSnapshot)
        scanGeneration &+= 1
        scanStartedAt = now
        let generation = scanGeneration
        scanTask = Task { [weak self, service] in
            if snapshotIsOld, let cached = await service.cachedScan() {
                guard !Task.isCancelled else { return }
                self?.showCachedResults(cached, generation: generation)
            }
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await service.scan()
                guard !Task.isCancelled else { return }
                self?.finishScan(snapshot, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishScan(error: error, generation: generation)
            }
        }
    }

    public func connect(to choice: WiFiNetworkChoice, password: String?) {
        guard !isConnecting else { return }
        isConnecting = true
        let pendingScan = cancelScanForConnection()
        stopRefreshTimer()
        state = .connecting(ssid: choice.ssid)
        log.notice("connect: \(choice.ssid, privacy: .public), \(password == nil ? "no password" : "with a password", privacy: .public)")

        connectTask = Task { [weak self, service] in
            await pendingScan?.value
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            do {
                let target = WiFiAssociationTarget(
                    ssidDataHex: choice.ssidDataHex,
                    security: choice.security
                )
                try await service.associate(to: choice, password: password)
                try Task.checkCancellation()
                try await self?.waitForAssociation(target: target, deadline: deadline)
                guard !Task.isCancelled else { return }
                self?.finishConnection(ssid: choice.ssid)
            } catch {
                log.notice("connect: failed, \(String(describing: error), privacy: .public)")
                if await self?.recoverLateAssociation(
                    after: error,
                    target: WiFiAssociationTarget(
                        ssidDataHex: choice.ssidDataHex,
                        security: choice.security
                    ),
                    ssid: choice.ssid,
                    deadline: deadline
                ) == true {
                    return
                }
                guard !Task.isCancelled else { return }
                if choice.security == .personal, password == nil {
                    self?.finishSavedNetworkAttempt(choice)
                } else {
                    self?.finishConnection(error: error)
                }
            }
        }
    }

    public func connectHidden(ssid: String, password: String?) {
        guard !isConnecting else { return }
        isConnecting = true
        let pendingScan = cancelScanForConnection()
        stopRefreshTimer()
        state = .connecting(ssid: ssid)

        connectTask = Task { [weak self, service] in
            await pendingScan?.value
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var target: WiFiAssociationTarget?
            do {
                target = try await service.resolveHiddenTarget(ssid: ssid, password: password)
                guard let target else { return }
                try Task.checkCancellation()
                try await service.associateHidden(to: target, password: password)
                try Task.checkCancellation()
                try await self?.waitForAssociation(target: target, deadline: deadline)
                guard !Task.isCancelled else { return }
                self?.finishConnection(ssid: ssid)
            } catch {
                log.notice("connect: hidden network failed, \(String(describing: error), privacy: .public)")
                if let target,
                   await self?.recoverLateAssociation(
                       after: error,
                       target: target,
                       ssid: ssid,
                       deadline: deadline
                   ) == true {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.finishConnection(error: error)
            }
        }
    }

    /// Cancelling does not stop CoreWLAN: a scan in flight keeps the interface busy until it
    /// returns, and a join started before that fails as "operation in progress". The caller
    /// awaits the returned task before joining; the 30-second join deadline starts after it.
    private func cancelScanForConnection() -> Task<Void, Never>? {
        let pendingScan = scanTask
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        return pendingScan
    }

    public func requestLocationPermission() {
        permission.request()
    }

    private func scheduleLinkCheck(forcePresentation: Bool = false) {
        guard isStarted else { return }
        guard linkCheckTask == nil else { return }
        let generation = lifecycleGeneration
        linkCheckTask = Task { [weak self, service] in
            let link = await service.currentLink()
            guard !Task.isCancelled else { return }
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == generation else { return }
            self.linkCheckTask = nil
            if link.observationIsAvailable, link != self.lastLink {
                self.lastLink = link
                self.onLinkChange?(link)
            }
            self.handleLink(link, forcePresentation: forcePresentation)
        }
    }

    private func handleLink(_ link: WiFiLinkSnapshot, forcePresentation: Bool) {
        guard isStarted else { return }
        guard link.observationIsAvailable else {
            // An unknown observation cannot establish continuous disconnection.
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            disconnectedSince = nil
            if forcePresentation {
                showIfNeeded()
                beginVisibleRefreshCycle()
            }
            return
        }
        guard link.powerIsOn else {
            wasAssociated = false
            disconnectedSince = nil
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            if pickerIsVisible, !isConnecting, state != .poweredOff {
                showPoweredOff()
            }
            if forcePresentation {
                showIfNeeded()
                beginVisibleRefreshCycle()
            }
            return
        }
        if pickerIsVisible, state == .poweredOff {
            state = .scanning(previous: nil)
            refresh(force: true)
        }
        let previousAssociation = wasAssociated
        wasAssociated = link.isAssociated

        if link.isAssociated {
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            disconnectedSince = nil
            if forcePresentation || manuallyPresented {
                showIfNeeded()
                beginVisibleRefreshCycle()
            } else if pickerIsVisible, !isConnecting {
                hidePicker()
            }
            return
        }

        if disconnectedSince == nil { disconnectedSince = Date() }
        let shouldPresent = WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: previousAssociation,
            isAssociated: false,
            disconnectedFor: Date().timeIntervalSince(disconnectedSince ?? Date()),
            suppressionIsActive: Date() < suppressAutoShowUntil,
            forcedByUser: forcePresentation
        )
        if shouldPresent {
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            // Each 5-second check while disconnected lands here. Only a panel that is not on
            // screen yet becomes an auto-show; one the user is working in stays theirs.
            if !pickerIsVisible {
                manuallyPresented = false
                log.notice("show: Wi-Fi disconnected")
            }
            showIfNeeded()
            beginVisibleRefreshCycle()
        } else if Date() >= suppressAutoShowUntil, disconnectDebounceTask == nil {
            let generation = lifecycleGeneration
            disconnectDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                guard let self,
                      self.isStarted,
                      self.lifecycleGeneration == generation else { return }
                self.disconnectDebounceTask = nil
                self.scheduleLinkCheck()
            }
        }
    }

    private func showIfNeeded() {
        if !pickerIsVisible {
            pickerIsVisible = true
            scansPaused = false
            onVisibilityRequest?(.show)
        }
        renderPermissionStateOrRefresh()
    }

    private func hidePicker() {
        pickerIsVisible = false
        manuallyPresented = false
        endScanPause()
        stopRefreshTimer()
        log.notice("hide: connected")
        onVisibilityRequest?(.hide)
    }

    private func beginVisibleRefreshCycle() {
        guard pickerIsVisible else { return }
        renderPermissionStateOrRefresh()
        installRefreshTimerIfNeeded()
    }

    private func installRefreshTimerIfNeeded() {
        guard refreshTimer == nil, !scansPaused else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func endScanPause() {
        focusPauseTask?.cancel()
        focusPauseTask = nil
        scansPaused = false
    }

    private func showPoweredOff() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        currentSnapshot = nil
        state = .poweredOff
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func renderPermissionStateOrRefresh() {
        switch permission.state {
        case .authorized:
            refresh()
        default:
            renderPermissionState()
        }
    }

    private func renderPermissionState() {
        if permission.state == .authorized {
            refresh()
        } else {
            state = .permissionRequired
        }
    }

    private func handlePermissionChange() {
        if let lastLink { onLinkChange?(lastLink) }
        if permission.state != .authorized {
            scanGeneration &+= 1
            scanTask?.cancel()
            scanTask = nil
        }
        guard !isConnecting else { return }
        guard pickerIsVisible else { return }
        renderPermissionStateOrRefresh()
    }

    private func finishScan(_ snapshot: WiFiScanSnapshot, generation: UInt64) {
        guard generation == scanGeneration else { return }
        guard permission.state == .authorized else {
            scanTask = nil
            if pickerIsVisible { renderPermissionState() }
            return
        }
        scanTask = nil
        currentSnapshot = snapshot
        let seconds = Date().timeIntervalSince(scanStartedAt)
        log.notice("scan: \(snapshot.networks.count, privacy: .public) networks in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
        nextAllowedScan = Date().addingTimeInterval(8)
        scanBackoff = 8
        state = .ready(snapshot)
    }

    private func showCachedResults(_ cached: WiFiScanSnapshot, generation: UInt64) {
        guard generation == scanGeneration, permission.state == .authorized else { return }
        currentSnapshot = cached
        state = .scanning(previous: cached)
    }

    private func finishScan(error: Error, generation: UInt64) {
        guard generation == scanGeneration else { return }
        scanTask = nil
        log.notice("scan: failed, \(String(describing: error), privacy: .public)")
        if error as? WiFiPickerError == .wifiPoweredOff {
            showPoweredOff()
            return
        }
        nextAllowedScan = Date().addingTimeInterval(scanBackoff)
        scanBackoff = min(60, scanBackoff * 2)
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let currentSnapshot {
            state = .stale(snapshot: currentSnapshot, message: message)
        } else {
            state = .failed(message: message, previous: nil)
        }
    }

    private func waitForAssociation(
        target: WiFiAssociationTarget,
        deadline: ContinuousClock.Instant
    ) async throws {
        var stableMatches = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let link = await service.currentLink()
            if WiFiAssociationVerifier.matchesTarget(link, target: target) {
                stableMatches += 1
                if stableMatches >= 4 { return }
            } else {
                stableMatches = 0
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WiFiPickerError.connectionTimedOut
    }

    private func recoverLateAssociation(
        after error: Error,
        target: WiFiAssociationTarget,
        ssid: String,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        guard error as? WiFiPickerError == .connectionTimedOut else { return false }
        do {
            try await waitForAssociation(target: target, deadline: deadline)
            guard !Task.isCancelled else { return false }
            finishConnection(ssid: ssid)
            return true
        } catch {
            return false
        }
    }

    private func finishConnection(ssid: String) {
        connectTask = nil
        isConnecting = false
        wasAssociated = true
        log.notice("connect: joined \(ssid, privacy: .public)")
        state = .connected(ssid: ssid)
        hideAfterConnectionTask?.cancel()
        hideAfterConnectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.hidePicker()
            self?.hideAfterConnectionTask = nil
        }
    }

    private func finishSavedNetworkAttempt(_ network: WiFiNetworkChoice) {
        connectTask = nil
        isConnecting = false
        state = .savedNetworkNeedsPassword(network: network)
        if pickerIsVisible { installRefreshTimerIfNeeded() }
    }

    private func finishConnection(error: Error) {
        connectTask = nil
        isConnecting = false
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message: message, previous: currentSnapshot)
        if pickerIsVisible { installRefreshTimerIfNeeded() }
    }
}
