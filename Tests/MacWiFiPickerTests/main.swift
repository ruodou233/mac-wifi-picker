import Foundation
import CoreWLAN
import MacWiFiPicker

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case let .failed(message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

@MainActor
private func eventually(
    timeout: Duration,
    pollEveryNanoseconds: UInt64 = 50_000_000,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: pollEveryNanoseconds)
    }
    return condition()
}

private func containsConnectedState(_ states: [WiFiPickerState]) -> Bool {
    states.contains { state in
        if case .connected = state { return true }
        return false
    }
}

private func accessPoint(
    id: String,
    ssid: String = "Office",
    hex: String = "4f6666696365",
    bssid: String? = nil,
    channel: Int = 36,
    band: WiFiBand = .band5GHz,
    rssi: Int,
    security: WiFiSecurityKind = .personal,
    saved: Bool = false,
    current: Bool = false
) -> WiFiAccessPoint {
    WiFiAccessPoint(
        id: id,
        ssid: ssid,
        ssidDataHex: hex,
        bssid: bssid,
        channel: channel,
        band: band,
        rawRSSI: rssi,
        security: security,
        isSaved: saved,
        isCurrent: current
    )
}

private func runTests() throws {
    let sorted = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "weak", ssid: "Weak", hex: "01", rssi: -81),
            accessPoint(id: "strong", ssid: "Strong", hex: "02", rssi: -34),
            accessPoint(id: "medium", ssid: "Medium", hex: "03", rssi: -62)
        ],
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 1
    )
    try expect(sorted.networks.map(\.rawRSSI) == [-34, -62, -81], "raw RSSI must be descending")

    let grouped = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "5g", bssid: "aa:bb:cc:00:00:01", rssi: -42),
            accessPoint(id: "2g", bssid: "aa:bb:cc:00:00:02", channel: 6, band: .band2GHz, rssi: -59),
            accessPoint(id: "open", rssi: -40, security: .open)
        ],
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 2
    )
    try expect(grouped.networks.count == 2, "group key must include SSID bytes and security")
    let personal = grouped.networks.first { $0.security == .personal }
    try expect(personal?.accessPoints.map(\.id) == ["5g", "2g"], "all APs must be retained and RSSI sorted")

    let duplicateAP = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "same-ap", bssid: "aa:bb:cc:00:00:03", rssi: -72),
            accessPoint(id: "same-ap", bssid: "aa:bb:cc:00:00:03", rssi: -39)
        ],
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 3
    )
    try expect(duplicateAP.networks.count == 1, "duplicate AP observations must remain one network")
    try expect(
        duplicateAP.networks[0].accessPoints.map(\.rawRSSI) == [-39],
        "duplicate AP observations must retain the strongest current RSSI"
    )

    let sameDisplayName = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "bytes-a", ssid: "Same", hex: "53616d65", rssi: -45),
            accessPoint(id: "bytes-b", ssid: "Same", hex: "53616d6500", rssi: -46)
        ],
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 4
    )
    try expect(
        sameDisplayName.networks.count == 2,
        "identical display strings with different SSID bytes must not be merged"
    )

    let a = accessPoint(id: "a", ssid: "A", hex: "01", rssi: -50)
    let b = accessPoint(id: "b", ssid: "B", hex: "02", rssi: -50)
    let first = WiFiSnapshotBuilder.make(from: [a, b], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let second = WiFiSnapshotBuilder.make(from: [b, a], hiddenNetworkCount: 0, scannedAt: .now, sequence: 2)
    try expect(first.networks.map(\.id) == second.networks.map(\.id), "equal RSSI order must be stable")
    try expect(
        first.networks.map(\.ssid) == ["A", "B"],
        "equal RSSI networks must use natural SSID order"
    )

    let totalOrderInput = [
        accessPoint(id: "current-weak", ssid: "CurrentWeak", hex: "30", rssi: -82, current: true),
        accessPoint(id: "ap-10", ssid: "AP 10", hex: "20", rssi: -50),
        accessPoint(id: "ap-2", ssid: "AP 2", hex: "10", rssi: -50),
        accessPoint(id: "same-open", ssid: "Same", hex: "41", rssi: -50, security: .open),
        accessPoint(id: "same-personal", ssid: "Same", hex: "41", rssi: -50, security: .personal),
        accessPoint(id: "same-bytes-b", ssid: "Same", hex: "42", rssi: -50, security: .personal)
    ]
    let totalOrder = WiFiSnapshotBuilder.make(
        from: totalOrderInput,
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 5
    )
    let reversedTotalOrder = WiFiSnapshotBuilder.make(
        from: Array(totalOrderInput.reversed()),
        hiddenNetworkCount: 0,
        scannedAt: .now,
        sequence: 6
    )
    try expect(
        totalOrder.networks.map(\.id) == reversedTotalOrder.networks.map(\.id),
        "the complete network order must not depend on scan input order"
    )
    try expect(
        totalOrder.networks.map { "\($0.ssid)|\($0.security.rawValue)|\($0.ssidDataHex)" } == [
            "AP 2|personal|10",
            "AP 10|personal|20",
            "Same|open|41",
            "Same|personal|41",
            "Same|personal|42",
            "CurrentWeak|personal|30"
        ],
        "equal RSSI ties must use natural name, security, and SSID-byte order"
    )
    try expect(
        totalOrder.networks.last?.ssid == "CurrentWeak",
        "the current network must not be promoted ahead of stronger RSSI"
    )
    try expect(
        zip(totalOrder.networks, totalOrder.networks.dropFirst()).allSatisfy {
            $0.rawRSSI >= $1.rawRSSI
        },
        "the complete network order must remain RSSI-descending"
    )

    let hidden = accessPoint(id: "hidden", ssid: "", hex: "", rssi: -20)
    let hiddenSnapshot = WiFiSnapshotBuilder.make(
        from: [hidden], hiddenNetworkCount: 3, scannedAt: .now, sequence: 1
    )
    try expect(hiddenSnapshot.networks.isEmpty, "unnamed observations must not become fake rows")
    try expect(hiddenSnapshot.hiddenNetworkCount == 3, "hidden count must be preserved")

    let aggregate1 = WiFiSnapshotBuilder.accessPointID(
        ssidDataHex: "0102", security: .personal, bssid: nil, channel: 36, band: .band5GHz
    )
    let aggregate2 = WiFiSnapshotBuilder.accessPointID(
        ssidDataHex: "0102", security: .personal, bssid: nil, channel: 36, band: .band5GHz
    )
    try expect(aggregate1 == aggregate2, "missing BSSID fallback must be deterministic")

    let bytes = Data([0x00, 0x7f, 0x80, 0xff])
    guard let hex = WiFiSnapshotBuilder.dataHex(bytes) else { throw TestFailure.failed("hex encoding failed") }
    try expect(hex == "007f80ff", "hex encoding changed bytes")
    try expect(WiFiSnapshotBuilder.data(fromHex: hex) == bytes, "hex round trip failed")

    let targetLink = WiFiLinkSnapshot(
        powerIsOn: true,
        isAssociated: true,
        ssid: "Office",
        ssidDataHex: "4f6666696365",
        bssid: nil,
        rawRSSI: -49,
        security: .personal
    )
    let associationTarget = WiFiAssociationTarget(ssidDataHex: "4f6666696365", security: .personal)
    try expect(
        WiFiAssociationVerifier.matchesTarget(targetLink, target: associationTarget),
        "association must succeed without BSSID or internet-path input"
    )
    try expect(
        !WiFiAssociationVerifier.matchesTarget(
            targetLink,
            target: WiFiAssociationTarget(ssidDataHex: "4775657374", security: .personal)
        ),
        "wrong target SSID must not close the picker"
    )
    try expect(
        !WiFiAssociationVerifier.matchesTarget(
            targetLink,
            target: WiFiAssociationTarget(ssidDataHex: "4f6666696365", security: .open)
        ),
        "same SSID with a different security type must not close the picker"
    )
    try expect(
        !WiFiAssociationVerifier.matchesTarget(
            WiFiLinkSnapshot(
                observationIsAvailable: false,
                powerIsOn: true,
                isAssociated: true,
                ssid: "Office",
                ssidDataHex: "4f6666696365",
                bssid: nil,
                rawRSSI: -49,
                security: .personal
            ),
            target: associationTarget
        ),
        "an unavailable link observation must never confirm association"
    )

    func marked(associated: Bool = true, security: WiFiSecurityKind? = .personal,
                currentBSSID: String? = nil, candidateBSSID: String? = nil,
                candidateSecurity: WiFiSecurityKind = .personal, hex: String = "4f6666696365") -> Bool {
        WiFiCurrentNetworkMatcher.matches(
            WiFiLinkSnapshot(powerIsOn: true, isAssociated: associated, ssid: "Office",
                             ssidDataHex: "4f6666696365", bssid: currentBSSID,
                             rawRSSI: -49, security: security),
            ssidDataHex: hex, security: candidateSecurity, bssid: candidateBSSID
        )
    }
    try expect(marked(), "missing BSSID must still identify the matching security group")
    try expect(!marked(candidateSecurity: .open), "same-name open network must not also be current")
    try expect(!marked(associated: false), "residual SSID while disconnected must not mark current")
    try expect(!marked(security: nil), "unknown security must not mark current")
    try expect(!marked(hex: "00"), "SSID bytes must match")
    try expect(!marked(currentBSSID: "aa", candidateBSSID: "bb"), "conflicting visible BSSIDs must not match")
    try expect(marked(currentBSSID: "AA", candidateBSSID: "aa"), "BSSID case must not change identity")
    for (mixed, expected) in [(CWSecurity.wpaPersonalMixed, WiFiSecurityKind.personal),
                              (CWSecurity.wpaEnterpriseMixed, WiFiSecurityKind.enterprise)] {
        // Advertise only the mixed enum: no implicit supportsSecurity relationship.
        let scanned = WiFiCoreWLANSecurityClassifier.kind { $0 == mixed }
        let current = WiFiCoreWLANSecurityClassifier.kind(for: mixed)
        try expect(scanned == expected && current == expected,
                   "WPA/WPA2 mixed scan and link must use the same security category")
        let mixedLink = WiFiLinkSnapshot(powerIsOn: true, isAssociated: true, ssid: "Office",
                                        ssidDataHex: "4f6666696365", bssid: nil,
                                        rawRSSI: -49, security: current)
        try expect(WiFiCurrentNetworkMatcher.matches(
            mixedLink, ssidDataHex: "4f6666696365", security: scanned, bssid: nil
        ), "mixed-security link must mark its scanned group current without BSSID")
        try expect(WiFiAssociationVerifier.matchesTarget(
            mixedLink, target: WiFiAssociationTarget(ssidDataHex: "4f6666696365", security: scanned)
        ), "mixed-security link must confirm a matching association target")
        try expect(!WiFiCurrentNetworkMatcher.matches(
            mixedLink, ssidDataHex: "4f6666696365", security: .open, bssid: nil
        ), "mixed-security link must not mark a same-name open network current")
    }
    try expect(WiFiCoreWLANSecurityClassifier.kind(for: .unknown) == nil,
               "unknown current security must remain unconfirmed")
    try expect(!WiFiDisconnectPresentationPolicy.shouldPresent(
        previousAssociation: true, isAssociated: false, disconnectedFor: 2,
        suppressionIsActive: true, forcedByUser: false
    ), "real disconnection must respect a recent user dismissal")

    let hiddenPersonalSecurity = try WiFiHiddenNetworkPolicy.selectedSecurity(
        available: [.personal], hasPassword: true
    )
    try expect(
        hiddenPersonalSecurity == .personal,
        "a password must select a hidden personal network"
    )
    let hiddenOpenSecurity = try WiFiHiddenNetworkPolicy.selectedSecurity(
        available: [.open], hasPassword: true
    )
    try expect(
        hiddenOpenSecurity == .open,
        "an unnecessary password must not make an open hidden network disappear"
    )
    do {
        _ = try WiFiHiddenNetworkPolicy.selectedSecurity(available: [.personal], hasPassword: false)
        throw TestFailure.failed("a hidden personal network without a password must fail")
    } catch WiFiPickerError.passwordRequired {
        // Expected.
    }
    do {
        _ = try WiFiHiddenNetworkPolicy.selectedSecurity(available: [.enterprise], hasPassword: true)
        throw TestFailure.failed("a hidden enterprise network must use the system UI")
    } catch WiFiPickerError.requiresSystemSettings {
        // Expected.
    }

    try expect(
        WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: nil,
            isAssociated: false,
            disconnectedFor: 0,
            suppressionIsActive: false,
            forcedByUser: false
        ),
        "first disconnected launch must show a picker"
    )
    try expect(
        !WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: false,
            isAssociated: false,
            disconnectedFor: 20,
            suppressionIsActive: true,
            forcedByUser: false
        ),
        "manual-close suppression must prevent focus stealing"
    )
    try expect(
        !WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: true,
            isAssociated: false,
            disconnectedFor: 0,
            suppressionIsActive: true,
            forcedByUser: false
        ),
        "a transient disconnect must be debounced"
    )
    try expect(
        WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: true,
            isAssociated: false,
            disconnectedFor: 1.6,
            suppressionIsActive: false,
            forcedByUser: false
        ),
        "a stable real disconnect must restore the picker"
    )
    try expect(
        WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: false,
            isAssociated: false,
            disconnectedFor: 0,
            suppressionIsActive: true,
            forcedByUser: true
        ),
        "manual presentation must override disconnected suppression"
    )
    try expect(
        !WiFiDisconnectPresentationPolicy.shouldPresent(
            previousAssociation: true,
            isAssociated: true,
            disconnectedFor: 99,
            suppressionIsActive: false,
            forcedByUser: false
        ),
        "an associated background launch must remain hidden"
    )
}

