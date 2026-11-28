import Foundation
import Testing

/// install-doubao-driver.sh re-runs itself with sudo and then calls
/// verify-doubao-driver.sh. Under sudo, PATH holds only the system
/// directories, so the verify script must not depend on tools such as
/// Homebrew's ripgrep. These tests run the real script against a fake driver
/// bundle with stubbed signing/binary tools and a system-only PATH.
@Suite("Doubao driver scripts")
struct DoubaoDriverScriptTests {
    @Test func verifyPassesWithOnlySystemToolsOnPath() throws {
        let fixture = try DriverFixture(binaryStrings: ["MiRemoteV %ich", "MiRemoteV%ich_UID"])
        defer { fixture.remove() }

        let result = try fixture.runVerify()

        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("DOUBAO DRIVER VERIFY PASS"))
    }

    @Test func verifyStillRejectsADriverWithoutTheExpectedDeviceName() throws {
        // "%ich" must match literally, not as a pattern.
        let fixture = try DriverFixture(binaryStrings: ["MiRemoteV 2ch", "MiRemoteV%ich_UID"])
        defer { fixture.remove() }

        let result = try fixture.runVerify()

        #expect(result.status != 0)
        #expect(!result.output.contains("DOUBAO DRIVER VERIFY PASS"))
    }
}

private struct DriverFixture {
    let directory: URL
    let driver: URL
    let stubs: URL

    init(binaryStrings: [String]) throws {
        let fileManager = FileManager.default
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("RemoteMicTests.driver.\(UUID().uuidString)")
        driver = directory.appendingPathComponent("MiRemoteV2ch.driver")
        stubs = directory.appendingPathComponent("bin")
        let macOS = driver.appendingPathComponent("Contents/MacOS")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stubs, withIntermediateDirectories: true)

        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.hd838a.MiRemoteV2ch",
                "CFBundleName": "MiRemoteV2ch",
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: driver.appendingPathComponent("Contents/Info.plist"))
        try Self.writeExecutable("fake driver binary\n", to: macOS.appendingPathComponent("MiRemoteV2ch"))

        // Stand-ins for tools that need a real signed Mach-O binary.
        let printedStrings = binaryStrings.map { "print -r -- '\($0)'" }.joined(separator: "\n")
        let stubScripts = [
            "codesign": "exit 0",
            "lipo": "print arm64",
            "xcrun": "print '    minos 15.0'",
            "strings": printedStrings,
        ]
        for (name, body) in stubScripts {
            try Self.writeExecutable("#!/bin/zsh\n\(body)\n", to: stubs.appendingPathComponent(name))
        }
    }

    func runVerify() throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            root.appendingPathComponent("scripts/verify-doubao-driver.sh").path,
            driver.path,
        ]
        // Like sudo: system directories only, no Homebrew.
        process.environment = ["PATH": "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
