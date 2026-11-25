import Foundation

public enum WiFiSecurityKind: String, CaseIterable, Codable, Sendable {
    case open
    case personal
    case enterprise
    case other

    public var displayName: String {
        switch self {
        case .open: return "开放"
        case .personal: return "需要密码"
        case .enterprise: return "企业网络"
        case .other: return "旧式加密"
        }
    }

    public var canUsePasswordField: Bool {
        self == .open || self == .personal
    }
}

public enum WiFiBand: String, Codable, Sendable {
    case band2GHz = "2.4 GHz"
    case band5GHz = "5 GHz"
    case band6GHz = "6 GHz"
    case unknown = "频段未知"
}

public struct WiFiAccessPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let ssid: String
    public let ssidDataHex: String
    public let bssid: String?
    public let channel: Int
    public let band: WiFiBand
    public let rawRSSI: Int
    public let security: WiFiSecurityKind
    public let isSaved: Bool
    public let isCurrent: Bool

    public init(
        id: String,
        ssid: String,
        ssidDataHex: String,
        bssid: String?,
        channel: Int,
        band: WiFiBand,
        rawRSSI: Int,
        security: WiFiSecurityKind,
        isSaved: Bool,
        isCurrent: Bool
    ) {
        self.id = id
        self.ssid = ssid
        self.ssidDataHex = ssidDataHex
        self.bssid = bssid
        self.channel = channel
        self.band = band
        self.rawRSSI = rawRSSI
        self.security = security
        self.isSaved = isSaved
        self.isCurrent = isCurrent
    }
}

public struct WiFiNetworkChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let ssid: String
    public let ssidDataHex: String
    public let security: WiFiSecurityKind
    public let accessPoints: [WiFiAccessPoint]
    public let isSaved: Bool
    public let isCurrent: Bool

    public init?(
        id: String,
        ssid: String,
        ssidDataHex: String,
        security: WiFiSecurityKind,
        accessPoints: [WiFiAccessPoint],
        isSaved: Bool,
        isCurrent: Bool
    ) {
        guard !accessPoints.isEmpty else { return nil }
        self.id = id
        self.ssid = ssid
        self.ssidDataHex = ssidDataHex
        self.security = security
        self.accessPoints = accessPoints.sorted { lhs, rhs in
            if lhs.rawRSSI != rhs.rawRSSI { return lhs.rawRSSI > rhs.rawRSSI }
            return lhs.id < rhs.id
        }
        self.isSaved = isSaved
        self.isCurrent = isCurrent
    }

    public var strongestAccessPoint: WiFiAccessPoint { accessPoints[0] }
    public var rawRSSI: Int { strongestAccessPoint.rawRSSI }
}

public struct WiFiScanSnapshot: Equatable, Sendable {
    public let networks: [WiFiNetworkChoice]
    public let hiddenNetworkCount: Int
    public let scannedAt: Date
    public let sequence: UInt64

    public init(
        networks: [WiFiNetworkChoice],
        hiddenNetworkCount: Int,
        scannedAt: Date,
        sequence: UInt64
    ) {
        self.networks = networks
        self.hiddenNetworkCount = hiddenNetworkCount
        self.scannedAt = scannedAt
        self.sequence = sequence
    }
}

public struct WiFiLinkSnapshot: Equatable, Sendable {
    public let observationIsAvailable: Bool
    public let powerIsOn: Bool
    public let isAssociated: Bool
    public let ssid: String?
    public let ssidDataHex: String?
    public let bssid: String?
    public let rawRSSI: Int?
    public let security: WiFiSecurityKind?

    public init(
        observationIsAvailable: Bool = true,
        powerIsOn: Bool,
        isAssociated: Bool,
        ssid: String?,
        ssidDataHex: String?,
        bssid: String?,
        rawRSSI: Int?,
        security: WiFiSecurityKind?
    ) {
        self.observationIsAvailable = observationIsAvailable
        self.powerIsOn = powerIsOn
        self.isAssociated = isAssociated
        self.ssid = ssid
        self.ssidDataHex = ssidDataHex
        self.bssid = bssid
        self.rawRSSI = rawRSSI
        self.security = security
    }
}