@MainActor
private final class MockPermission: WiFiLocationProviding {
    var onChange: (@MainActor (WiFiLocationState) -> Void)?
    var state: WiFiLocationState = .authorized
    func request() { onChange?(state) }
    func setState(_ newState: WiFiLocationState) {
        state = newState
        onChange?(state)
    }
}

private actor MockService: WiFiServicing {
    let snapshot: WiFiScanSnapshot
    let cachedSnapshot: WiFiScanSnapshot?
    var link: WiFiLinkSnapshot
    let connectionError: WiFiPickerError?
    let scanDelayNanoseconds: UInt64
    let linkDelayNanoseconds: UInt64
    let hiddenResolveDelayNanoseconds: UInt64
    var disconnectedLinkReadsRemaining: Int
    var linkResponses: [WiFiLinkSnapshot]
    var hiddenAssociationCount = 0
    var holdsInterfaceWhileScanning = false
    var interfaceBusy = false
    var linkReadCount = 0
    var scanCount = 0
    var scanError: WiFiPickerError?
    var failureWithoutPassword: WiFiPickerError?
    var associatedPasswords: [String?] = []

    init(
        snapshot: WiFiScanSnapshot,
        cachedSnapshot: WiFiScanSnapshot? = nil,
        link: WiFiLinkSnapshot,
        connectionError: WiFiPickerError? = nil,
        scanError: WiFiPickerError? = nil,
        scanDelayNanoseconds: UInt64 = 0,
        linkDelayNanoseconds: UInt64 = 0,
        hiddenResolveDelayNanoseconds: UInt64 = 0,
        disconnectedLinkReadsBeforeConnected: Int = 0,
        linkResponses: [WiFiLinkSnapshot] = []
    ) {
        self.snapshot = snapshot
        self.cachedSnapshot = cachedSnapshot
        self.link = link
        self.connectionError = connectionError
        self.scanError = scanError
        self.scanDelayNanoseconds = scanDelayNanoseconds
        self.linkDelayNanoseconds = linkDelayNanoseconds
        self.hiddenResolveDelayNanoseconds = hiddenResolveDelayNanoseconds
        disconnectedLinkReadsRemaining = disconnectedLinkReadsBeforeConnected
        self.linkResponses = linkResponses
    }

    func scan() async throws -> WiFiScanSnapshot {
        scanCount += 1
        if holdsInterfaceWhileScanning {
            // Like CoreWLAN: one operation at a time, and cancelling does not end a scan early.
            interfaceBusy = true
            let delay = scanDelayNanoseconds
            await Task.detached { try? await Task.sleep(nanoseconds: delay) }.value
            interfaceBusy = false
            return snapshot
        }
        if scanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        if let scanError { throw scanError }
        return snapshot
    }
    func cachedScan() async -> WiFiScanSnapshot? {
        cachedSnapshot
    }
    func setPower(on: Bool) async throws {
        link = WiFiLinkSnapshot(powerIsOn: on, isAssociated: false, ssid: nil, ssidDataHex: nil,
                                bssid: nil, rawRSSI: nil, security: nil)
    }
    func currentLink() async -> WiFiLinkSnapshot {
        linkReadCount += 1
        if linkDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: linkDelayNanoseconds)
        }
        if !linkResponses.isEmpty {
            return linkResponses.removeFirst()
        }
        if disconnectedLinkReadsRemaining > 0 {
            disconnectedLinkReadsRemaining -= 1
            return WiFiLinkSnapshot(
                powerIsOn: true,
                isAssociated: false,
                ssid: nil,
                ssidDataHex: nil,
                bssid: nil,
                rawRSSI: nil,
                security: nil
            )
        }
        return link
    }
    func associate(to choice: WiFiNetworkChoice, password: String?) async throws {
        associatedPasswords.append(password)
        if password == nil, let failureWithoutPassword { throw failureWithoutPassword }
        if let connectionError { throw connectionError }
        if interfaceBusy { throw WiFiPickerError.operationInProgress }
    }
    func resolveHiddenTarget(ssid: String, password: String?) async throws -> WiFiAssociationTarget {
        if hiddenResolveDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: hiddenResolveDelayNanoseconds)
        }
        return WiFiAssociationTarget(
            ssidDataHex: link.ssidDataHex ?? "",
            security: link.security ?? .other
        )
    }
    func associateHidden(to target: WiFiAssociationTarget, password: String?) async throws {
        hiddenAssociationCount += 1
        if let connectionError { throw connectionError }
    }
    func setLink(_ value: WiFiLinkSnapshot) { link = value; linkReadCount = 0 }
    func holdInterfaceWhileScanning() { holdsInterfaceWhileScanning = true }
    func recordedLinkReadCount() -> Int { linkReadCount }
    func recordedScanCount() -> Int { scanCount }
    func clearScanError() { scanError = nil }
    func failWithoutPassword(_ error: WiFiPickerError) { failureWithoutPassword = error }
    func recordedPasswords() -> [String?] { associatedPasswords }
    func recordedHiddenAssociationCount() -> Int { hiddenAssociationCount }
}

