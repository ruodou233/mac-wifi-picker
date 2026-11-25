@preconcurrency import CoreWLAN
import Foundation

/// Shares CoreWLAN security categories between scan results and current links.
public enum WiFiCoreWLANSecurityClassifier {
    public static func kind(for security: CWSecurity) -> WiFiSecurityKind? {
        switch security {
        // OWE (enhanced open) encrypts the air but asks for no password, so it joins like open.
        case .none, .OWE, .oweTransition: return .open
        case .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition, .personal:
            return .personal
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise:
            return .enterprise
        case .unknown: return nil
        default: return .other
        }
    }

    public static func kind(supports: (CWSecurity) -> Bool) -> WiFiSecurityKind {
        if supports(.none) { return .open }
        if [.wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise]
            .contains(where: supports) { return .enterprise }
        if [.wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition, .personal]
            .contains(where: supports) { return .personal }
        if supports(.OWE) || supports(.oweTransition) { return .open }
        return .other
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false

    func resolve(
        _ result: Result<Value, Error>,
        continuation: CheckedContinuation<Value, Error>
    ) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class ValueContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false

    func resolve(_ value: Value, continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

private final class ExclusiveOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func end() {
        lock.lock()
        isBusy = false
        lock.unlock()
    }
}

public protocol WiFiServicing: Sendable {
    func scan() async throws -> WiFiScanSnapshot
    /// What macOS already remembers from its last scan; instant, may be empty or a little old.
    func cachedScan() async -> WiFiScanSnapshot?
    func setPower(on: Bool) async throws
    func currentLink() async -> WiFiLinkSnapshot
    func associate(to choice: WiFiNetworkChoice, password: String?) async throws
    func resolveHiddenTarget(ssid: String, password: String?) async throws -> WiFiAssociationTarget
    func associateHidden(to target: WiFiAssociationTarget, password: String?) async throws
}

/// Isolates blocking scan/association work from low-cost link observation.
/// Public callers only see immutable value snapshots, so this module can later
/// be embedded in a larger app without leaking CoreWLAN reference types.
public final class CoreWLANWiFiService: WiFiServicing, @unchecked Sendable {
    private let operationQueue = DispatchQueue(label: "io.github.ruodou233.MacWiFiPicker.corewlan.operation", qos: .userInitiated)
    private let observationQueue = DispatchQueue(label: "io.github.ruodou233.MacWiFiPicker.corewlan.observation", qos: .utility)
    private let client = CWWiFiClient.shared()
    private let observationClient = CWWiFiClient()
    private let operationGate = ExclusiveOperationGate()
    private let observationGate = ExclusiveOperationGate()
    private var sequence: UInt64 = 0

    public init() {}

    public func scan() async throws -> WiFiScanSnapshot {
        try await perform(timeout: 12, timeoutError: .scanTimedOut) { [self] in
            guard let interface = client.interface() else { throw WiFiPickerError.noInterface }
            guard interface.powerOn() else { throw WiFiPickerError.wifiPoweredOff }

            let rawNetworks: Set<CWNetwork>
            do {
                rawNetworks = try interface.scanForNetworks(withSSID: nil, includeHidden: true)
            } catch {
                throw mapScanError(error)
            }
            return snapshot(from: rawNetworks, interface: interface)
        }
    }

    public func cachedScan() async -> WiFiScanSnapshot? {
        try? await perform(timeout: 2, timeoutError: .scanTimedOut) { [self] in
            guard let interface = client.interface(), interface.powerOn(),
                  let cached = interface.cachedScanResults(), !cached.isEmpty else { return nil }
            return snapshot(from: cached, interface: interface)
        }
    }

    public func setPower(on: Bool) async throws {
        try await perform(timeout: 10, timeoutError: .operationInProgress) { [self] in
            guard let interface = client.interface() else { throw WiFiPickerError.noInterface }
            do {
                try interface.setPower(on)
            } catch {
                throw WiFiPickerError.powerFailed(code: (error as NSError).code)
            }
        }
    }

    private func snapshot(from rawNetworks: Set<CWNetwork>, interface: CWInterface) -> WiFiScanSnapshot {
        let currentLink = linkSnapshot(for: interface)
        let savedSSIDs = Set(
            (interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? [])
                .compactMap { WiFiSnapshotBuilder.dataHex($0.ssidData) }
        )

        var hiddenCount = 0
        var observations: [WiFiAccessPoint] = []
        observations.reserveCapacity(rawNetworks.count)

        for network in rawNetworks {
            let ssid = network.ssid ?? ""
            guard let ssidDataHex = WiFiSnapshotBuilder.dataHex(network.ssidData), !ssid.isEmpty else {
                hiddenCount += 1
                continue
            }
            let rawRSSI = network.rssiValue
            guard rawRSSI != 0 else { continue }
            let security = securityKind(for: network)
            let channel = network.wlanChannel?.channelNumber ?? 0
            let band = bandKind(for: network.wlanChannel)
            let bssid = normalizedBSSID(network.bssid)
            let isCurrent = WiFiCurrentNetworkMatcher.matches(
                currentLink, ssidDataHex: ssidDataHex, security: security, bssid: bssid
            )
            observations.append(
                WiFiAccessPoint(
                    id: WiFiSnapshotBuilder.accessPointID(
                        ssidDataHex: ssidDataHex,
                        security: security,
                        bssid: bssid,
                        channel: channel,
                        band: band
                    ),
                    ssid: ssid,
                    ssidDataHex: ssidDataHex,
                    bssid: bssid,
                    channel: channel,
                    band: band,
                    rawRSSI: rawRSSI,
                    security: security,
                    isSaved: savedSSIDs.contains(ssidDataHex),
                    isCurrent: isCurrent
                )
            )
        }

        sequence &+= 1
        return WiFiSnapshotBuilder.make(
            from: observations,
            hiddenNetworkCount: hiddenCount,
            scannedAt: Date(),
            sequence: sequence
        )
    }

    public func currentLink() async -> WiFiLinkSnapshot {
        let unavailable = WiFiLinkSnapshot(
            observationIsAvailable: false,
            powerIsOn: false,
            isAssociated: false,
            ssid: nil,
            ssidDataHex: nil,
            bssid: nil,
            rawRSSI: nil,
            security: nil
        )
        return await performObservation(timeout: 2, fallback: unavailable) { [self] in
            guard let interface = observationClient.interface() else {
                return WiFiLinkSnapshot(
                    observationIsAvailable: false,
                    powerIsOn: false,
                    isAssociated: false,
                    ssid: nil,
                    ssidDataHex: nil,
                    bssid: nil,
                    rawRSSI: nil,
                    security: nil
                )
            }
            return linkSnapshot(for: interface)
        }
    }

    private func linkSnapshot(for interface: CWInterface) -> WiFiLinkSnapshot {
        let powerIsOn = interface.powerOn()
        let isAssociated = powerIsOn
            && interface.interfaceMode() == .station
            && interface.activePHYMode().rawValue != 0
        let security = interface.security()
        return WiFiLinkSnapshot(
            powerIsOn: powerIsOn,
            isAssociated: isAssociated,
            ssid: interface.ssid(),
            ssidDataHex: WiFiSnapshotBuilder.dataHex(interface.ssidData()),
            bssid: normalizedBSSID(interface.bssid()),
            rawRSSI: isAssociated ? interface.rssiValue() : nil,
            security: isAssociated ? WiFiCoreWLANSecurityClassifier.kind(for: security) : nil
        )
    }

    public func associate(to choice: WiFiNetworkChoice, password: String?) async throws {
        try await perform(timeout: 25, timeoutError: .connectionTimedOut) { [self] in
            guard choice.security.canUsePasswordField else { throw WiFiPickerError.requiresSystemSettings }
            guard let interface = client.interface() else { throw WiFiPickerError.noInterface }
            guard interface.powerOn() else { throw WiFiPickerError.wifiPoweredOff }
            guard let ssidData = WiFiSnapshotBuilder.data(fromHex: choice.ssidDataHex) else {
                throw WiFiPickerError.networkNoLongerVisible
            }

            let networks: Set<CWNetwork>
            do {
                networks = try interface.scanForNetworks(withSSID: ssidData)
            } catch {
                throw mapScanError(error)
            }
            let matchingIdentity = networks.filter {
                WiFiSnapshotBuilder.dataHex($0.ssidData) == choice.ssidDataHex
                    && securityKind(for: $0) == choice.security
            }
            guard let target = preferredNetwork(in: matchingIdentity) else {
                throw WiFiPickerError.networkNoLongerVisible
            }
            // Saved networks go through with no password: macOS may use its stored credential.
            // Apple does not document this, so the caller treats every failure as "ask the user".
            // Nothing here reads the keychain.
            if choice.security == .personal, password?.isEmpty != false, !choice.isSaved {
                throw WiFiPickerError.passwordRequired
            }
            try associate(interface: interface, network: target, password: password)
        }
    }

    public func resolveHiddenTarget(ssid: String, password: String?) async throws -> WiFiAssociationTarget {
        try await perform(timeout: 10, timeoutError: .scanTimedOut) { [self] in
            guard !ssid.isEmpty,
                  ssid.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw WiFiPickerError.invalidSSID
            }
            guard let interface = client.interface() else { throw WiFiPickerError.noInterface }
            guard interface.powerOn() else { throw WiFiPickerError.wifiPoweredOff }
            let ssidData = Data(ssid.utf8)
            guard ssidData.count <= 32 else { throw WiFiPickerError.invalidSSID }
            let networks: Set<CWNetwork>
            do {
                networks = try interface.scanForNetworks(withSSID: ssidData, includeHidden: true)
            } catch {
                throw mapScanError(error)
            }
            let matching = networks.filter { $0.ssidData == ssidData }
            let selectedSecurity = try WiFiHiddenNetworkPolicy.selectedSecurity(
                available: Set(matching.map(securityKind(for:))),
                hasPassword: password?.isEmpty == false
            )
            return WiFiAssociationTarget(
                ssidDataHex: WiFiSnapshotBuilder.dataHex(ssidData) ?? "",
                security: selectedSecurity
            )
        }
    }

    public func associateHidden(to target: WiFiAssociationTarget, password: String?) async throws {
        try await perform(timeout: 15, timeoutError: .connectionTimedOut) { [self] in
            guard target.security.canUsePasswordField else {
                throw WiFiPickerError.requiresSystemSettings
            }
            if target.security == .personal, password?.isEmpty != false {
                throw WiFiPickerError.passwordRequired
            }
            guard let interface = client.interface() else { throw WiFiPickerError.noInterface }
            guard interface.powerOn() else { throw WiFiPickerError.wifiPoweredOff }
            guard let ssidData = WiFiSnapshotBuilder.data(fromHex: target.ssidDataHex) else {
                throw WiFiPickerError.invalidSSID
            }
            let networks: Set<CWNetwork>
            do {
                networks = try interface.scanForNetworks(withSSID: ssidData, includeHidden: true)
            } catch {
                throw mapScanError(error)
            }
            let candidates = networks.filter {
                $0.ssidData == ssidData && securityKind(for: $0) == target.security
            }
            guard let network = preferredNetwork(in: candidates) else {
                throw WiFiPickerError.networkNoLongerVisible
            }
            try associate(
                interface: interface,
                network: network,
                password: target.security == .personal ? password : nil
            )
        }
    }

    private func preferredNetwork(in networks: Set<CWNetwork>) -> CWNetwork? {
        WiFiAccessPointSelector.preferred(
            among: Array(networks),
            band: { bandKind(for: $0.wlanChannel) },
            rssi: \.rssiValue,
            stableKey: networkStableKey
        )
    }

    private func networkStableKey(_ network: CWNetwork) -> String {
        let channel = network.wlanChannel?.channelNumber ?? 0
        return [
            WiFiSnapshotBuilder.dataHex(network.ssidData) ?? "",
            normalizedBSSID(network.bssid) ?? "",
            securityKind(for: network).rawValue,
            String(format: "%04d", channel)
        ].joined(separator: "|")
    }

    private func associate(interface: CWInterface, network: CWNetwork, password: String?) throws {
        do {
            try interface.associate(to: network, password: password)
        } catch {
            let nsError = error as NSError
            if nsError.code == -3931 { return }
            throw WiFiPickerError.connectionFailed(code: nsError.code)
        }
    }

    private func securityKind(for network: CWNetwork) -> WiFiSecurityKind {
        WiFiCoreWLANSecurityClassifier.kind { network.supportsSecurity($0) }
    }

    private func bandKind(for channel: CWChannel?) -> WiFiBand {
        guard let channel else { return .unknown }
        switch channel.channelBand {
        case .band2GHz: return .band2GHz
        case .band5GHz: return .band5GHz
        case .band6GHz: return .band6GHz
        default: return .unknown
        }
    }

    private func normalizedBSSID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func mapScanError(_ error: Error) -> WiFiPickerError {
        WiFiPickerError.scanFailed(code: (error as NSError).code)
    }

    private func perform<T: Sendable>(
        timeout: TimeInterval,
        timeoutError: WiFiPickerError,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        guard operationGate.begin() else { throw WiFiPickerError.operationInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<T>()
            operationQueue.async { [operationGate] in
                let result: Result<T, Error>
                do { result = .success(try operation()) }
                catch { result = .failure(error) }
                // A resumed task may immediately submit the next operation.
                // Release exclusivity before resuming to avoid a false busy race.
                operationGate.end()
                gate.resolve(result, continuation: continuation)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resolve(.failure(timeoutError), continuation: continuation)
            }
        }
    }

    private func performObservation<T: Sendable>(
        timeout: TimeInterval,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        guard observationGate.begin() else { return fallback }
        return await withCheckedContinuation { continuation in
            let gate = ValueContinuationGate<T>()
            observationQueue.async { [observationGate] in
                let value = operation()
                observationGate.end()
                gate.resolve(value, continuation: continuation)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resolve(fallback, continuation: continuation)
            }
        }
    }
}
