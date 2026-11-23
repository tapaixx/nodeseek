import XCTest
import SwiftUI
@testable import nodeseek

@MainActor
final class TradeWorkspaceLayoutTests: XCTestCase {
    func testMarketplaceAccountAndEscrowRenderInDarkAndLargeType() async throws {
        let api = WorkspaceStub()
        let data = #"{"agents":[{"id":9,"username":"Intermediary with a long display name","completed":19,"profile":{"online_status":"online","fee_rate":"5","fee_min":"10","fee_cap":"100","other_info":"Long description for wrapping and Dynamic Type"},"reputation":{"score":5,"reviews":27,"agent":{"cancel_rate":0,"response_seconds":420}}}],"tasks":[{"id":5,"title":"托管交易标题与比较长的商品描述","details":"Public description without any account credentials","price":"350","agent_fee":"20","status":"taken","seller":{"username":"Seller"},"agent":{"username":"Intermediary"},"created_at":"2026-11-23T12:34:56Z"}],"task":{"id":5,"title":"托管交易标题与比较长的商品描述","details":"Public description without account credentials","price":"350","agent_fee":"20","fee_payer":"seller","delivery_method":"official_push","status":"taken","seller":{"username":"Seller"},"agent":{"username":"Intermediary"},"can_view_goods":false,"can_accept":false,"can_cancel":false,"created_at":"2026-11-23T12:34:56Z"},"totals":{"trades":26,"amount":"25449.84","avg_price":"978.84"},"series":[{"day":"2026-11-23","completed":4}],"hot":[],"user":{"id":1,"username":"User","role":"user"}}"#
        api.response = try JSONDecoder().decode(TradeValue.self, from: Data(data.utf8))
        let home = TradeHomeModel(api: LayoutTradeStub())
        await home.load()
        let operation = TradeForms.escrow(agents: [.init(id: 9, username: "Intermediary")])
        let cases: [(String, AnyView)] = [
            ("workspace", AnyView(TradeWorkspaceView(home: home, api: api))),
            ("agents", AnyView(TradeCollectionPage(destination: .init(kind: "agents", title: "中介"), api: api, home: home, open: { _ in }))),
            ("escrow", AnyView(TradeCollectionPage(destination: .init(kind: "escrow", title: "托管售卖"), api: api, home: home, open: { _ in }))),
            ("escrow-detail", AnyView(TradeEscrowDetailView(api: api, taskID: "5", home: home))),
            ("publish", AnyView(TradeOperationView(operation: operation, api: api, onComplete: { _ in }))),
            ("calculator", AnyView(TradeCalculatorView(api: api)))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodeseek-trade-workspace-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, view) in cases {
            for (variant, style, size) in [("light", UIUserInterfaceStyle.light, UIContentSizeCategory.large), ("dark-large", .dark, .accessibilityExtraExtraExtraLarge)] {
                let host = UIHostingController(rootView: view.tradeTypography())
                host.overrideUserInterfaceStyle = style
                let navigation = UINavigationController(rootViewController: host)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.rootViewController = navigation
                navigation.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: size), forChild: host)
                window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 650_000_000)
                window.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { context in window.layer.render(in: context.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = name + "-" + variant; attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: directory.appendingPathComponent(name + "-" + variant + ".png"))
                XCTAssertFalse(host.view.bounds.isEmpty)
                window.isHidden = true
            }
        }
        print("Workspace screenshots: \(directory.path)")
    }
}

@MainActor
private final class LayoutTradeStub: TradeServing {
    func currentUser() async throws -> TradeUser? { .init(id: 1, username: "User", role: "user") }
    func conversations() async throws -> [TradeConversation] { [] }
    func agents() async throws -> [TradeUser] { [.init(id: 9, username: "Intermediary")] }
    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64 { 42 }
    func room(id: Int64) async throws -> TradeRoom { throw URLError(.unsupportedURL) }
    func messages(id: Int64, before: Int64?) async throws -> TradeMessagePage { .init(messages: [], hasMore: false) }
    func send(_ text: String, to id: Int64) async throws -> TradeMessage { throw URLError(.unsupportedURL) }
    func send(_ text: String, to id: Int64, replyingTo: Int64) async throws -> TradeMessage { throw URLError(.unsupportedURL) }
    func invitation(for tradeID: Int64) async throws -> URL { TradeAPIClient.webURL }
    func invitation(token: String) async throws -> TradeInvitation { throw URLError(.unsupportedURL) }
    func join(token: String, role: String?) async throws -> Int64 { 42 }
    func perform(_ action: TradeAction, tradeID: Int64) async throws {}
    func updateTerms(_ terms: TradeTerms, tradeID: Int64) async throws {}
    func markRead(conversationID: Int64, messageID: Int64) async throws {}
}