private func presentationLink(available: Bool = true, power: Bool = true, associated: Bool = false) -> WiFiLinkSnapshot {
    WiFiLinkSnapshot(observationIsAvailable: available, powerIsOn: power, isAssociated: associated,
                     ssid: "Office", ssidDataHex: "4f6666696365", bssid: nil,
                     rawRSSI: associated ? -49 : nil, security: .personal)
}

@MainActor
private func runSavedNetworkTests() async throws {
    let ap = accessPoint(id: "target", rssi: -41)
    let snapshot = WiFiSnapshotBuilder.make(from: [ap], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let connected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: true, ssid: "Office", ssidDataHex: "4f6666696365",
                                     bssid: nil, rawRSSI: -41, security: .personal)
    let disconnected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: false, ssid: nil, ssidDataHex: nil,
                                        bssid: nil, rawRSSI: nil, security: nil)
    let saved = WiFiNetworkChoice(id: "saved", ssid: "Office", ssidDataHex: "4f6666696365", security: .personal,
                                  accessPoints: [ap], isSaved: true, isCurrent: false)!

    let okService = MockService(snapshot: snapshot, link: connected)
    let okController = WiFiPickerController(service: okService, permission: MockPermission())
    var okStates: [WiFiPickerState] = []
    okController.onStateChange = { okStates.append($0) }
    okController.presentManually()
    okController.connect(to: saved, password: nil)
    let joined = await eventually(timeout: .seconds(5)) { containsConnectedState(okStates) }
    try expect(joined, "a saved network must connect with no password when macOS accepts it")
    let okPasswords = await okService.recordedPasswords()
    try expect(okPasswords == [nil], "the first attempt must pass no password and no other attempt follows")

    let failService = MockService(snapshot: snapshot, link: connected)
    await failService.failWithoutPassword(.connectionFailed(code: -3903))
    let failController = WiFiPickerController(service: failService, permission: MockPermission())
    var failVisibility: [WiFiPickerVisibilityRequest] = []
    var failStates: [WiFiPickerState] = []
    failController.onVisibilityRequest = { failVisibility.append($0) }
    failController.onStateChange = { failStates.append($0) }
    failController.presentManually()
    failController.connect(to: saved, password: nil)
    let asked = await eventually(timeout: .seconds(2)) {
        failController.state == .savedNetworkNeedsPassword(network: saved)
    }
    try expect(asked, "a failed saved-network attempt must ask for the password, on the same network")
    try expect(!failVisibility.contains(.hide), "a failed attempt must keep the panel open")
    failController.connect(to: saved, password: "temporary-test-password")
    let joinedWithPassword = await eventually(timeout: .seconds(5)) { containsConnectedState(failStates) }
    try expect(joinedWithPassword, "the typed password must then connect")
    let failPasswords = await failService.recordedPasswords()
    try expect(failPasswords == [nil, "temporary-test-password"], "no password first, the typed one second")

    let wrongService = MockService(snapshot: snapshot, link: disconnected, connectionError: .connectionFailed(code: -3906))
    let wrongController = WiFiPickerController(service: wrongService, permission: MockPermission())
    wrongController.presentManually()
    wrongController.connect(to: saved, password: "wrong")
    let wrongFailed = await eventually(timeout: .seconds(2)) {
        if case .failed = wrongController.state { return true }
        return false
    }
    try expect(wrongFailed, "a typed password that fails must report failure, not loop back to the fallback")
}