public struct WiFiAssociationTarget: Equatable, Sendable {
    public let ssidDataHex: String
    public let security: WiFiSecurityKind

    public init(ssidDataHex: String, security: WiFiSecurityKind) {
        self.ssidDataHex = ssidDataHex
        self.security = security
    }
}

public enum WiFiPickerError: LocalizedError, Equatable, Sendable {
    case noInterface
    case wifiPoweredOff
    case networkNoLongerVisible
    case invalidSSID
    case passwordRequired
    case requiresSystemSettings
    case scanTimedOut
    case operationInProgress
    case scanFailed(code: Int)
    case connectionFailed(code: Int)
    case connectionTimedOut
    case powerFailed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .noInterface: return "未找到Wi‑Fi硬件"
        case .wifiPoweredOff: return "Wi‑Fi已关闭"
        case .networkNoLongerVisible: return "找不到这个网络"
        case .invalidSSID: return "网络名称最长 32 字节（约 10 个汉字）"
        case .passwordRequired: return "这个网络需要密码"
        // Rows of these networks open Settings directly; only a typed hidden name reaches this text.
        case .requiresSystemSettings: return "需要在“Wi‑Fi设置”中加入"
        case .scanTimedOut: return "无法扫描"
        case .operationInProgress: return "Wi‑Fi正忙"
        case .scanFailed: return "无法扫描"
        case let .connectionFailed(code):
            switch code {
            case -3906: return "密码不正确"
            case -3905: return "找不到这个网络"
            case -3908: return "加入超时"
            case -3903: return "认证失败"
            case -3931: return "已经连接到这个Wi‑Fi"
            default: return "无法加入"
            }
        case .connectionTimedOut: return "加入超时"
        case .powerFailed: return "无法打开Wi‑Fi"
        }
    }
}

public enum WiFiAssociationVerifier {
    /// BSSID and internet reachability are intentionally absent: roaming and
    /// captive/local-only Wi-Fi must not prevent a successful association.
    public static func matchesTarget(_ link: WiFiLinkSnapshot, target: WiFiAssociationTarget) -> Bool {
        link.observationIsAvailable
            && link.isAssociated
            && link.ssidDataHex == target.ssidDataHex
            && link.security == target.security
    }
}

/// Marks a matching network group; missing BSSID does not identify an exact AP.
public enum WiFiCurrentNetworkMatcher {
    public static func matches(
        _ link: WiFiLinkSnapshot,
        ssidDataHex: String,
        security: WiFiSecurityKind,
        bssid: String?
    ) -> Bool {
        guard link.observationIsAvailable, link.powerIsOn, link.isAssociated,
              !ssidDataHex.isEmpty, link.ssidDataHex == ssidDataHex,
              link.security == security else { return false }
        if let currentBSSID = link.bssid, let bssid {
            return currentBSSID.caseInsensitiveCompare(bssid) == .orderedSame
        }
        return true
    }
}

public enum WiFiHiddenNetworkPolicy {
    public static func selectedSecurity(
        available: Set<WiFiSecurityKind>,
        hasPassword: Bool
    ) throws -> WiFiSecurityKind {
        if hasPassword {
            if available.contains(.personal) { return .personal }
            if available.contains(.open) { return .open }
        } else {
            if available.contains(.open) { return .open }
            if available.contains(.personal) { throw WiFiPickerError.passwordRequired }
        }
        if available.contains(.enterprise) || available.contains(.other) {
            throw WiFiPickerError.requiresSystemSettings
        }
        throw WiFiPickerError.networkNoLongerVisible
    }
}

public enum WiFiDisconnectPresentationPolicy {
    public static func shouldPresent(
        previousAssociation: Bool?,
        isAssociated: Bool,
        disconnectedFor: TimeInterval,
        suppressionIsActive: Bool,
        forcedByUser: Bool
    ) -> Bool {
        if forcedByUser { return true }
        guard !isAssociated, !suppressionIsActive else { return false }
        if previousAssociation == nil { return true }
        return disconnectedFor >= 1.5
    }
}

