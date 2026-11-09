import Foundation
@testable import BridgeCore

// Minimal test runner (Apple's Command Line Tools ship without XCTest). SYNTHETIC tests only.
var passed = 0, failed = 0
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1 } catch { failed += 1; print("FAIL \(name): \(error)") }
}
struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ c: Bool, _ msg: @autoclosure () -> String = "expectation failed", file: StaticString = #file, line: UInt = #line) throws {
    if !c { throw Failure(description: "\(msg()) (line \(line))") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: UInt = #line) throws {
    if a != b { throw Failure(description: "\(msg) expected \(b), got \(a) (line \(line))") }
}

let repoRoot = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fixtures = repoRoot.appendingPathComponent("tests/fixtures/t3-0.1.7")
func fixture(_ name: String) -> [String: Any] {
    let d = try! Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))
    return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
}
func tmpDir() -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t3wow-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

runCodecTests()
runPixelTests()
runStoreTests()
runEngineTests()
runClientTests()
runDiscoveryTests()
runSetupTests()
runAccessTests()
runLifecycleTests()
runInstallerTransactionTests()
runInstallerRealFaultTest()
runPresentationTests()
runCapturePlanTests()
runDiagnosticsTests()
runCaptureAccessTests()
runCaptureLatchTests()
runGameIdentityTests()
runBandInspectorTests()
runBandColorTests()
runCaptureColorTests()
runDecoderRobustTests()
runScreenContextTests()
runWarmMatrixTests()
runThemeTests()
runReleaseLifecycleTests()
runReleaseSafetyTests()

print("swift tests: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
