#!/usr/bin/env python3
"""用实际快取实现验证 iOS 15 的优化编译，提前捕获泛型解构子编译器崩溃。"""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "nodeseek/AppRuntime/Services/Messages/SharedNotificationClient.swift").read_text()
    marker = "@MainActor\nprivate final class NotificationReadCache<"
    cache = source[source.index(marker):]
    fixture = "import Foundation\n\n" + cache + """
@MainActor
public func exerciseMessageCache() async throws -> Int {
    let cache = NotificationReadCache<Int>(ttl: 5)
    let value = try await cache.value(scope: 1) { 42 }
    cache.clear()
    return value
}
"""
    with tempfile.TemporaryDirectory(prefix="message-cache-release-") as directory:
        path = Path(directory)
        (path / "Cache.swift").write_text(fixture)
        subprocess.run([
            "xcrun", "--sdk", "iphoneos", "swiftc", "-O", "-swift-version", "5",
            "-default-isolation", "MainActor", "-target", "arm64-apple-ios15.0",
            "-parse-as-library", "-c", str(path / "Cache.swift"), "-o", str(path / "Cache.o"),
        ], check=True)
    print("Optimized message cache compiled for arm64 iOS 15")


if __name__ == "__main__":
    main()
