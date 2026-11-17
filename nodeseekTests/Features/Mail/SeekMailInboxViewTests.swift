import Foundation
import Testing
import UIKit
@testable import nodeseek

/// 在有尺寸的界面里真正生成单元格，覆盖骨架行、邮件行和验证码卡片的布局。
@MainActor
struct SeekMailInboxViewTests {
    @Test func rendersSkeletonThenRowsAndCodeCard() async throws {
        let transport = SeekMailRouteTransport()
        transport.delayNanoseconds = 150_000_000
        let received = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))
        transport.mailPages = [#"{"data":[{"id":21,"mailboxId":1,"fromAddress":"noreply@example.com","fromName":"GitHub","subject":"Verify","bodyText":"Your code is 482913","verificationCode":"482913","receivedAt":"\#(received)"},{"id":22,"mailboxId":2,"fromAddress":"bill@example.com","subject":"Invoice","bodyText":"Paid","isRead":true,"hasAttachments":true}],"pagination":{"total":2,"limit":20,"offset":0}}"#]
        let inbox = SeekMailInboxViewController(
            keyStore: InMemorySeekMailKeyStore(key: "sk_live_ok"),
            transport: transport.load,
            selectionStore: makeSelectionStore()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = inbox
        window.isHidden = false
        defer { window.isHidden = true }
        inbox.view.layoutIfNeeded()

        let table = try #require(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
        #expect(table.visibleCells.contains { $0 is SeekMailSkeletonCell })

        await mailWaitUntil { inbox.model.phase == .loaded }
        table.layoutIfNeeded()
        #expect(table.visibleCells.contains { $0 is SeekMailSkeletonCell } == false)
        #expect(table.visibleCells.filter { $0 is SeekMailCell }.count == 2)
        let card = try #require(table.visibleCells.first { $0 is SeekMailCodeCell })
        #expect((card.mailTestView(id: "seek-mail-code-card-code") as? UILabel)?.text == "482913")
        // 「全部邮箱」时摘要开头标出收件邮箱，行内也显示验证码
        let row = try #require(table.visibleCells.first { $0.accessibilityIdentifier == "seek-mail-row-21" })
        #expect(row.mailTestView(id: "seek-mail-row-code")?.isHidden == false)
        #expect(row.accessibilityLabel?.contains("验证码 482913") == true)
        let tabs = try #require(inbox.view.mailTestView(id: "seek-mail-folder-tabs"))
        #expect(tabs.mailTestView(id: "seek-mail-folder-inbox") != nil)
        let allTag = try #require(inbox.view.mailTestView(id: "seek-mail-tag-all") as? UIButton)
        #expect(allTag.configuration?.attributedTitle.map { String($0.characters) }?.hasPrefix("全部") == true)
        #expect(allTag.accessibilityTraits.contains(.selected))
    }

    @Test func emptyTrashShowsReadOnlyNotice() async throws {
        let transport = SeekMailRouteTransport()
        transport.mailPages = [#"{"data":null,"pagination":{"total":0,"limit":20,"offset":0}}"#]
        let selection = makeSelectionStore()
        selection.scope = .trash
        let inbox = SeekMailInboxViewController(
            keyStore: InMemorySeekMailKeyStore(key: "sk_live_ok"), transport: transport.load, selectionStore: selection
        )
        inbox.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        inbox.loadViewIfNeeded()
        await mailWaitUntil { inbox.model.phase == .loaded }
        inbox.view.layoutIfNeeded()

        #expect((inbox.view.mailTestView(id: "seek-mail-notice") as? UILabel)?.text == "回收站只能查看 · 网页中恢复")
        #expect((inbox.view.mailTestView(id: "seek-mail-state-message") as? UILabel)?.text == "回收站是空的")
    }

    @Test func bottomSearchRequestsOnlyOnSubmitAndClearsOnCancel() async throws {
        let transport = SeekMailRouteTransport()
        let inbox = SeekMailInboxViewController(
            keyStore: InMemorySeekMailKeyStore(key: "sk_live_ok"), transport: transport.load, selectionStore: makeSelectionStore()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = inbox
        window.isHidden = false
        defer { window.isHidden = true }
        await mailWaitUntil { inbox.model.phase == .loaded }
        inbox.view.layoutIfNeeded()

        let field = try #require(inbox.view.mailTestView(id: "seek-mail-search") as? UITextField)
        let table = try #require(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
        #expect(table.contentInset.bottom > 0)
        let before = transport.requests.count

        // 输入时不发请求
        field.text = "invoice"
        field.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(transport.requests.count == before)
        #expect(inbox.model.isSearching == false)

        // 点键盘「搜索」才请求
        _ = field.delegate?.textFieldShouldReturn?(field)
        await mailWaitUntil { transport.requests.last?.url?.query?.contains("search=invoice") == true }
        #expect(inbox.model.isSearching)

        // 取消后回到普通列表
        inbox.searchBar.cancel()
        #expect(inbox.model.isSearching == false)
        #expect(field.text?.isEmpty ?? true)
    }

    @Test func manyMailboxesUseCompactSwitcherAndDirectCopy() async throws {
        let transport = SeekMailRouteTransport()
        let boxes = (1...12).map { #"{"id":\#($0),"address":"box\#($0)@nodeseek.org"}"# }.joined(separator: ",")
        transport.mailboxes = #"{"data":[\#(boxes)]}"#
        let inbox = SeekMailInboxViewController(
            keyStore: InMemorySeekMailKeyStore(key: "sk_live_test"), transport: transport.load, selectionStore: makeSelectionStore()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = inbox
        window.isHidden = false
        defer { window.isHidden = true }
        await mailWaitUntil { inbox.model.phase == .loaded }
        inbox.model.selectMailbox(12)
        await mailWaitUntil { !inbox.model.isRefreshing }
        inbox.view.layoutIfNeeded()
        let tags = try #require(inbox.view.mailTestView(id: "seek-mail-tags"))
        #expect(tags.isHidden)
        let switcher = try #require(inbox.view.mailTestView(id: "seek-mail-mailbox-switcher") as? UIButton)
        #expect(switcher.accessibilityValue == "box12@nodeseek.org")
        #expect(switcher.frame.height < 100)
        let copy = try #require(inbox.view.mailTestView(id: "seek-mail-copy-current-address") as? UIButton)
        #expect(!copy.isHidden)
        let before = transport.requests.count
        copy.sendActions(for: .touchUpInside)
        #expect(UIPasteboard.general.string == "box12@nodeseek.org")
        #expect(transport.requests.count == before)
        #expect(!inbox.model.canCompose)
    }

    @Test func progressFloatsAboveSearchWithoutTakingListHeight() async throws {
        let inbox = SeekMailInboxViewController(
            keyStore: InMemorySeekMailKeyStore(key: "sk_live_ok"),
            transport: SeekMailRouteTransport().load,
            selectionStore: makeSelectionStore()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = inbox
        window.isHidden = false
        defer { window.isHidden = true }
        inbox.view.layoutIfNeeded()
        let table = try #require(inbox.view.mailTestView(id: "seek-mail-list") as? UITableView)
        let tableFrame = table.frame
        let insetBefore = table.contentInset.bottom

        var stopped = false
        inbox.progressBar.show(text: "正在标为已读 1/3", progress: 1 / 3, actionTitle: "停止") { stopped = true }
        inbox.view.layoutIfNeeded()
        let bar = inbox.progressBar
        #expect(bar.superview === inbox.view)
        #expect(bar.isHidden == false)
        // 列表位置不变，只加大底部留白
        #expect(table.frame == tableFrame)
        #expect(table.contentInset.bottom > insetBefore)
        let search = try #require(inbox.view.mailTestView(id: "seek-mail-search"))
        #expect(bar.frame.maxY <= search.convert(search.bounds, to: inbox.view).minY)
        (bar.mailTestView(id: "seek-mail-progress-action") as? UIButton)?.sendActions(for: .touchUpInside)
        #expect(stopped)

        inbox.progressBar.hide()
        inbox.view.layoutIfNeeded()
        // 淡出动画结束后才真正隐藏
        #expect(bar.isShowing == false)
        #expect(table.contentInset.bottom == insetBefore)
    }
}
