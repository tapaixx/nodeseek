import Foundation

nonisolated struct ProbeNetworkPoint: Codable, Equatable, Sendable {
    var date: Date
    var latency: Double?
    var loss: Double?
    var minimum: Double? = nil
    var maximum: Double? = nil
}

nonisolated struct ProbeNetworkSeries: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String? = nil
    var points: [ProbeNetworkPoint] = []
    var latency: Double? = nil
    var loss: Double? = nil
    var average: Double? = nil
    var minimum: Double? = nil
    var maximum: Double? = nil
    var sampledAt: Date? = nil
    var hasSamples = false
    /// window：面板提供的整窗统计；sample：采样点丢包，不能当作整窗平均。
    var lossScope = "window"
    var latencyScope = "sample"

    var isTimeout: Bool { hasSamples && latency == nil && (points.last?.loss == 100 || loss == 100) }
    var latencyText: String {
        if isTimeout { return "超时" }
        return latency.map { Self.number($0) + " ms" } ?? "—"
    }
    var lossText: String { hasSamples ? loss.map { Self.number($0) + "%" } ?? "—" : "—" }
    var carrierOrder: Int {
        let value = name.lowercased()
        if value.contains("电信") || value.contains("電信") || value.contains("telecom") || value == "ct" { return 0 }
        if value.contains("联通") || value.contains("聯通") || value.contains("unicom") || value == "cu" { return 1 }
        if value.contains("移动") || value.contains("移動") || value.contains("mobile") || value == "cm" { return 2 }
        return 3
    }
    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value).replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }
}

