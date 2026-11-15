import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct NodeSeekVerificationRequiredTests {
    @Test func recognizesChallengeHeaderAndHTMLWithoutTreatingNormal403AsCloudflare() throws {
        let url = URL(string: "https://www.nodeseek.com/notification#/atMe")!
        let challenge = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["cf-mitigated": "challenge"])!
        #expect(NodeSeekVerificationRequired.detect(data: Data(), response: challenge, pageURL: url)?.url == url)
        let html = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        #expect(NodeSeekVerificationRequired.detect(data: Data("<html><script src='/cdn-cgi/challenge-platform/test'></script></html>".utf8), response: html, pageURL: url) != nil)
        let denied = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Server": "cloudflare"])!
        #expect(NodeSeekVerificationRequired.detect(data: Data(#"{"success":false,"message":"Permission denied"}"#.utf8), response: denied, pageURL: url) == nil)
        #expect(NodeSeekVerificationRequired.detect(data: Data(#"{"content":"/cdn-cgi/challenge-platform/"}"#.utf8), response: html, pageURL: url) == nil)
    }
    @Test func onlyOpensHTTPSNodeSeekURLs() {
        for text in ["https://example.com/", "http://www.nodeseek.com/", "https://user:password@www.nodeseek.com/", "https://www.nodeseek.com:8443/"] {
            #expect(NodeSeekVerificationRequired.safeURL(URL(string: text)!) == NodeSeekSite.baseURL)
        }
    }
}
