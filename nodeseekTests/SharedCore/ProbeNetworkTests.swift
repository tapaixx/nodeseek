import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct ProbeNetworkTests {
    @Test func monitorKeepsWindowLossAndTimeoutSeparate() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"probes":{"1":"电信","2":"联通","3":"移动"},"ping":[{"task_id":1,"ts":1763193600,"latency":null,"loss":100},{"task_id":1,"ts":1763193660,"latency":42,"band":[40,44]},{"task_id":2,"ts":1763193660,"latency":18}],"loss":{"1":6.25},"step":60}"#.utf8))
        let rows = try ProbeNetworkParser.history(adapter: "monitor", object: object)
        #expect(rows.count == 3)
        #expect(rows[0].loss == 6.25)
        #expect(rows[0].latency == 42)
        #expect(rows[0].points[0].latency == nil)
        #expect(rows[0].points[0].loss == 100)
        #expect(rows[0].points[1].minimum == 40)
        #expect(rows[1].loss == 0)
        #expect(!rows[2].hasSamples)
        #expect(rows[2].loss == nil)
    }

    @Test func komariDoesNotTreatEmptyTotalsAsHealthy() throws {
        let raw = #"{"data":{"records":[{"task_id":1,"time":"2026-11-15T08:00:00Z","value":44},{"task_id":1,"time":"2026-11-15T08:01:00Z","value":-1}],"tasks":[{"id":1,"name":"上海电信","type":"icmp","loss":50,"avg":44,"min":44,"max":44,"total":2},{"id":2,"name":"联通","loss":0,"avg":0,"total":0}]}}"#
        let rows = try ProbeNetworkParser.history(adapter: "komari", object: JSONSerialization.jsonObject(with: Data(raw.utf8)))
        #expect(rows[0].loss == 50)
        #expect(rows[0].average == 44)
        #expect(rows[0].points.last?.latency == nil)
        #expect(rows[0].isTimeout)
        #expect(!rows[1].hasSamples)
        #expect(rows[1].loss == nil)
        #expect(rows[1].average == nil)
    }

    @Test func cfsmRejectsBooleansAndKeepsSampleLoss() throws {
        let raw = #"[{"timestamp":1763193600000,"ping_ct":null,"loss_ct":100,"ping_cu":"18.4","loss_cu":"0","ping_cm":false,"loss_cm":false,"ping_bd":35,"loss_bd":0}]"#
        let rows = try ProbeNetworkParser.history(adapter: "cfsm", object: JSONSerialization.jsonObject(with: Data(raw.utf8)), names: ["ct": "电信", "cu": "联通"])
        #expect(rows.count == 3)
        #expect(rows[0].isTimeout)
        #expect(rows[1].latency == 18.4)
        #expect(rows[1].loss == 0)
        #expect(rows[1].lossScope == "sample")
        #expect(rows[1].points.first?.date.timeIntervalSince1970 == 1763193600)
        #expect(!rows.contains(where: { $0.id == "cm" }))
    }

    @Test func komariLatestCanReuseExistingResponse() {
        let item: [String: Any] = ["ping": ["1": ["name": "移动", "latest": -1, "loss": 100, "avg": 0]]]
        let rows = ProbeNetworkParser.latest(adapter: "komari", item: item, sampledAt: nil)
        #expect(rows.first?.latency == nil)
        #expect(rows.first?.isTimeout == true)
        #expect(rows.first?.average == nil)
    }
}
