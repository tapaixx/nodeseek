import Foundation

/// App 内置的探针适配器配置。以后支持远程目录或用户导入时，在这里合并来源。
final class ProbeAdapterRegistry: Sendable {
    static let shared = ProbeAdapterRegistry()

    /// 内置配置的资源名，按显示顺序排列。
    private static let builtinResources = ["probe-adapter-komari", "probe-adapter-cfsm", "probe-adapter-monitor"]

    let engines: [ProbeAdapterEngine]

    init(bundle: Bundle = .main) {
        engines = Self.builtinResources.compactMap { name in
            guard let url = bundle.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                AppLog.error(.service, "probe adapter missing: \(name)")
                return nil
            }
            do {
                return try ProbeAdapterEngine(data: data)
            } catch {
                AppLog.error(.service, "probe adapter invalid: \(name) \(error)")
                return nil
            }
        }
    }

    init(engines: [ProbeAdapterEngine]) {
        self.engines = engines
    }

    func engine(id: String) -> ProbeAdapterEngine? {
        engines.first { $0.spec.id == id }
    }
}

/// 测试连接的结果。
struct ProbeConnectionInfo: Sendable {
    let version: String?
    let nodes: [ProbeNode]
}

nonisolated protocol ProbeFetching: Sendable {
    func testConnection(baseURL: URL, adapterID: String) async throws -> ProbeConnectionInfo
    func snapshot(for instance: ProbeInstance, reloadNodes: Bool) async throws -> ProbeSnapshot
    func history(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeHistoryPoint]
    func networkHistory(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeNetworkSeries]
    /// 探针被修改或删除后清掉内存缓存。
    func forget(instanceID: UUID) async
    func testConnection(baseURL: URL, adapterID: String, instanceID: UUID) async throws -> ProbeConnectionInfo
}

extension ProbeFetching {
    func networkHistory(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeNetworkSeries] {
        throw ProbeFetchError.unsupported
    }
    func testConnection(baseURL: URL, adapterID: String, instanceID: UUID) async throws -> ProbeConnectionInfo {
        try await testConnection(baseURL: baseURL, adapterID: adapterID)
    }
}