@MainActor
private func runPresentationTests() async throws {
    let snapshot = WiFiScanSnapshot(networks: [], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let off = presentationLink(power: false)
    let connected = presentationLink(associated: true)
    let unknown = presentationLink(available: false, power: false)
    let initialLinks = [off, connected, connected, connected, connected]
    let services = initialLinks.map { MockService(snapshot: snapshot, link: $0) }
    let controllers = services.map { WiFiPickerController(service: $0, permission: MockPermission()) }
    var shows = [0, 0, 0, 0, 0]
    for (index, controller) in controllers.enumerated() {
        controller.presentationGracePeriod = 0
        controller.onVisibilityRequest = { if $0 == .show { shows[index] += 1 } }
        controller.start(manuallyLaunched: false)
    }
    defer { controllers.forEach { $0.stop() } }
    try await Task.sleep(nanoseconds: 300_000_000)
    try expect(shows == [0, 0, 0, 0, 0], "startup off and connected must remain quiet")
    controllers[2].presentManually()
    controllers[2].pickerDidCloseByUser()
    await services[1].setLink(off)
    await services[2].setLink(unknown)
    await services[3].setLink(presentationLink())
    await services[4].setLink(presentationLink())
    let observationDeadline = ContinuousClock.now.advanced(by: .seconds(6))
    while await services[4].recordedLinkReadCount() == 0, ContinuousClock.now < observationDeadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let transientWasObserved = await services[4].recordedLinkReadCount() > 0
    try expect(transientWasObserved, "transient disconnect must actually be observed")
    await services[4].setLink(connected)
    let disconnectedShown = await eventually(timeout: .seconds(8)) { shows[3] == 1 }
    try expect(disconnectedShown, "a real power-on disconnect must show after debounce")
    try expect(shows[0] == 0 && shows[1] == 0 && shows[2] == 1,
               "startup off, connected-to-off, and dismissed unavailable must remain quiet")
    await services[3].setLink(connected)
    // Exercise repeated unavailable observations beyond the 30-second dismissal window.
    try await Task.sleep(nanoseconds: 31_000_000_000)
    try expect(shows == [0, 0, 1, 1, 0], "unknown observations must not reopen after suppression expires")
    controllers[0].presentManually()
    controllers[1].presentManually()
    controllers[2].presentManually()
    try expect(shows == [1, 1, 2, 1, 0], "manual entry must remain available for off and unknown links")
}

@MainActor
private func runControllerTests() async throws {
    let ap = accessPoint(id: "target", rssi: -41)
    guard let choice = WiFiNetworkChoice(
        id: "choice",
        ssid: ap.ssid,
        ssidDataHex: ap.ssidDataHex,
        security: ap.security,
        accessPoints: [ap],
        isSaved: false,
        isCurrent: false
    ) else { throw TestFailure.failed("could not create test choice") }
    let snapshot = WiFiScanSnapshot(networks: [choice], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let connectedLink = WiFiLinkSnapshot(
        powerIsOn: true,
        isAssociated: true,
        ssid: choice.ssid,
        ssidDataHex: choice.ssidDataHex,
        bssid: nil,
        rawRSSI: -41,
        security: .personal
    )

    let successService = MockService(snapshot: snapshot, link: connectedLink)
    let launchController = WiFiPickerController(service: successService, permission: MockPermission())
    var launchVisibility: [WiFiPickerVisibilityRequest] = []
    launchController.onVisibilityRequest = { launchVisibility.append($0) }
    launchController.start(manuallyLaunched: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    try expect(launchVisibility.contains(.show), "manual first launch must show even when Wi-Fi is already connected")
    launchController.stop()

    let successController = WiFiPickerController(service: successService, permission: MockPermission())
    var successVisibility: [WiFiPickerVisibilityRequest] = []
    var successStates: [WiFiPickerState] = []
    successController.onVisibilityRequest = { successVisibility.append($0) }
    successController.onStateChange = { successStates.append($0) }
    successController.presentManually()
    successController.connect(to: choice, password: "temporary-test-password")
    try expect(successVisibility.contains(.show), "manual presentation must request a visible picker")
    let successReachedConnected = await eventually(timeout: .seconds(5)) {
        containsConnectedState(successStates)
    }
    try expect(
        successReachedConnected,
        "stable target association must reach the connected state"
    )
    let successReachedHidden = await eventually(timeout: .seconds(1)) {
        successVisibility.contains(.hide)
    }
    try expect(
        successReachedHidden,
        "stable target association must hide the picker"
    )
    try expect(
        successVisibility.filter { $0 == .hide }.count == 1,
        "stable target association must emit one hide request"
    )
    let showCountBeforeAssociatedRefresh = successVisibility.filter { $0 == .show }.count
    successController.start(manuallyLaunched: false)
    try await Task.sleep(nanoseconds: 300_000_000)
    try expect(
        successVisibility.filter { $0 == .show }.count == showCountBeforeAssociatedRefresh,
        "an associated link refresh after success must not reopen the picker"
    )
    successController.stop()

    let disconnectedLink = WiFiLinkSnapshot(
        powerIsOn: true,
        isAssociated: false,
        ssid: nil,
        ssidDataHex: nil,
        bssid: nil,
        rawRSSI: nil,
        security: nil
    )
    let transientAfterSuccessService = MockService(
        snapshot: snapshot,
        link: connectedLink,
        linkResponses: [
            connectedLink, connectedLink, connectedLink, connectedLink,
            disconnectedLink, connectedLink
        ]
    )
    let transientAfterSuccessController = WiFiPickerController(
        service: transientAfterSuccessService,
        permission: MockPermission()
    )
    var transientVisibility: [WiFiPickerVisibilityRequest] = []
    var transientConnectedAt: Date?
    var transientHiddenAt: Date?
    transientAfterSuccessController.onVisibilityRequest = { request in
        transientVisibility.append(request)
        if request == .hide { transientHiddenAt = .now }
    }
    transientAfterSuccessController.onStateChange = { state in
        if case .connected = state { transientConnectedAt = .now }
    }
    transientAfterSuccessController.presentManually()
    transientAfterSuccessController.connect(to: choice, password: "temporary-test-password")
    let transientReachedConnected = await eventually(timeout: .seconds(5)) {
        transientConnectedAt != nil
    }
    try expect(transientReachedConnected, "transient-disconnect test must first connect")
    transientAfterSuccessController.start(manuallyLaunched: false)
    let transientReachedHidden = await eventually(timeout: .seconds(1)) {
        transientHiddenAt != nil
    }
    try expect(
        transientReachedHidden,
        "a transient link observation after confirmed success must not cancel picker dismissal"
    )
    if let transientConnectedAt, let transientHiddenAt {
        try expect(
            transientHiddenAt.timeIntervalSince(transientConnectedAt) <= 1,
            "confirmed success must dismiss the picker within one second"
        )
    }
    try expect(
        transientVisibility.filter { $0 == .hide }.count == 1,
        "transient link changes after success must still emit exactly one hide request"
    )
    transientAfterSuccessController.stop()

    let lateSuccessService = MockService(
        snapshot: snapshot,
        link: connectedLink,
        connectionError: .connectionTimedOut,
        disconnectedLinkReadsBeforeConnected: 2
    )
    let lateSuccessController = WiFiPickerController(
        service: lateSuccessService,
        permission: MockPermission()
    )
    var lateSuccessVisibility: [WiFiPickerVisibilityRequest] = []
    var lateSuccessStates: [WiFiPickerState] = []
    lateSuccessController.onVisibilityRequest = { lateSuccessVisibility.append($0) }
    lateSuccessController.onStateChange = { lateSuccessStates.append($0) }
    lateSuccessController.presentManually()
    lateSuccessController.connect(to: choice, password: "temporary-test-password")
    let lateSuccessReachedConnected = await eventually(timeout: .seconds(6)) {
        containsConnectedState(lateSuccessStates)
    }
    try expect(
        lateSuccessReachedConnected,
        "a CoreWLAN timeout followed by a stable target link must reach the connected state"
    )
    let lateSuccessReachedHidden = await eventually(timeout: .seconds(1)) {
        lateSuccessVisibility.contains(.hide)
    }
    try expect(
        lateSuccessReachedHidden,
        "a CoreWLAN timeout followed by a stable target link must still hide the picker"
    )

    let hiddenLateSuccessService = MockService(
        snapshot: snapshot,
        link: connectedLink,
        connectionError: .connectionTimedOut,
        disconnectedLinkReadsBeforeConnected: 2
    )
    let hiddenLateSuccessController = WiFiPickerController(
        service: hiddenLateSuccessService,
        permission: MockPermission()
    )
    var hiddenLateSuccessVisibility: [WiFiPickerVisibilityRequest] = []
    var hiddenLateSuccessStates: [WiFiPickerState] = []
    hiddenLateSuccessController.onVisibilityRequest = { hiddenLateSuccessVisibility.append($0) }
    hiddenLateSuccessController.onStateChange = { hiddenLateSuccessStates.append($0) }
    hiddenLateSuccessController.presentManually()
    hiddenLateSuccessController.connectHidden(
        ssid: choice.ssid,
        password: "temporary-test-password"
    )
    let hiddenLateSuccessReachedConnected = await eventually(timeout: .seconds(6)) {
        containsConnectedState(hiddenLateSuccessStates)
    }
    try expect(
        hiddenLateSuccessReachedConnected,
        "a hidden network that appears after CoreWLAN timeout must reach the connected state"
    )
    let hiddenLateSuccessReachedHidden = await eventually(timeout: .seconds(1)) {
        hiddenLateSuccessVisibility.contains(.hide)
    }
    try expect(
        hiddenLateSuccessReachedHidden,
        "a hidden network that appears after CoreWLAN timeout must still hide the picker"
    )

    let delayedDisconnectedService = MockService(
        snapshot: snapshot,
        link: WiFiLinkSnapshot(
            powerIsOn: true,
            isAssociated: false,
            ssid: nil,
            ssidDataHex: nil,
            bssid: nil,
            rawRSSI: nil,
            security: nil
        ),
        linkDelayNanoseconds: 300_000_000
    )
    let stoppedController = WiFiPickerController(
        service: delayedDisconnectedService,
        permission: MockPermission()
    )
    var stoppedVisibility: [WiFiPickerVisibilityRequest] = []
    stoppedController.onVisibilityRequest = { stoppedVisibility.append($0) }
    stoppedController.start(manuallyLaunched: false)
    stoppedController.stop()
    try await Task.sleep(nanoseconds: 500_000_000)
    try expect(
        !stoppedVisibility.contains(.show),
        "a queued link callback must not show the picker after stop"
    )

    let revocablePermission = MockPermission()
    let delayedScanService = MockService(
        snapshot: snapshot,
        link: connectedLink,
        scanDelayNanoseconds: 300_000_000
    )
    let permissionController = WiFiPickerController(
        service: delayedScanService,
        permission: revocablePermission
    )
    permissionController.start(manuallyLaunched: true)
    try await Task.sleep(nanoseconds: 50_000_000)
    revocablePermission.setState(.denied)
    try await Task.sleep(nanoseconds: 400_000_000)
    if case .permissionRequired = permissionController.state {
        // Expected.
    } else {
        throw TestFailure.failed("a late scan must not overwrite revoked location permission")
    }
    permissionController.stop()

    let stoppedHiddenService = MockService(
        snapshot: snapshot,
        link: connectedLink,
        hiddenResolveDelayNanoseconds: 300_000_000
    )
    let stoppedHiddenController = WiFiPickerController(
        service: stoppedHiddenService,
        permission: MockPermission()
    )
    stoppedHiddenController.start(manuallyLaunched: true)
    stoppedHiddenController.connectHidden(
        ssid: choice.ssid,
        password: "temporary-test-password"
    )
    try await Task.sleep(nanoseconds: 50_000_000)
    stoppedHiddenController.stop()
    try await Task.sleep(nanoseconds: 400_000_000)
    let hiddenAssociationCountAfterStop = await stoppedHiddenService.recordedHiddenAssociationCount()
    try expect(
        hiddenAssociationCountAfterStop == 0,
        "stopping after hidden target resolution starts must prevent association"
    )

    let failureService = MockService(
        snapshot: snapshot,
        link: WiFiLinkSnapshot(
            powerIsOn: true,
            isAssociated: false,
            ssid: nil,
            ssidDataHex: nil,
            bssid: nil,
            rawRSSI: nil,
            security: nil
        ),
        connectionError: .connectionFailed(code: -3906)
    )
    let failureController = WiFiPickerController(service: failureService, permission: MockPermission())
    var failureVisibility: [WiFiPickerVisibilityRequest] = []
    failureController.onVisibilityRequest = { failureVisibility.append($0) }
    failureController.presentManually()
    failureController.connect(to: choice, password: "wrong")
    try await Task.sleep(nanoseconds: 200_000_000)
    if case let .failed(message, _) = failureController.state {
        try expect(message.contains("密码不正确"), "wrong password must have a useful error")
        try expect(!message.contains("wrong"), "connection errors must not echo the submitted password")
    } else {
        throw TestFailure.failed("wrong password must leave the controller in failed state")
    }
    try expect(!failureVisibility.contains(.hide), "connection failure must keep the picker visible")
}

private func runPolicyTests() throws {
    struct Candidate { let name: String; let band: WiFiBand; let rssi: Int }
    func preferred(_ candidates: [Candidate]) -> String? {
        WiFiAccessPointSelector.preferred(
            among: candidates, band: \.band, rssi: \.rssi, stableKey: \.name
        )?.name
    }
    let strong2G = Candidate(name: "2g", band: .band2GHz, rssi: -29)
    try expect(preferred([strong2G, Candidate(name: "5g", band: .band5GHz, rssi: -68)]) == "5g",
               "a usable 5 GHz AP must win over a stronger 2.4 GHz AP")
    try expect(preferred([strong2G, Candidate(name: "6g", band: .band6GHz, rssi: -70)]) == "6g",
               "exactly -70 dBm on 6 GHz still counts as usable")
    try expect(preferred([strong2G, Candidate(name: "5g", band: .band5GHz, rssi: -71)]) == "2g",
               "a 5 GHz AP below -70 dBm must lose to 2.4 GHz")
    try expect(preferred([Candidate(name: "a", band: .band5GHz, rssi: -60),
                          Candidate(name: "b", band: .band5GHz, rssi: -50)]) == "b",
               "the strongest AP wins inside the preferred bands")
    try expect(preferred([]) == nil, "no candidates must select nothing")

    let dualBand = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "strong-2g", bssid: "aa", channel: 1, band: .band2GHz, rssi: -29, saved: true),
            accessPoint(id: "usable-5g", bssid: "bb", rssi: -31, saved: true),
            accessPoint(id: "other", ssid: "Other", hex: "02", rssi: -30)
        ],
        hiddenNetworkCount: 0, scannedAt: .now, sequence: 1
    )
    try expect(dualBand.networks.map(\.rawRSSI) == [-29, -30],
               "the band preference must not change list order or the displayed signal")
    try expect(dualBand.networks[1].showsLock, "a personal network shows the lock")

    for owe in [CWSecurity.OWE, .oweTransition] {
        try expect(WiFiCoreWLANSecurityClassifier.kind(for: owe) == .open, "a linked OWE network joins like open")
        try expect(WiFiCoreWLANSecurityClassifier.kind { $0 == owe } == .open, "a scanned OWE network joins like open")
    }
    try expect(WiFiCoreWLANSecurityClassifier.kind { $0 == .wpa2Personal || $0 == .oweTransition } == .personal,
               "a personal network that also answers for OWE must still ask for its password")
    try expect(WiFiCoreWLANSecurityClassifier.kind { $0 == .WEP } == .other, "WEP must remain unsupported")

    let filtered = WiFiSnapshotBuilder.make(
        from: [
            accessPoint(id: "printer", ssid: "DIRECT-xx-Printer", hex: "01", rssi: -40),
            accessPoint(id: "on-printer", ssid: "DIRECT-AB-Mine", hex: "02", rssi: -41, current: true),
            accessPoint(id: "director", ssid: "DIRECTOR", hex: "03", rssi: -42)
        ],
        hiddenNetworkCount: 0, scannedAt: .now, sequence: 1
    )
    try expect(filtered.networks.map(\.ssid) == ["DIRECT-AB-Mine", "DIRECTOR"],
               "printer hotspots are hidden unless the Mac is on one; only the DIRECT- prefix counts")

    try expect(WiFiSignal.symbolValue(rssi: -54) != WiFiSignal.symbolValue(rssi: -72),
               "-54 and -72 dBm must look different")

    func choice(_ security: WiFiSecurityKind, saved: Bool = false, current: Bool = false) -> WiFiNetworkChoice {
        WiFiNetworkChoice(id: "x", ssid: "X", ssidDataHex: "58", security: security,
                          accessPoints: [accessPoint(id: "x", rssi: -50, security: security)],
                          isSaved: saved, isCurrent: current)!
    }
    try expect(WiFiJoinPolicy.action(for: choice(.open)) == .connectWithoutPassword, "open joins on click")
    try expect(WiFiJoinPolicy.action(for: choice(.personal)) == .askForPassword, "unsaved encrypted asks for a password")
    try expect(WiFiJoinPolicy.action(for: choice(.personal, saved: true)) == .connectWithoutPassword,
               "a saved network is tried without a password first")
    try expect(WiFiJoinPolicy.action(for: choice(.enterprise, saved: true)) == .openSystemSettings,
               "being saved must not make an enterprise network joinable here")
    try expect(WiFiJoinPolicy.action(for: choice(.enterprise)) == .openSystemSettings, "enterprise joins in Settings")
    try expect(WiFiJoinPolicy.action(for: choice(.other)) == .openSystemSettings, "WEP joins in Settings")
    try expect(choice(.open).showsLock == false && choice(.enterprise).showsLock && choice(.other).showsLock,
               "every network with a password or credential shows the same lock, open ones none")
    for rssi in [-34, -60, -72, -90] {
        try expect(WiFiSignal.symbolValue(rssi: rssi) > 0, "a visible network always lights a bar")
    }

    // Nothing the user sees carries a number, a band or an error code.
    let spoken = choice(.personal, current: true).accessibilityLabel(isCurrent: true)
    try expect(spoken == "X，已连接，信号强，需要密码", "VoiceOver hears the name, state, signal and lock: \(spoken)")
    for error: WiFiPickerError in [.scanFailed(code: -3905), .connectionFailed(code: -3999), .powerFailed(code: -3930)] {
        let text = error.localizedDescription
        try expect(!text.contains(where: \.isNumber), "errors carry no code: \(text)")
        try expect(!text.hasSuffix("。"), "errors are phrases: \(text)")
        try expect(!text.contains("CoreWLAN") && !text.contains("macOS"), "errors name no internals: \(text)")
    }
    try expect(WiFiPickerError.powerFailed(code: 1).localizedDescription == "无法打开Wi‑Fi",
               "failing to turn Wi-Fi on must not read as failing to join")
    try expect(WiFiPickerError.connectionFailed(code: -3906).localizedDescription == "密码不正确",
               "a wrong password says so")

    // The permission page has one sentence; only its button follows the state.
    try expect(WiFiPermissionAction(location: .notDetermined) == .request, "not asked yet: ask")
    try expect(WiFiPermissionAction(location: .denied) == .openSettings, "denied: go to Settings")
    try expect(WiFiPermissionAction(location: .servicesDisabled) == .openSettings, "services off: go to Settings")
    try expect(WiFiPermissionAction.request.title == "允许定位", "the request button")
    try expect(WiFiPermissionAction.openSettings.title == "打开定位设置…", "leaving for Settings ends in an ellipsis")

    // A join stays on the list: only the clicked row changes and the others cannot be clicked.
    func row(_ id: String, _ security: WiFiSecurityKind, current: Bool = false) -> WiFiNetworkChoice {
        WiFiNetworkChoice(id: id, ssid: id, ssidDataHex: "58", security: security,
                          accessPoints: [accessPoint(id: id, rssi: -50, security: security)],
                          isSaved: false, isCurrent: current)!
    }
    var inline = WiFiPanelFlow()
    try expect(inline.rowClicked(row("open", .open)) == .join && inline.page == .list, "an open row joins in place")
    try expect(inline.joiningNetworkID == "open" && inline.rowsAreLocked, "the clicked row spins")
    try expect(inline.rowClicked(row("other", .open)) == .ignored, "other rows wait for the join")
    inline.joinFailed(message: "加入超时")
    try expect(inline.rowNotice?.networkID == "open" && inline.rowNotice?.message == "加入超时" && inline.page == .list,
               "a failed row join explains itself under that row")
    try expect(!inline.rowsAreLocked, "a failed join unlocks the list")
    try expect(inline.rowClicked(row("open", .open)) == .join && inline.rowNotice == nil, "a retry clears the reason")
    inline.joinSucceeded()
    try expect(inline.joinedNetworkID == "open" && inline.page == .list, "success just turns the row current")
    try expect(inline.rowClicked(row("open", .open)) == .ignored, "the row that just joined is the current one")

    // Enterprise and WEP rows go straight to Settings and leave no message behind.
    for security in [WiFiSecurityKind.enterprise, .other] {
        var settings = WiFiPanelFlow()
        try expect(settings.rowClicked(row("corp", security)) == .openSettings, "this row opens Settings")
        try expect(settings.join == nil && settings.page == .list && settings.rowNotice == nil,
                   "opening Settings starts no join and writes no message")
    }

    // A wrong password stays on its page with the reason, and the page keeps working.
    var wrong = WiFiPanelFlow()
    let locked = row("locked", .personal)
    try expect(wrong.rowClicked(locked) == .askForPassword && wrong.page == .credentials(locked),
               "an unsaved network asks first")
    wrong.passwordSubmitted()
    try expect(wrong.joiningNetworkID == "locked" && wrong.page == .credentials(locked), "the form waits for the result")
    wrong.joinFailed(message: "密码不正确")
    try expect(wrong.page == .credentials(locked) && wrong.pageNotice == "密码不正确" && wrong.join == nil,
               "a wrong password stays on the page with the reason")
    wrong.passwordSubmitted()
    try expect(wrong.pageNotice == nil, "resubmitting clears the old reason")
    wrong.joinSucceeded()
    try expect(wrong.page == .list && wrong.joinedNetworkID == "locked", "success returns to the list")

    var escaped = WiFiPanelFlow()
    _ = escaped.rowClicked(locked)
    escaped.passwordSubmitted()
    escaped.returnToList()
    try expect(escaped.page == .credentials(locked), "a running join cannot be backed out of")
    escaped.panelClosed()
    try expect(escaped.page == .list && escaped.joiningNetworkID == "locked", "a join outlives the panel")
    escaped.joinFailed(message: "密码不正确")
    try expect(escaped.pageNotice == nil && escaped.page == .list && !escaped.rowsAreLocked,
               "a late failure must not reopen on the password page")

    // The saved row spins like any other; a failed try lands on the page with no reason.
    var savedFlow = WiFiPanelFlow()
    let savedRow = WiFiNetworkChoice(id: "saved", ssid: "saved", ssidDataHex: "58", security: .personal,
                                     accessPoints: [accessPoint(id: "saved", rssi: -50)],
                                     isSaved: true, isCurrent: false)!
    try expect(savedFlow.rowClicked(savedRow) == .join && savedFlow.page == .list, "a saved row joins in place")
    savedFlow.savedNetworkNeedsPassword(savedRow)
    try expect(savedFlow.page == .credentials(savedRow) && savedFlow.pageNotice == nil && savedFlow.rowNotice == nil,
               "the page opens without a reason: the user did nothing wrong")
    savedFlow.passwordSubmitted()
    savedFlow.joinFailed(message: "密码不正确")
    try expect(savedFlow.pageNotice == "密码不正确", "only a password the user typed can be called wrong")

    var hiddenForm = WiFiPanelFlow()
    hiddenForm.openHiddenCredentials()
    hiddenForm.hiddenCredentialsSubmitted()
    try expect(hiddenForm.rowsAreLocked && hiddenForm.joiningNetworkID == nil, "a hidden join has no row to spin")
    hiddenForm.joinFailed(message: "找不到这个网络")
    try expect(hiddenForm.page == .hiddenCredentials && hiddenForm.pageNotice == "找不到这个网络",
               "a hidden join that fails stays on its form")
    try expect(WiFiJoinPolicy.action(for: choice(.personal, current: true)) == .alreadyConnected,
               "clicking the current network must do nothing")

    let connected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: true, ssid: "Office", ssidDataHex: "01",
                                     bssid: nil, rawRSSI: -72, security: .personal)
    let disconnected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: false, ssid: nil, ssidDataHex: nil,
                                        bssid: nil, rawRSSI: nil, security: nil)
    let off = WiFiLinkSnapshot(powerIsOn: false, isAssociated: false, ssid: nil, ssidDataHex: nil,
                               bssid: nil, rawRSSI: nil, security: nil)
    let signal = WiFiStatusIndicator.make(link: connected)
    try expect(signal.symbolName == "wifi" && signal.variableValue == 0.2, "the icon follows the signal")
    let unconnected = WiFiStatusIndicator.make(link: disconnected)
    try expect(unconnected.symbolName == "wifi" && unconnected.variableValue == 0,
               "on but not connected is the empty fan, as in the system")
    try expect(signal != unconnected && signal.variableValue ?? 0 > 0, "connected always lights a bar")
    try expect(WiFiStatusIndicator.make(link: off).symbolName == "wifi.slash", "off shows a slash")
    let strong = WiFiLinkSnapshot(powerIsOn: true, isAssociated: true, ssid: nil, ssidDataHex: nil,
                                  bssid: nil, rawRSSI: -50, security: .personal)
    let withoutPermission = WiFiStatusIndicator.make(link: strong)
    try expect(withoutPermission.symbolName == "wifi" && withoutPermission.variableValue == 1,
               "connected without location permission still shows plain signal bars, never an exclamation mark")
    for link in [connected, disconnected, off, strong] {
        try expect(!WiFiStatusIndicator.make(link: link).symbolName.contains("exclamationmark"),
                   "the menu-bar icon never borrows the system's no-internet mark")
    }
}