/// 各面板的线网语义不同，在解析层保留原始统计范围。
nonisolated enum ProbeNetworkParser {
    static func latest(adapter: String, item: Any, sampledAt: Date?) -> [ProbeNetworkSeries] {
        guard let item = item as? [String: Any] else { return [] }
        if adapter == "komari", let ping = item["ping"] as? [String: Any] {
            return sorted(ping.compactMap { id, raw in
                guard let task = raw as? [String: Any] else { return nil }
                let loss = percent(task["loss"])
                let latency = latency(task["latest"])
                let hasSamples = latency != nil || (loss ?? 0) > 0
                return ProbeNetworkSeries(id: id, name: task["name"] as? String ?? "线路 \(id)", latency: latency,
                    loss: hasSamples ? loss : nil, average: hasSamples && loss != 100 ? number(task["avg"]) : nil,
                    minimum: hasSamples && loss != 100 ? latencyValue(task["min"]) : nil,
                    maximum: hasSamples && loss != 100 ? latencyValue(task["max"]) : nil,
                    sampledAt: sampledAt, hasSamples: hasSamples, latencyScope: "success")
            })
        }
        if adapter == "cfsm" { return cfsm(rows: [item], names: [:], dateKey: "last_updated") }
        return []
    }

    static func history(adapter: String, object: Any, names: [String: String] = [:]) throws -> [ProbeNetworkSeries] {
        switch adapter {
        case "monitor": return try monitor(object)
        case "komari": return try komari(object)
        case "cfsm":
            guard let rows = object as? [[String: Any]] else { throw ProbeFetchError.decoding }
            return cfsm(rows: rows, names: names, dateKey: "timestamp")
        default: throw ProbeFetchError.unsupported
        }
    }

    static func cfsmNames(_ object: Any) -> [String: String] {
        guard let values = object as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for key in ["ct", "cu", "cm", "bd"] { result[key] = values["custom_\(key)_name"] as? String }
        for i in 1...4 { result["node_\(i)"] = values["node_\(i)_name"] as? String }
        return result
    }

    private static func monitor(_ object: Any) throws -> [ProbeNetworkSeries] {
        guard let root = object as? [String: Any], let records = root["ping"] as? [[String: Any]],
              let tasks = root["probes"] as? [String: Any] else { throw ProbeFetchError.decoding }
        let losses = root["loss"] as? [String: Any] ?? [:]
        let grouped = Dictionary(grouping: records, by: { identifier($0["task_id"]) ?? "" })
        return sorted(Set(tasks.keys).union(grouped.keys).filter { !$0.isEmpty }.map { id in
            let points = (grouped[id] ?? []).compactMap { row -> ProbeNetworkPoint? in
                guard let ts = number(row["ts"]) else { return nil }
                let band = row["band"] as? [Any]
                return ProbeNetworkPoint(date: Date(timeIntervalSince1970: ts), latency: latency(row["latency"]),
                    loss: percent(row["loss"]) ?? 0, minimum: band?.first.flatMap(latencyValue), maximum: band?.last.flatMap(latencyValue))
            }.sorted { $0.date < $1.date }
            return ProbeNetworkSeries(id: id, name: tasks[id] as? String ?? "线路 \(id)", points: points,
                latency: points.last?.latency, loss: points.isEmpty ? nil : percent(losses[id]) ?? 0,
                sampledAt: points.last?.date, hasSamples: !points.isEmpty, latencyScope: "median")
        })
    }

    private static func komari(_ object: Any) throws -> [ProbeNetworkSeries] {
        guard let root = object as? [String: Any], let data = (root["data"] ?? root["result"]) as? [String: Any],
              let records = data["records"] as? [[String: Any]], let tasks = data["tasks"] as? [[String: Any]] else { throw ProbeFetchError.decoding }
        let grouped = Dictionary(grouping: records, by: { identifier($0["task_id"]) ?? "" })
        var known = Set<String>()
        let series = tasks.compactMap { task -> ProbeNetworkSeries? in
            guard let id = identifier(task["id"]) else { return nil }
            known.insert(id)
            let points = komariPoints(grouped[id] ?? [])
            let hasSamples = (number(task["total"]) ?? Double(points.count)) > 0
            let loss = hasSamples ? percent(task["loss"]) : nil
            return ProbeNetworkSeries(id: id, name: task["name"] as? String ?? "线路 \(id)", kind: task["type"] as? String,
                points: points, latency: points.last?.latency, loss: loss,
                average: hasSamples && loss != 100 ? latencyValue(task["avg"]) : nil,
                minimum: hasSamples && loss != 100 ? latencyValue(task["min"]) : nil,
                maximum: hasSamples && loss != 100 ? latencyValue(task["max"]) : nil,
                sampledAt: points.last?.date, hasSamples: hasSamples)
        }
        return sorted(series + grouped.filter { !known.contains($0.key) && !$0.key.isEmpty }.map { id, rows in
            let points = komariPoints(rows)
            return ProbeNetworkSeries(id: id, name: "线路 \(id)", points: points, latency: points.last?.latency,
                sampledAt: points.last?.date, hasSamples: !points.isEmpty)
        })
    }

    private static func komariPoints(_ rows: [[String: Any]]) -> [ProbeNetworkPoint] {
        rows.compactMap { row in
            guard let raw = row["time"] as? String, let date = ProbeJSONPath.date(raw, format: .iso8601),
                  let value = number(row["value"]) else { return nil }
            return ProbeNetworkPoint(date: date, latency: value < 0 ? nil : value, loss: value < 0 ? 100 : 0)
        }.sorted { $0.date < $1.date }
    }

    private static func cfsm(rows: [[String: Any]], names: [String: String], dateKey: String) -> [ProbeNetworkSeries] {
        let ids = ["ct", "cu", "cm", "bd"] + (1...4).map { "node_\($0)" }
        return sorted(ids.compactMap { id in
            let samples: [(Date?, Double?, Double?)] = rows.compactMap { row in
                let ping = latency(row["ping_\(id)"]), loss = percent(row["loss_\(id)"])
                guard ping != nil || loss != nil else { return nil }
                let date = number(row[dateKey]).map { Date(timeIntervalSince1970: $0 / 1000) }
                return (date, ping, loss)
            }.sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }
            guard let last = samples.last else { return nil }
            let points = samples.compactMap { sample in sample.0.map { ProbeNetworkPoint(date: $0, latency: sample.1, loss: sample.2) } }
            return ProbeNetworkSeries(id: id, name: names[id]?.isEmpty == false ? names[id]! : ["ct": "CT", "cu": "CU", "cm": "CM", "bd": "BGP"][id] ?? "自定义 \(id)",
                points: points, latency: last.1, loss: last.2, sampledAt: last.0, hasSamples: true, lossScope: "sample")
        })
    }

    private static func identifier(_ raw: Any?) -> String? { (raw as? String) ?? number(raw).map { String(format: "%.0f", $0) } }
    private static func latency(_ raw: Any?) -> Double? { latencyValue(raw) }
    private static func latencyValue(_ raw: Any?) -> Double? { number(raw).flatMap { $0 >= 0 ? $0 : nil } }
    private static func percent(_ raw: Any?) -> Double? { number(raw).flatMap { (0...100).contains($0) ? $0 : nil } }
    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        if let raw = raw as? String, let value = Double(raw), value.isFinite { return value }
        return nil
    }
    private static func sorted(_ values: [ProbeNetworkSeries]) -> [ProbeNetworkSeries] {
        values.sorted { ($0.carrierOrder, $0.name, $0.id) < ($1.carrierOrder, $1.name, $1.id) }
    }
}
