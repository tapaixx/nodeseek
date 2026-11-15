import Foundation

nonisolated struct NodeSeekVerificationRequired: LocalizedError, Sendable, Equatable {
    let url: URL
    var errorDescription: String? { "站点需要 Cloudflare 验证，请点击「手动验证」，完成后重试。" }

    static func detect(data: Data, response: HTTPURLResponse, pageURL: URL) -> Self? {
        let mitigated = response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
        let challengeHTML = HTMLPayloadInspector.looksLikeHTMLDocument(data) && HTMLPayloadInspector.containsCloudflareChallenge(data)
        guard mitigated || challengeHTML else { return nil }
        return Self(url: safeURL(pageURL))
    }
    static func safeURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "https", NodeSeekSite.isNodeSeekHost(url),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return NodeSeekSite.baseURL }
        return url
    }
}