@MainActor
private func runBehaviorTests() async throws {
    let ap = accessPoint(id: "target", rssi: -41)
    let snapshot = WiFiSnapshotBuilder.make(from: [ap], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let connected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: true, ssid: "Office", ssidDataHex: "4f6666696365",
                                     bssid: nil, rawRSSI: -41, security: .personal)
    let disconnected = WiFiLinkSnapshot(powerIsOn: true, isAssociated: false, ssid: nil, ssidDataHex: nil,
                                        bssid: nil, rawRSSI: nil, security: nil)

    // The system's cached results paint while the full scan is still running.
    let cachedAP = accessPoint(id: "cached", ssid: "Cached", hex: "01", rssi: -60)
    let cached = WiFiSnapshotBuilder.make(from: [cachedAP], hiddenNetworkCount: 0, scannedAt: .now, sequence: 1)
    let cachedService = MockService(snapshot: snapshot, cachedSnapshot: cached, link: connected,
                                    scanDelayNanoseconds: 400_000_000)
    let cachedController = WiFiPickerController(service: cachedService, permission: MockPermission())
    var sawCachedWhileScanning = false
    cachedController.onStateChange = {
        if case let .scanning(previous) = $0, previous?.networks.first?.ssid == "Cached" { sawCachedWhileScanning = true }
    }
    cachedController.start(manuallyLaunched: true)
    let cachedShown = await eventually(timeout: .seconds(1)) { sawCachedWhileScanning }
    try expect(cachedShown, "cached results must show before the scan finishes")
    let scanReplaced = await eventually(timeout: .seconds(2)) {
        if case let .ready(result) = cachedController.state { return result.networks.first?.ssid == "Office" }
        return false
    }
    try expect(scanReplaced, "the finished scan must replace the cached results")
    cachedController.stop()

    // No auto-show inside the launch grace period, and a real disconnect still shows after it.
    let graceService = MockService(snapshot: snapshot, link: disconnected)
    let graceController = WiFiPickerController(service: graceService, permission: MockPermission())
    graceController.presentationGracePeriod = 0.5
    var graceShows = 0
    graceController.onVisibilityRequest = { if $0 == .show { graceShows += 1 } }
    graceController.start(manuallyLaunched: false)
    try await Task.sleep(nanoseconds: 300_000_000)
    try expect(graceShows == 0, "launch grace must hold back the auto-show")
    let shownAfterGrace = await eventually(timeout: .seconds(7)) { graceShows == 1 }
    try expect(shownAfterGrace, "a disconnect that outlasts the grace period must still show")
    try expect(!graceController.isManuallyPresented, "an auto-show must not count as opened by the user")

    // An auto-shown panel the user touched is no longer closed by reconnecting.
    graceController.userDidInteractWithPicker()
    try expect(graceController.isManuallyPresented, "touching the panel makes it the user's")
    // Still disconnected through at least one more 5-second link check, as while typing a password.
    try await Task.sleep(nanoseconds: 5_500_000_000)
    try expect(graceController.isManuallyPresented, "link checks while still disconnected must keep the panel the user's")
    var graceHides = 0
    graceController.onVisibilityRequest = { if $0 == .hide { graceHides += 1 } }
    await graceService.setLink(connected)
    try await Task.sleep(nanoseconds: 5_500_000_000)
    try expect(graceHides == 0, "reconnecting must not close a panel the user is working in")
    graceController.stop()

    // An auto-shown panel that was never touched still closes on reconnect, and wake adds grace.
    let wakeService = MockService(snapshot: snapshot, link: disconnected)
    let wakeController = WiFiPickerController(service: wakeService, permission: MockPermission())
    wakeController.presentationGracePeriod = 0
    var wakeShows = 0
    var wakeHides = 0
    wakeController.onVisibilityRequest = { if $0 == .show { wakeShows += 1 } else { wakeHides += 1 } }
    wakeController.start(manuallyLaunched: false)
    let wakeShown = await eventually(timeout: .seconds(1)) { wakeShows == 1 }
    try expect(wakeShown, "with no grace a disconnected launch shows at once")
    await wakeService.setLink(connected)
    let wakeHidden = await eventually(timeout: .seconds(7)) { wakeHides == 1 }
    try expect(wakeHidden, "an untouched auto-shown panel closes on reconnect")
    wakeController.presentationGracePeriod = 60
    wakeController.noteSystemDidWake()
    await wakeService.setLink(disconnected)
    try await Task.sleep(nanoseconds: 5_500_000_000)
    try expect(wakeShows == 1, "wake grace must hold back the auto-show")
    wakeController.stop()

    // Losing focus pauses scanning; regaining it resumes with a scan.
    let focusService = MockService(snapshot: snapshot, link: connected)
    let focusController = WiFiPickerController(service: focusService, permission: MockPermission())
    focusController.unfocusedScanPause = 0.1
    focusController.start(manuallyLaunched: true)
    _ = await eventually(timeout: .seconds(1)) {
        if case .ready = focusController.state { return true }
        return false
    }
    focusController.panelFocusDidChange(isFocused: false)
    let paused = await eventually(timeout: .seconds(1)) { focusController.scansArePaused }
    try expect(paused, "scans must pause after losing focus")
    let scansWhenPaused = await focusService.recordedScanCount()
    focusController.refresh()
    try await Task.sleep(nanoseconds: 100_000_000)
    let scansAfterRefresh = await focusService.recordedScanCount()
    try expect(scansAfterRefresh == scansWhenPaused, "a timer refresh must not scan while paused")
    focusController.panelFocusDidChange(isFocused: true)
    try expect(!focusController.scansArePaused, "regaining focus must end the pause")
    focusController.stop()

    // A click while a scan is still running waits for the scan instead of failing as busy.
    let busyService = MockService(snapshot: snapshot, link: connected, scanDelayNanoseconds: 600_000_000)
    await busyService.holdInterfaceWhileScanning()
    let busyController = WiFiPickerController(service: busyService, permission: MockPermission())
    var busyStates: [WiFiPickerState] = []
    busyController.onStateChange = { busyStates.append($0) }
    busyController.start(manuallyLaunched: true)
    let busyScanStarted = await eventually(timeout: .seconds(1)) {
        if case .scanning = busyController.state { return true }
        return false
    }
    try expect(busyScanStarted, "the busy-interface test must start while a scan runs")
    let busyChoice = WiFiNetworkChoice(id: "busy", ssid: "Office", ssidDataHex: "4f6666696365", security: .personal,
                                       accessPoints: [ap], isSaved: false, isCurrent: false)!
    busyController.connect(to: busyChoice, password: "temporary-test-password")
    let busyJoined = await eventually(timeout: .seconds(5)) { containsConnectedState(busyStates) }
    try expect(busyJoined, "a join during a scan must wait for the scan and then connect")
    try expect(!busyStates.contains { if case .failed = $0 { return true }; return false },
               "a join during a scan must not report the interface as busy")
    busyController.stop()

    // A powered-off radio is its own state, and turning it on scans again.
    let offLink = WiFiLinkSnapshot(powerIsOn: false, isAssociated: false, ssid: nil, ssidDataHex: nil,
                                   bssid: nil, rawRSSI: nil, security: nil)
    let offService = MockService(snapshot: snapshot, link: offLink, scanError: .wifiPoweredOff)
    let offController = WiFiPickerController(service: offService, permission: MockPermission())
    offController.start(manuallyLaunched: true)
    let reachedOff = await eventually(timeout: .seconds(1)) { offController.state == .poweredOff }
    try expect(reachedOff, "Wi-Fi off must not read as a generic scan failure")
    await offService.clearScanError()
    offController.turnWiFiOn()
    let scannedAfterOn = await eventually(timeout: .seconds(2)) {
        if case .ready = offController.state { return true }
        return false
    }
    try expect(scannedAfterOn, "turning Wi-Fi on must scan again")
    offController.stop()

    let failService = MockService(snapshot: snapshot, link: connected, scanError: .scanTimedOut)
    let failController = WiFiPickerController(service: failService, permission: MockPermission())
    failController.start(manuallyLaunched: true)
    let reachedFailed = await eventually(timeout: .seconds(1)) {
        if case .failed = failController.state { return true }
        return false
    }
    try expect(reachedFailed, "a scan failure with nothing cached must surface as failed, not still scanning")
    failController.stop()
}

do {
    try runTests()
    try runPolicyTests()
} catch {
    fputs("WiFiPickerModelTests failed: \(error)\n", stderr)
    exit(1)
}

Task { @MainActor in
    do {
        try await runSavedNetworkTests()
        try await runPresentationTests()
        try await runControllerTests()
        try await runBehaviorTests()
        print("WiFiPickerModelTests: all tests passed")
        exit(0)
    } catch {
        fputs("WiFiPickerModelTests failed: \(error)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
