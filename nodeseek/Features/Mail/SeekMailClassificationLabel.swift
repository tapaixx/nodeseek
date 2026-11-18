import UIKit

/// 文件夹归属与邮件标签保留名称；颜色只作辅助，未知颜色回退到系统色。
final class SeekMailClassificationLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        adjustsFontForContentSizeCategory = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(folder: SeekMailFolder?, tags: [SeekMailTag]) {
        font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: SeekMailFont.of(.caption1))
        let result = NSMutableAttributedString()
        var accessible: [String] = []
        func append(name: String, prefix: String, symbol: String, color: String?) {
            if result.length > 0 { result.append(NSAttributedString(string: "   ")) }
            let indicator = NSTextAttachment()
            indicator.image = UIImage(systemName: symbol)?.withTintColor(Self.indicatorColor(color), renderingMode: .alwaysOriginal)
            indicator.bounds = CGRect(x: 0, y: -1, width: font.pointSize, height: font.pointSize)
            result.append(NSAttributedString(attachment: indicator))
            result.append(NSAttributedString(string: " " + name, attributes: [.font: font!, .foregroundColor: UIColor.secondaryLabel]))
            accessible.append(SeekMailL10n.format(prefix, name))
        }
        if let folder { append(name: folder.name, prefix: "文件夹：%@", symbol: "folder.fill", color: folder.color) }
        for tag in tags { append(name: tag.name, prefix: "标签：%@", symbol: "tag.fill", color: tag.color) }
        attributedText = result
        accessibilityLabel = accessible.joined(separator: "，")
        isHidden = result.length == 0
    }

    private static func indicatorColor(_ raw: String?) -> UIColor {
        guard let raw, raw.hasPrefix("#"), raw.count == 7, let value = UInt32(raw.dropFirst(), radix: 16) else { return .secondaryLabel }
        // 服务端保存的标签颜色属于分类语义色，仅用于图标；文字始终使用系统动态色。
        let red = CGFloat((value >> 16) & 255) / 255
        let green = CGFloat((value >> 8) & 255) / 255
        let blue = CGFloat(value & 255) / 255
        return UIColor { traits in
            let lift: CGFloat = traits.userInterfaceStyle == .dark ? 0.25 : 0
            return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift, alpha: 1)
        }
    }
}