/// Picks the AP to associate with inside one network. List order never uses this:
/// rows stay sorted by raw RSSI, and only the join prefers a faster band.
public enum WiFiAccessPointSelector {
    public static let highBandMinimumRSSI = -70

    public static func preferred<Candidate>(
        among candidates: [Candidate],
        band: (Candidate) -> WiFiBand,
        rssi: (Candidate) -> Int,
        stableKey: (Candidate) -> String
    ) -> Candidate? {
        let strongestFirst = candidates.sorted { lhs, rhs in
            if rssi(lhs) != rssi(rhs) { return rssi(lhs) > rssi(rhs) }
            return stableKey(lhs) < stableKey(rhs)
        }
        let usableHighBand = strongestFirst.first {
            (band($0) == .band5GHz || band($0) == .band6GHz) && rssi($0) >= highBandMinimumRSSI
        }
        return usableHighBand ?? strongestFirst.first
    }
}

public enum WiFiNoiseFilter {
    /// Wi-Fi Direct printer hotspots are never what the user came to join.
    /// The network the Mac is actually on stays visible whatever its name.
    public static func isPrinterHotspot(_ accessPoint: WiFiAccessPoint) -> Bool {
        accessPoint.ssid.hasPrefix("DIRECT-") && !accessPoint.isCurrent
    }
}

public enum WiFiSignal {
    /// The `wifi` symbol lights its dot above 0, the inner arc above 1/3 and the outer arc
    /// above 2/3. A network that can be seen always lights one bar: an empty fan means "not
    /// connected", in the menu bar and in the system's own menu.
    public static func symbolValue(rssi: Int) -> Double {
        switch rssi {
        case (-58)...: return 1
        case (-68)...: return 0.5
        default: return 0.2
        }
    }

    public static func accessibilityText(rssi: Int) -> String {
        switch symbolValue(rssi: rssi) {
        case 1: return "信号强"
        case 0.5: return "信号中等"
        default: return "信号弱"
        }
    }
}

extension WiFiNetworkChoice {
    /// A row shows the signal, the name and, when there is a password to deal with, one lock.
    public var showsLock: Bool { security != .open }

    /// VoiceOver cannot see the disc, the bars or the lock, so it hears them here.
    public func accessibilityLabel(isCurrent: Bool) -> String {
        var parts = [ssid]
        if isCurrent { parts.append("已连接") }
        parts.append(WiFiSignal.accessibilityText(rssi: rawRSSI))
        if showsLock { parts.append(security.displayName) }
        return parts.joined(separator: "，")
    }
}

/// The permission page says one sentence in every case and only its button changes.
public enum WiFiPermissionAction: Equatable, Sendable {
    case request
    case openSettings

    public static let message = "允许定位以显示网络名称"

    public init(location: WiFiLocationState) {
        self = location == .notDetermined ? .request : .openSettings
    }

    public var title: String {
        switch self {
        case .request: return "允许定位"
        case .openSettings: return "打开定位设置…"
        }
    }
}

public enum WiFiJoinAction: Equatable, Sendable {
    case alreadyConnected
    case openSystemSettings
    case connectWithoutPassword
    case askForPassword
}

public enum WiFiJoinPolicy {
    public static func action(for network: WiFiNetworkChoice) -> WiFiJoinAction {
        if network.isCurrent { return .alreadyConnected }
        switch network.security {
        case .open: return .connectWithoutPassword
        // A saved network is tried without a password first; any failure falls back to the page.
        case .personal: return network.isSaved ? .connectWithoutPassword : .askForPassword
        case .enterprise, .other: return .openSystemSettings
        }
    }
}

public struct WiFiStatusIndicator: Equatable, Sendable {
    public let symbolName: String
    public let variableValue: Double?
    public let accessibilityLabel: String

    public init(symbolName: String, variableValue: Double? = nil, accessibilityLabel: String) {
        self.symbolName = symbolName
        self.variableValue = variableValue
        self.accessibilityLabel = accessibilityLabel
    }

