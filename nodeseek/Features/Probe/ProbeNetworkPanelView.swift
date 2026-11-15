import UIKit

final class ProbeNetworkPanelView: UIView {
    private let stack = UIStackView()
    private var series: [ProbeNetworkSeries] = []
    private var selectedID: String?
    private var message: String?
    private var hours = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ProbeStyle.card
        layer.cornerRadius = ProbeStyle.cardRadius
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
        accessibilityIdentifier = "probe-network-panel"
        configure([], message: "加载线路信息…", hours: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ series: [ProbeNetworkSeries], message: String? = nil, hours: Int) {
        self.series = series; self.message = message; self.hours = hours
        if !series.contains(where: { $0.id == selectedID }) { selectedID = series.first?.id }
        render()
    }

    private func label(_ text: String, color: UIColor = .label, font: UIFont = .preferredFont(forTextStyle: .caption1)) -> UILabel {
        let view = UILabel(); view.text = text; view.font = font; view.textColor = color; view.numberOfLines = 0
        view.adjustsFontForContentSizeCategory = true
        return view
    }
    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label("三网与线路", font: .preferredFont(forTextStyle: .headline)))
        stack.addArrangedSubview(label("服务器 → 面板监测目标 · 最近 \(hours) 小时", color: .secondaryLabel))
        if let message { stack.addArrangedSubview(label(message, color: .secondaryLabel)) }
        if series.isEmpty {
            if message == nil { stack.addArrangedSubview(label("面板尚未提供线路数据，请确认已配置 Ping 监测任务。", color: .secondaryLabel)) }
            return
        }
        for item in series {
            let button = UIButton(type: .system)
            let title = label(item.name, font: .preferredFont(forTextStyle: .subheadline))
            let value = label(item.hasSamples ? "\(item.latencyText)  ·  \(item.lossText)" : "尚未采样", color: item.isTimeout ? .systemRed : .label)
            value.setContentHuggingPriority(.required, for: .horizontal)
            value.textAlignment = .right
            let row = UIStackView(arrangedSubviews: [title, value]); row.spacing = 8; row.alignment = .center
            row.isUserInteractionEnabled = false
            row.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(row)
            button.backgroundColor = item.id == selectedID ? UIColor.systemBlue.withAlphaComponent(0.08) : .clear
            button.layer.cornerRadius = 9
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: button.topAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -10),
                row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
            button.accessibilityLabel = "\(item.name)，延迟 \(item.latencyText)，丢包 \(item.lossText)"
            button.accessibilityIdentifier = "probe-network-task-\(item.id)"
            button.accessibilityTraits = item.id == selectedID ? [.button, .selected] : .button
            button.addAction(UIAction { [weak self] _ in self?.selectedID = item.id; self?.render() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        guard let selected = series.first(where: { $0.id == selectedID }) else { return }
        let scope = selected.lossScope == "window" ? "窗口丢包" : "采样点丢包"
        let latencyScope = selected.latencyScope == "median" ? "桶中位延迟" : selected.latencyScope == "success" ? "最近成功延迟" : "最近采样延迟"
        stack.addArrangedSubview(label("\(latencyScope) \(selected.latencyText)  ·  \(scope) \(selected.lossText)", color: .secondaryLabel))
        if !selected.points.isEmpty {
            let latency = ProbeNetworkChartView(points: selected.points, loss: false)
            let loss = ProbeNetworkChartView(points: selected.points, loss: true)
            stack.addArrangedSubview(label("延迟 · ms", color: .secondaryLabel))
            stack.addArrangedSubview(latency)
            stack.addArrangedSubview(label("丢包 · %", color: .secondaryLabel))
            stack.addArrangedSubview(loss)
            latency.heightAnchor.constraint(equalToConstant: 90).isActive = true
            loss.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            let first = selected.points.first.map { formatter.string(from: $0.date) } ?? ""
            let last = selected.points.last.map { formatter.string(from: $0.date) } ?? ""
            stack.addArrangedSubview(label("\(first) — \(last) · 断线表示缺少成功样本", color: .tertiaryLabel))
        }
        var stats: [String] = []
        if let average = selected.average { stats.append(String(format: "平均 %.1f ms", average)) }
        if let minimum = selected.minimum { stats.append(String(format: "最低 %.1f ms", minimum)) }
        if let maximum = selected.maximum { stats.append(String(format: "最高 %.1f ms", maximum)) }
        if !stats.isEmpty { stack.addArrangedSubview(label(stats.joined(separator: " · "), color: .secondaryLabel)) }
        stack.addArrangedSubview(label("线路名称由面板配置；CT / CU / CM 为面板字段。数据来自服务器探针，不是手机测速。", color: .tertiaryLabel))
    }
}

/// 按真实采样时间绘制；超时断线，不补 0ms，也不连接缺失样本。
private final class ProbeNetworkChartView: UIView {
    private let points: [ProbeNetworkPoint]
    private let loss: Bool
    init(points: [ProbeNetworkPoint], loss: Bool) {
        self.points = points; self.loss = loss
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = loss ? "采样点丢包率趋势" : "线路延迟趋势，超时断线"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let first = points.first, let last = points.last else { return }
        let area = bounds.insetBy(dx: 2, dy: 3)
        let span = max(1, last.date.timeIntervalSince(first.date))
        let maximum = loss ? 100 : max(10, (points.compactMap(\.latency).max() ?? 10) * 1.1)
        context.setStrokeColor(UIColor.separator.cgColor); context.setLineWidth(0.5)
        for fraction in [0.0, 0.5, 1.0] {
            let y = area.maxY - area.height * fraction
            context.move(to: CGPoint(x: area.minX, y: y)); context.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        context.strokePath()
        let gaps = zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.filter { $0 > 0 }.sorted()
        let expectedGap = gaps.isEmpty ? span : gaps[gaps.count / 2]
        var previous: ProbeNetworkPoint?
        context.setStrokeColor((loss ? UIColor.systemOrange : UIColor.systemBlue).cgColor)
        context.setLineWidth(loss ? 3 : 1.8)
        for point in points {
            let x = area.minX + CGFloat(point.date.timeIntervalSince(first.date) / span) * area.width
            guard let value = loss ? point.loss : point.latency else { previous = nil; continue }
            let y = area.maxY - CGFloat(min(maximum, max(0, value)) / maximum) * area.height
            if loss {
                context.move(to: CGPoint(x: x, y: area.maxY)); context.addLine(to: CGPoint(x: x, y: y)); context.strokePath()
            } else {
                if let previous, previous.latency != nil, point.date.timeIntervalSince(previous.date) <= expectedGap * 3 {
                    let px = area.minX + CGFloat(previous.date.timeIntervalSince(first.date) / span) * area.width
                    let py = area.maxY - CGFloat(min(maximum, previous.latency!) / maximum) * area.height
                    context.move(to: CGPoint(x: px, y: py)); context.addLine(to: CGPoint(x: x, y: y)); context.strokePath()
                }
                context.setFillColor(UIColor.systemBlue.cgColor); context.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            }
            previous = point
        }
    }
}
