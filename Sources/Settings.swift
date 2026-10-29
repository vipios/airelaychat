import SwiftUI

// MARK: - 网络环境（在家 / 在外 / 未知）

enum NetPlace: String, Codable {
    case home = "在家"
    case away = "在外"
    case unknown = "检测中"

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .away: return "antenna.radiowaves.left.and.right"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - 持久化配置

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var lanHost: String { didSet { store() } }
    @Published var publicAddrs: [String] { didSet { store() } }
    @Published var gatewayKey: String { didSet { store() } }
    @Published var homeModel: String { didSet { store() } }
    @Published var awayModel: String { didSet { store() } }
    @Published var port: Int { didSet { store() } }
    @Published var gistId: String { didSet { store() } }
    @Published var gistOwner: String { didSet { store() } }

    private let key = "airelay.settings.v1"

    private struct Stored: Codable {
        var lanHost: String
        var publicAddrs: [String]
        var gatewayKey: String
        var homeModel: String
        var awayModel: String
        var port: Int
        var gistId: String
        var gistOwner: String?
    }

    private init() {
        let d = UserDefaults.standard.data(forKey: key)
        let s = d.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        lanHost = s?.lanHost ?? "192.168.2.1"
        publicAddrs = s?.publicAddrs ?? []
        gatewayKey = s?.gatewayKey ?? ""
        homeModel = s?.homeModel ?? ""
        awayModel = s?.awayModel ?? ""
        port = s?.port ?? 8080
        gistId = s?.gistId ?? "a96bdb5d96de46975334ca3276476901"
        gistOwner = s?.gistOwner ?? "vipios"
    }

    private func store() {
        let s = Stored(lanHost: lanHost, publicAddrs: publicAddrs, gatewayKey: gatewayKey,
                       homeModel: homeModel, awayModel: awayModel, port: port,
                       gistId: gistId, gistOwner: gistOwner)
        if let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    /// 内网基地址
    var lanBase: String { "http://\(lanHost):\(port)" }

    /// 按顺序要试的外网地址
    var publicBases: [String] {
        publicAddrs.map { "http://[\($0)]:\(port)" }
    }
}