    /// Menu-bar state from the existing 5-second link check; never triggers a scan.
    /// Same symbols as the system: slash is off, an empty fan is on but not connected. The
    /// location permission does not show here: the system reads an exclamation mark as "no
    /// internet", and the panel itself opens on the permission page when it is needed.
    public static func make(link: WiFiLinkSnapshot) -> WiFiStatusIndicator {
        guard link.powerIsOn else {
            return WiFiStatusIndicator(symbolName: "wifi.slash", accessibilityLabel: "Wi‑Fi已关闭")
        }
        guard link.isAssociated else {
            return WiFiStatusIndicator(symbolName: "wifi", variableValue: 0, accessibilityLabel: "Wi‑Fi未连接")
        }
        return WiFiStatusIndicator(
            symbolName: "wifi",
            variableValue: WiFiSignal.symbolValue(rssi: link.rawRSSI ?? -100),
            accessibilityLabel: "Wi‑Fi已连接"
        )
    }
}

/// Which page the panel shows and what a join in flight means for it. Free of AppKit, so the
/// routing is tested directly. A join is not a page: the list or the form stays on screen.
public struct WiFiPanelFlow: Equatable, Sendable {
    public enum Page: Equatable, Sendable {
        case list
        case credentials(WiFiNetworkChoice)
        case hiddenCredentials
        case permission
    }

    public enum Join: Equatable, Sendable {
        case row(WiFiNetworkChoice)
        case password(WiFiNetworkChoice)
        case hidden
    }

    public enum Click: Equatable, Sendable {
        case ignored
        case join
        case askForPassword
        case openSettings
    }

    public struct RowNotice: Equatable, Sendable {
        public let networkID: String
        public let message: String
    }

    public private(set) var page: Page = .list
    public private(set) var join: Join?
    public private(set) var rowNotice: RowNotice?
    public private(set) var pageNotice: String?
    /// The row that just joined reads as current until the panel closes, without a new scan.
    public private(set) var joinedNetworkID: String?

    public init() {}

    public var rowsAreLocked: Bool { join != nil }

    public var joiningNetworkID: String? {
        switch join {
        case let .row(network), let .password(network): return network.id
        case .hidden, nil: return nil
        }
    }

    public mutating func rowClicked(_ network: WiFiNetworkChoice) -> Click {
        guard page == .list, join == nil, network.id != joinedNetworkID else { return .ignored }
        switch WiFiJoinPolicy.action(for: network) {
        case .alreadyConnected:
            return .ignored
        case .openSystemSettings:
            rowNotice = nil
            return .openSettings
        case .connectWithoutPassword:
            rowNotice = nil
            join = .row(network)
            return .join
        case .askForPassword:
            rowNotice = nil
            page = .credentials(network)
            pageNotice = nil
            return .askForPassword
        }
    }

    public mutating func openHiddenCredentials() {
        guard join == nil else { return }
        rowNotice = nil
        pageNotice = nil
        page = .hiddenCredentials
    }

    public mutating func passwordSubmitted() {
        guard case let .credentials(network) = page, join == nil else { return }
        pageNotice = nil
        join = .password(network)
    }

    public mutating func hiddenCredentialsSubmitted() {
        guard page == .hiddenCredentials, join == nil else { return }
        pageNotice = nil
        join = .hidden
    }

    public mutating func returnToList() {
        guard join == nil else { return }
        page = .list
        pageNotice = nil
    }

    /// A wrong password stays on its page, with the reason under the field. Failing on a form
    /// the panel has since left has nowhere useful to say so.
    public mutating func joinFailed(message: String) {
        switch join {
        case let .row(network):
            rowNotice = RowNotice(networkID: network.id, message: message)
        case let .password(network):
            if page == .credentials(network) { pageNotice = message }
        case .hidden:
            if page == .hiddenCredentials { pageNotice = message }
        case nil:
            break
        }
        join = nil
    }