/// 探针网络请求。使用独立的临时会话：不带 Cookie、不落盘缓存，与 NodeSeek 登录态完全隔离。
actor ProbeService: ProbeFetching {
    static let shared = ProbeService()

    /// 节点列表变化不频繁，缓存一段时间，刷新时只请求最新状态。
    private static let nodesTTL: TimeInterval = 600
    /// 趋势数据按分钟聚合，短时间内重复请求没有意义。
    private static let historyTTL: TimeInterval = 120
    /// 响应体上限，防止异常响应占用过多内存。
    private static let maxResponseBytes = 8 * 1024 * 1024

    private let registry: ProbeAdapterRegistry
    private let session: URLSession
    private let sessions: ProbeSessionStoring
    private var nodeCache: [UUID: (nodes: [ProbeNode], at: Date)] = [:]
    private var historyCache: [String: (points: [ProbeHistoryPoint], at: Date)] = [:]
    private var historyTasks: [String: Task<[ProbeHistoryPoint], Error>] = [:]
    private var generations: [UUID: Int] = [:]
    private var networkCache: [String: (series: [ProbeNetworkSeries], at: Date)] = [:]
    private var networkTasks: [String: Task<[ProbeNetworkSeries], Error>] = [:]

    init(registry: ProbeAdapterRegistry = .shared, session: URLSession? = nil,
         sessions: ProbeSessionStoring = KeychainProbeSessionStore.shared) {
        self.registry = registry
        self.sessions = sessions
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = ProbeAdapterEngine.requestTimeout
            configuration.timeoutIntervalForResource = ProbeAdapterEngine.requestTimeout * 2
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration, delegate: SameHostRedirectDelegate(), delegateQueue: nil)
        }
    }

    func testConnection(baseURL: URL, adapterID: String) async throws -> ProbeConnectionInfo {
        try await testConnection(baseURL: baseURL, adapterID: adapterID, instanceID: UUID())
    }

    func testConnection(baseURL: URL, adapterID: String, instanceID: UUID) async throws -> ProbeConnectionInfo {
        let engine = try engine(adapterID)
        var version: String?
        if engine.spec.requests["version"] != nil, let versionSource = engine.spec.version {
            // 版本只是展示信息，拿不到不影响连接。
            version = try? engine.version(from: await load(versionSource.request, engine: engine, baseURL: baseURL))
        }
        for check in Set((engine.spec.preflight ?? []).map(\.request)) {
            try engine.runChecks(for: check, object: await load(check, engine: engine, baseURL: baseURL))
        }
        let nodes = try engine.nodes(from: await load(engine.spec.nodes.request, engine: engine, baseURL: baseURL, instanceID: instanceID))
        // 再请求一次状态，确认最新状态接口也可用（例如面板版本过旧没有 rpc2）。
        _ = try engine.statuses(from: await load(engine.spec.status.request, engine: engine, baseURL: baseURL, instanceID: instanceID))
        return ProbeConnectionInfo(version: version, nodes: nodes)
    }

    func snapshot(for instance: ProbeInstance, reloadNodes: Bool) async throws -> ProbeSnapshot {
        let generation = generations[instance.id, default: 0]
        if instance.requiresAuthentication == true, sessions.session(instanceID: instance.id, baseURL: instance.baseURL) == nil {
            throw ProbeFetchError.unauthorized
        }
        let engine = try engine(instance.adapterID)
        let nodes: [ProbeNode]
        if !reloadNodes, let cached = nodeCache[instance.id], Date().timeIntervalSince(cached.at) < Self.nodesTTL {
            nodes = cached.nodes
        } else {
            nodes = try engine.nodes(from: await load(engine.spec.nodes.request, engine: engine, baseURL: instance.baseURL, instanceID: instance.id))
            guard generation == generations[instance.id, default: 0] else { throw CancellationError() }
            nodeCache[instance.id] = (nodes, Date())
        }
        let statusObject = try await load(engine.spec.status.request, engine: engine, baseURL: instance.baseURL, instanceID: instance.id)
        guard generation == generations[instance.id, default: 0] else { throw CancellationError() }
        return ProbeSnapshot(nodes: nodes, statuses: try engine.statuses(from: statusObject), fetchedAt: Date())
    }

    func history(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeHistoryPoint] {
        let generation = generations[instance.id, default: 0]
        if instance.requiresAuthentication == true, sessions.session(instanceID: instance.id, baseURL: instance.baseURL) == nil {
            throw ProbeFetchError.unauthorized
        }
        let key = "\(instance.id.uuidString)/\(generation)/\(nodeID)/\(hours)"
        if let cached = historyCache[key], Date().timeIntervalSince(cached.at) < Self.historyTTL {
            return cached.points
        }
        // 同一节点的并发请求（列表滚动、详情页）合并成一次。
        if let running = historyTasks[key] { return try await running.value }
        let engine = try engine(instance.adapterID)
        guard let request = engine.spec.history?.request else { return [] }
        let task = Task { [baseURL = instance.baseURL] in
            try engine.history(from: await self.load(request, engine: engine, baseURL: baseURL, nodeID: nodeID, hours: hours, instanceID: instance.id))
        }
        historyTasks[key] = task
        defer { historyTasks[key] = nil }
        let points = try await task.value
        guard generation == generations[instance.id, default: 0] else { throw CancellationError() }
        historyCache[key] = (points, Date())
        return points
    }

    func networkHistory(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeNetworkSeries] {
        let generation = generations[instance.id, default: 0]
        if instance.requiresAuthentication == true, sessions.session(instanceID: instance.id, baseURL: instance.baseURL) == nil {
            throw ProbeFetchError.unauthorized
        }
        let key = "\(instance.id)/\(generation)/\(instance.adapterID)/\(instance.baseURL.absoluteString)/\(nodeID)/\(hours)"
        if let cached = networkCache[key], Date().timeIntervalSince(cached.at) < 60 { return cached.series }
        if let task = networkTasks[key] {
            let value = try await task.value
            guard generation == generations[instance.id, default: 0] else { throw CancellationError() }
            if instance.requiresAuthentication == true, sessions.session(instanceID: instance.id, baseURL: instance.baseURL) == nil {
                throw ProbeFetchError.unauthorized
            }
            return value
        }
        let engine = try engine(instance.adapterID)
        guard let mapping = engine.spec.network else { throw ProbeFetchError.unsupported }
        let task = Task {
            let object = try await self.load(mapping.request, engine: engine, baseURL: instance.baseURL,
                                             nodeID: nodeID, hours: hours, instanceID: instance.id)
            var names: [String: String] = [:]
            if mapping.format == "cfsm", let config = try? await self.load("version", engine: engine, baseURL: instance.baseURL) {
                names = ProbeNetworkParser.cfsmNames(config)
            }
            return try ProbeNetworkParser.history(adapter: mapping.format, object: object, names: names)
        }
        networkTasks[key] = task
        defer { networkTasks[key] = nil }
        let series = try await task.value
        guard generation == generations[instance.id, default: 0] else { throw CancellationError() }
        if instance.requiresAuthentication == true, sessions.session(instanceID: instance.id, baseURL: instance.baseURL) == nil {
            throw ProbeFetchError.unauthorized
        }
        networkCache[key] = (series, Date())
        return series
    }

    func forget(instanceID: UUID) {
        generations[instanceID, default: 0] += 1
        nodeCache[instanceID] = nil
        historyCache = historyCache.filter { !$0.key.hasPrefix(instanceID.uuidString) }
        for (key, task) in historyTasks where key.hasPrefix(instanceID.uuidString) { task.cancel() }
        historyTasks = historyTasks.filter { !$0.key.hasPrefix(instanceID.uuidString) }
        networkCache = networkCache.filter { !$0.key.hasPrefix(instanceID.uuidString) }
        for (key, task) in networkTasks where key.hasPrefix(instanceID.uuidString) { task.cancel() }
        networkTasks = networkTasks.filter { !$0.key.hasPrefix(instanceID.uuidString) }
    }

    private func engine(_ id: String) throws -> ProbeAdapterEngine {
        guard let engine = registry.engine(id: id) else { throw ProbeFetchError.unsupported }
        return engine
    }

    private func load(_ name: String, engine: ProbeAdapterEngine, baseURL: URL, nodeID: String? = nil, hours: Int? = nil, instanceID: UUID? = nil) async throws -> Any {
        var request: URLRequest
        do {
            request = try engine.request(name, baseURL: baseURL, nodeID: nodeID, hours: hours)
        } catch {
            throw ProbeFetchError.unsupported
        }
        if engine.spec.id == "monitor", let instanceID {
            request.setValue(sessions.session(instanceID: instanceID, baseURL: baseURL)?.header(), forHTTPHeaderField: "Cookie")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProbeFetchError.unreachable
        }
        guard data.count <= Self.maxResponseBytes, let http = response as? HTTPURLResponse else { throw ProbeFetchError.decoding }
        // 只记录请求名和状态码，不记录地址和响应体。
        if !(200..<300).contains(http.statusCode) {
            AppLog.info(.service, "probe \(engine.spec.id) \(name) http \(http.statusCode)")
        }
        return try engine.json(from: data, httpStatus: http.statusCode)
    }
}

/// 只允许同一域名、同一端口、https 的重定向，防止以后带令牌的请求被重定向到别的站点。
final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let original = task.originalRequest?.url
        let target = request.url
        let sameOrigin = target?.scheme == "https" && target?.host == original?.host && target?.port == original?.port
        completionHandler(sameOrigin ? request : nil)
    }
}
