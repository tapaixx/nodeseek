import UIKit
import XCTest
@testable import nodeseek

/// 按实际使用规模构造虚构数据，不保存真实 Key、地址或邮件内容。
@MainActor
final class SeekMailUsabilityTests: XCTestCase {
    func testPickerSearchCopyAndSelectionUseLocalMailboxData() async throws {
        let transport = fixture()
        let inbox = makeInbox(transport)
        let window = try makeWindow(inbox)
        defer { window.isHidden = true }
        await mailWaitUntil { !inbox.model.isRefreshing }
        var selected: Int64?
        let picker = SeekMailMailboxPickerViewController(model: inbox.model) { selected = $0 }
        let nav = UINavigationController(rootViewController: picker)
        window.rootViewController = nav
        window.layoutIfNeeded()
        let table = try XCTUnwrap(picker.view.mailTestView(id: "seek-mail-picker-list") as? UITableView)
        let field = try XCTUnwrap(picker.view.mailTestView(id: "seek-mail-picker-search") as? UISearchTextField)
        let search = try XCTUnwrap(field.superview?.superview as? UISearchBar ?? descendants(picker.view, UISearchBar.self).first)
        let before = transport.requests.count
        picker.searchBar(search, textDidChange: "账单")
        table.layoutIfNeeded()
        XCTAssertEqual(table.numberOfSections, 1)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
        let row = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        XCTAssertEqual(row.detailTextLabel?.text, "billing@nodeseek.org")
        let copy = try XCTUnwrap(row.accessoryView?.mailTestView(id: "seek-mail-picker-copy-12") as? UIButton)
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, "billing@nodeseek.org")
        XCTAssertNil(selected)
        XCTAssertEqual(transport.requests.count, before)
        picker.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(selected, 12)
        picker.searchBar(search, textDidChange: "missing@example.invalid")
        XCTAssertEqual(table.numberOfSections, 0)
        XCTAssertNotNil(table.backgroundView)
        XCTAssertEqual(transport.requests.count, before)
    }

    func testInboxDoesNotRequestQuotaBeforeOpeningSettings() async throws {
        let transport = fixture()
        let inbox = makeInbox(transport)
        let window = try makeWindow(inbox)
        defer { window.isHidden = true }
        await mailWaitUntil { !inbox.model.isRefreshing }
        XCTAssertFalse(transport.requests.contains { $0.url?.path.hasSuffix("/quotas") == true })
    }

    func testRefreshKeepsVisibleMailAndLoadedPages() async throws {
        let transport = fixture()
        transport.mailPages = [page(1...20), page(21...40), page(1...20)]
        let inbox = makeInbox(transport)
        let window = try makeWindow(inbox)
        defer { window.isHidden = true }
        await mailWaitUntil { !inbox.model.isRefreshing }
        inbox.model.loadMoreIfNeeded()
        await mailWaitUntil { inbox.model.mails.count == 40 }
        let table = try XCTUnwrap(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
        table.layoutIfNeeded()
        table.scrollToRow(at: IndexPath(row: 25, section: 1), at: .top, animated: false)
        table.layoutIfNeeded()
        let before = try XCTUnwrap(table.indexPathsForVisibleRows?.first { $0.section == 1 })
        let visibleID = inbox.model.mails[before.row].id
        let offset = table.contentOffset.y - table.rectForRow(at: before).minY
        inbox.model.reload()
        await mailWaitUntil { !inbox.model.isRefreshing }
        table.layoutIfNeeded()
        XCTAssertEqual(inbox.model.mails.count, 40)
        let after = try XCTUnwrap(table.indexPathsForVisibleRows?.first { $0.section == 1 })
        XCTAssertEqual(inbox.model.mails[after.row].id, visibleID)
        XCTAssertEqual(table.contentOffset.y - table.rectForRow(at: after).minY, offset, accuracy: 1)
    }

    func testMailboxScreensInLightDarkAndLargeType() async throws {
        let originalOffset = AppTextSizeSettings.shared.pointOffset
        defer { AppTextSizeSettings.shared.setPointOffset(originalOffset) }
        for (style, offset, width) in [(UIUserInterfaceStyle.light, CGFloat(0), CGFloat(390)), (.dark, 0, 390), (.light, 8, 320)] {
            AppTextSizeSettings.shared.setPointOffset(offset)
            let inbox = makeInbox(fixture())
            let window = try makeWindow(inbox, width: width)
            window.overrideUserInterfaceStyle = style
            defer { window.isHidden = true }
            await mailWaitUntil { !inbox.model.isRefreshing }
            window.layoutIfNeeded()
            let switcher = try XCTUnwrap(inbox.view.mailTestView(id: "seek-mail-mailbox-switcher") as? UIButton)
            XCTAssertGreaterThanOrEqual(switcher.bounds.height, 44)
            XCTAssertTrue(inbox.view.mailTestView(id: "seek-mail-tags")?.isHidden == true)
            attach(window, name: "mail-inbox-\(style.rawValue)-\(Int(width))-\(Int(offset))")
            let picker = SeekMailMailboxPickerViewController(model: inbox.model) { _ in }
            window.rootViewController = UINavigationController(rootViewController: picker)
            window.layoutIfNeeded()
            let table = try XCTUnwrap(picker.view.mailTestView(id: "seek-mail-picker-list") as? UITableView)
            XCTAssertGreaterThan(table.visibleCells.count, 3)
            for cell in table.visibleCells {
                XCTAssertGreaterThanOrEqual(cell.bounds.height, 44)
                if let accessory = cell.accessoryView { XCTAssertLessThanOrEqual(accessory.frame.maxX, cell.bounds.maxX) }
            }
            attach(window, name: "mail-picker-\(style.rawValue)-\(Int(width))-\(Int(offset))")
        }
    }

    private func fixture() -> SeekMailRouteTransport {
        let transport = SeekMailRouteTransport()
        let boxes = (1...12).map { id in
            id == 12 ? #"{"id":12,"address":"billing@nodeseek.org","alias":"账单与订单"}"#
                : #"{"id":\#(id),"address":"account-\#(id)@nodeseek.org"}"#
        }.joined(separator: ",")
        transport.mailboxes = #"{"data":[\#(boxes)]}"#
        transport.details["/openapi/v1/mails/counts"] = #"{"data":{"mailboxes":{},"total":0}}"#
        transport.mailPages = [page(1...20)]
        return transport
    }

    private func page(_ ids: ClosedRange<Int>) -> String {
        let rows = ids.map { id in
            #"{"id":\#(id),"mailboxId":\#(id % 12 + 1),"fromAddress":"service@example.com","fromName":"示例服务","subject":"账户通知与服务器续费提醒 \#(id)","bodyText":"这是用于布局检查的虚构邮件摘要，不包含真实邮件内容。","isRead":true,"receivedAt":"2026-11-17T08:42:15Z"}"#
        }.joined(separator: ",")
        return #"{"data":[\#(rows)],"pagination":{"total":40,"limit":20,"offset":\#(ids.lowerBound - 1)}}"#
    }

    private func makeInbox(_ transport: SeekMailRouteTransport) -> SeekMailInboxViewController {
        let inbox = SeekMailInboxViewController(keyStore: InMemorySeekMailKeyStore(key: "sk_live_test"), transport: transport.load, selectionStore: makeSelectionStore())
        inbox.title = SeekMailL10n.text("邮箱")
        return inbox
    }

    private func makeWindow(_ controller: UIViewController, width: CGFloat = 390) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, type) }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
