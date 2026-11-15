import Testing
@testable import nodeseek

@MainActor
struct SettingsBuildInfoTests {
    @Test func forkVersionIsShownWithSequence() {
        let info = SettingsBuildInfo(info: [
            "CFBundleShortVersionString": "1.3.1",
            "Build Release Version": "1.3.1-2",
            "CFBundleVersion": "2",
        ])
        #expect(info.appVersion == "1.3.1-2")
        #expect(info.buildNumber == "2")
    }

    @Test func regularBuildUsesUpstreamVersion() {
        let info = SettingsBuildInfo(info: ["CFBundleShortVersionString": "1.3.1"])
        #expect(info.appVersion == "1.3.1")
    }

    @Test func emptyForkVersionFallsBackToUpstream() {
        let info = SettingsBuildInfo(info: [
            "CFBundleShortVersionString": "1.3.1", "Build Release Version": "",
        ])
        #expect(info.appVersion == "1.3.1")
    }
}
