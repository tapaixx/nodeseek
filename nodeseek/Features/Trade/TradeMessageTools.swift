import SwiftUI
import PhotosUI

struct TradeImagePicker: UIViewControllerRepresentable {
    let onSelected: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: TradeImagePicker
        init(parent: TradeImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                let maxSide: CGFloat = 2400
                let ratio = min(1, maxSide / max(image.size.width, image.size.height))
                let scaled = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio)).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio)))
                }
                guard let data = scaled.jpegData(compressionQuality: 0.85) else { return }
                DispatchQueue.main.async { self.parent.onSelected(data) }
            }
        }
    }
}

struct TradeRemoteImage: View {
    let api: TradeWorkspaceServing
    let path: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var expanded = false
    var body: some View {
        Group {
            if let image {
                Button { expanded = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                }.buttonStyle(.plain).accessibilityLabel(TradeText.text("查看大图"))
            }
            else if failed { Label(TradeText.text("图片加载失败"), systemImage: "photo") }
            else { ProgressView() }
        }
        .sheet(isPresented: $expanded) {
            NavigationView {
                ScrollView([.horizontal, .vertical]) {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(minWidth: 300, maxWidth: 1500) }
                }.navigationTitle(TradeText.text("聊天图片"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(TradeText.text("关闭")) { expanded = false } } }
            }
        }
        .task(id: path) {
            do { let bytes = try await api.image(path); image = UIImage(data: bytes); failed = image == nil }
            catch { failed = true }
        }
    }
}

struct TradeMessageActions: View {
    let message: TradeMessage
    let room: TradeRoom
    let currentUser: TradeUser?
    let api: TradeWorkspaceServing
    let conversationID: Int64
    @Binding var operation: TradeOperation?
    @Binding var history: TradeValue?
    var body: some View {
        if room.access.canWrite, ["text", "image"].contains(message.type ?? ""), message.hidden != true, message.deleted != true {
            ForEach(["👍", "❤️", "😂", "🎉", "🤔", "👀"], id: \.self) { emoji in
                Button(emoji) {
                    operation = .init(title: TradeText.text("添加表情"), explanation: TradeText.text("表情会显示在这条消息下方。"), path: "/api/common/messages/\(message.id)/reactions", fields: ["emoji": .string(emoji)])
                }
            }
            if message.sender?.id == currentUser?.id {
                Button(TradeText.text("编辑消息")) {
                    operation = .init(title: TradeText.text("编辑消息"), explanation: TradeText.text("修改会留下编辑记录。"), path: "/api/common/messages/\(message.id)", method: "PATCH", inputs: [
                        .init(key: "content", title: "消息内容", kind: .multiline, required: true, initial: message.content ?? "", limit: 10000)])
                }
            }
            if message.sender?.id == currentUser?.id || room.access.canDeleteOthers == true {
                Button(TradeText.text("删除消息"), role: .destructive) {
                    operation = .init(title: TradeText.text("删除消息"), explanation: TradeText.text("聊天中会留下删除记录，内容会保留审计存档。"), path: "/api/common/messages/\(message.id)", method: "DELETE", irreversible: true)
                }
            }
        }
        if room.access.canPin == true {
            Button(TradeText.text(message.pinnedAt == nil ? "置顶消息" : "取消置顶")) {
                operation = .init(title: TradeText.text("消息置顶"), explanation: TradeText.text("置顶不会扩大私密消息的可见范围。"), path: "/api/common/messages/\(message.id)/pin", fields: ["pinned": .bool(message.pinnedAt == nil)])
            }
        }
        if (message.editCount ?? 0) > 0, room.access.canModerate == true || message.editsVisible == true {
            Button(TradeText.text("编辑记录")) {
                Task { history = try? await api.read("/api/common/messages/\(message.id)/revisions", query: [:]) }
            }
        }
        if room.access.canModerate == true, message.type == "deleted" {
            Button(TradeText.text("切换删除内容可见性")) {
                operation = .init(title: TradeText.text("删除内容可见性"), explanation: TradeText.text("将调整其他参与者能否查看删除内容，私密消息仍遵循原有权限。"), path: "/api/common/messages/\(message.id)/deletion-visibility", fields: ["visible": .bool(message.deletionVisible != true)])
            }
        }
        if room.access.canModerate == true, (message.editCount ?? 0) > 0 {
            Button(TradeText.text("切换编辑记录可见性")) {
                operation = .init(title: TradeText.text("编辑记录可见性"), explanation: TradeText.text("将调整其他参与者能否查看这条消息的编辑历史。"), path: "/api/common/messages/\(message.id)/edits-visibility", fields: ["visible": .bool(message.editsVisible != true)])
            }
        }
    }
}

struct TradeMessageHistory: View {
    let data: TradeValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                ForEach(Array(data["revisions"].list.enumerated()), id: \.offset) { _, row in
                    TradeBusinessRow(title: row["content"].text ?? TradeText.text("空消息"), subtitle: row["edited_by_name"].text, trailing: row["created_at"].date)
                }
                Section(TradeText.text("当前版本")) { Text(data["current"].text ?? "").textSelection(.enabled) }
            }.navigationTitle(TradeText.text("编辑记录"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(TradeText.text("关闭")) { dismiss() } } }
        }
    }
}