    /// The try without a password failed. The page says nothing: the user did nothing wrong.
    public mutating func savedNetworkNeedsPassword(_ network: WiFiNetworkChoice) {
        join = nil
        rowNotice = nil
        pageNotice = nil
        page = .credentials(network)
    }

    public mutating func joinSucceeded() {
        joinedNetworkID = joiningNetworkID
        join = nil
        page = .list
        rowNotice = nil
        pageNotice = nil
    }

    public mutating func permissionChanged(required: Bool) {
        if required {
            page = .permission
            rowNotice = nil
            pageNotice = nil
        } else if page == .permission {
            page = .list
        }
    }

    /// A join CoreWLAN cannot cancel outlives the panel, so reopening still shows it.
    public mutating func panelClosed() {
        page = .list
        rowNotice = nil
        pageNotice = nil
        joinedNetworkID = nil
    }
}

public enum WiFiSnapshotBuilder {
    public static func make(
        from observations: [WiFiAccessPoint],
        hiddenNetworkCount: Int,
        scannedAt: Date,
        sequence: UInt64
    ) -> WiFiScanSnapshot {
        let visible = observations.filter {
            !$0.ssid.isEmpty && !$0.ssidDataHex.isEmpty && !WiFiNoiseFilter.isPrinterHotspot($0)
        }
        let grouped = Dictionary(grouping: visible) {
            $0.ssidDataHex + "|" + $0.security.rawValue
        }

        let choices = grouped.map { key, accessPoints -> WiFiNetworkChoice in
            let deduplicated = Dictionary(grouping: accessPoints, by: \.id).compactMap { _, values in
                values.max { lhs, rhs in
                    if lhs.rawRSSI != rhs.rawRSSI { return lhs.rawRSSI < rhs.rawRSSI }
                    return lhs.id > rhs.id
                }
            }
            let sortedAPs = deduplicated.sorted(by: accessPointComesFirst)
            let representative = sortedAPs[0]
            return WiFiNetworkChoice(
                id: stableHash(key),
                ssid: representative.ssid,
                ssidDataHex: representative.ssidDataHex,
                security: representative.security,
                accessPoints: sortedAPs,
                isSaved: sortedAPs.contains(where: \.isSaved),
                isCurrent: sortedAPs.contains(where: \.isCurrent)
            )!
        }.sorted(by: networkComesFirst)

        return WiFiScanSnapshot(
            networks: choices,
            hiddenNetworkCount: hiddenNetworkCount,
            scannedAt: scannedAt,
            sequence: sequence
        )
    }

    public static func accessPointID(
        ssidDataHex: String,
        security: WiFiSecurityKind,
        bssid: String?,
        channel: Int,
        band: WiFiBand
    ) -> String {
        let normalizedBSSID = bssid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedBSSID, !normalizedBSSID.isEmpty {
            return stableHash("\(ssidDataHex)|\(security.rawValue)|bssid=\(normalizedBSSID)")
        }
        return stableHash("\(ssidDataHex)|\(security.rawValue)|channel=\(channel)|band=\(band.rawValue)")
    }

    public static func dataHex(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(fromHex value: String) -> Data? {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return nil }
        var output = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }

    private static func accessPointComesFirst(_ lhs: WiFiAccessPoint, _ rhs: WiFiAccessPoint) -> Bool {
        if lhs.rawRSSI != rhs.rawRSSI { return lhs.rawRSSI > rhs.rawRSSI }
        return lhs.id < rhs.id
    }

    private static func networkComesFirst(_ lhs: WiFiNetworkChoice, _ rhs: WiFiNetworkChoice) -> Bool {
        if lhs.rawRSSI != rhs.rawRSSI { return lhs.rawRSSI > rhs.rawRSSI }
        let nameOrder = lhs.ssid.localizedStandardCompare(rhs.ssid)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.security.rawValue != rhs.security.rawValue {
            return lhs.security.rawValue < rhs.security.rawValue
        }
        if lhs.ssidDataHex != rhs.ssidDataHex { return lhs.ssidDataHex < rhs.ssidDataHex }
        return lhs.id < rhs.id
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
