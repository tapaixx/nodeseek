import UIKit
import XCTest
@testable import nodeseek

@MainActor
final class SeekMailClassificationTests: XCTestCase {
    func testListAndDetailShowFolderAndAllTagNames() async throws {
        let transport = fixture()
        let inbox = makeInbox(transport)
        let window = try makeWindow(inbox)
        defer { window.isHidden = true }
        await mailWaitUntil { !inbox.model.isRefreshing && !inbox.model.availableTags.isEmpty }
        let table = try XCTUnwrap(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
        table.layoutIfNeeded()
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 1)))
        let label = try XCTUnwrap(cell.contentView.mailTestView(id: "seek-mail-row-classification") as? UILabel)
        XCTAssertTrue(label.accessibilityLabel?.contains("服务器") == true)
        XCTAssertTrue(label.accessibilityLabel?.contains("续费") == true)
        XCTAssertTrue(label.accessibilityLabel?.contains("重要") == true)
        let filter = try XCTUnwrap(inbox.view.mailTestView(id: "seek-mail-classification-filter") as? UIButton)
        XCTAssertFalse(filter.isHidden)
        let tags = try XCTUnwrap(filter.menu?.children.compactMap { $0 as? UIMenu }.first { $0.title == SeekMailL10n.text("标签") })
        let action = try XCTUnwrap(tags.children.compactMap { $0 as? UIAction }.first { $0.title == "重要" })
        if #available(iOS 16.0, *) { action.performWithSender(nil, target: nil) }
        await mailWaitUntil { !inbox.model.isRefreshing }
        XCTAssertEqual(inbox.model.selectedTag?.id, 2)
        XCTAssertTrue(transport.requests.last { $0.url?.path.hasSuffix("/mails") == true }?.url?.query?.contains("tag_id=2") == true)
        let detail = SeekMailDetailViewController(mailID: 11, model: inbox.model) { _ in }
        inbox.navigationController?.pushViewController(detail, animated: false)
        await mailWaitUntil { detail.view.mailTestView(id: "seek-mail-detail-classification") != nil }
        let detailLabel = try XCTUnwrap(detail.view.mailTestView(id: "seek-mail-detail-classification") as? UILabel)
        XCTAssertTrue(detailLabel.accessibilityLabel?.contains("重要") == true)
        XCTAssertTrue(detailLabel.accessibilityLabel?.contains("服务器") == true)
    }

    func testCellReuseClearsOldClassifications() throws {
        let mail = try SeekMailJSON.decoder.decode(SeekMail.self, from: Data(#"{"id":1,"mailboxId":1,"tags":[{"id":2,"name":"重要","color":"not-a-color"}]}"#.utf8))
        let plain = try SeekMailJSON.decoder.decode(SeekMail.self, from: Data(#"{"id":2,"mailboxId":1,"tags":null}"#.utf8))
        let cell = SeekMailCell(style: .default, reuseIdentifier: nil)
        cell.configure(mail: mail, recipient: nil, keyword: "")
        let label = try XCTUnwrap(cell.contentView.mailTestView(id: "seek-mail-row-classification") as? UILabel)
        XCTAssertFalse(label.isHidden)
        cell.prepareForReuse()
        cell.configure(mail: plain, recipient: nil, keyword: "")
        XCTAssertTrue(label.isHidden)
        XCTAssertFalse(cell.accessibilityLabel?.contains("重要") == true)
    }

    func testClassificationScreensSupportDarkLargeTypeAndRTL() async throws {
        let previous = AppTextSizeSettings.shared.pointOffset
        defer { AppTextSizeSettings.shared.setPointOffset(previous) }
        for (style, size, rtl) in [(UIUserInterfaceStyle.light, CGFloat(0), false), (.dark, 0, false), (.light, 8, false), (.dark, 8, true)] {
            AppTextSizeSettings.shared.setPointOffset(size)
            let inbox = makeInbox(fixture())
            let window = try makeWindow(inbox, width: size == 0 ? 390 : 320)
            window.overrideUserInterfaceStyle = style
            if rtl { inbox.view.semanticContentAttribute = .forceRightToLeft }
            defer { window.isHidden = true }
            await mailWaitUntil { !inbox.model.isRefreshing && !inbox.model.availableTags.isEmpty }
            window.layoutIfNeeded()
            let table = try XCTUnwrap(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
            table.layoutIfNeeded()
            let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 1)))
            let label = try XCTUnwrap(cell.contentView.mailTestView(id: "seek-mail-row-classification") as? UILabel)
            XCTAssertGreaterThan(label.bounds.height, 0)
            XCTAssertLessThanOrEqual(label.convert(label.bounds, to: cell.contentView).maxX, cell.contentView.bounds.maxX)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "mail-classification-\(style.rawValue)-\(Int(size))-rtl-\(rtl)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func fixture() -> SeekMailRouteTransport {
        let transport = SeekMailRouteTransport()
        transport.folders = ##"{"data":[{"id":9,"name":"服务器","color":"#4080FF","sortOrder":0}]}"##
        transport.tags = ##"{"data":[{"id":1,"name":"续费","color":"#D17A10"},{"id":2,"name":"重要","color":"#D04444"}]}"##
        let mail = ##"{"id":11,"mailboxId":1,"folderId":9,"fromName":"Example Cloud","fromAddress":"billing@example.com","subject":"服务器续费提醒","bodyText":"这是一封虚构测试邮件。","tags":[{"id":1,"name":"续费","color":"#D17A10"},{"id":2,"name":"重要","color":"#D04444"}]}"##
        transport.mailPages = [#"{"data":[\#(mail)],"pagination":{"total":1,"limit":20,"offset":0}}"#]
        transport.details["/openapi/v1/mails/11"] = ##"{"data":{"mail":\##(mail),"tags":[{"id":2,"name":"重要","color":"#D04444"}]}}"##
        return transport
    }

    private func makeInbox(_ transport: SeekMailRouteTransport) -> SeekMailInboxViewController {
        let inbox = SeekMailInboxViewController(keyStore: InMemorySeekMailKeyStore(key: "sk_live_test"), transport: transport.load, selectionStore: makeSelectionStore())
        inbox.title = SeekMailL10n.text("邮箱")
        return inbox
    }

    private func makeWindow(_ root: UIViewController, width: CGFloat = 390) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = UINavigationController(rootViewController: root)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }
}
