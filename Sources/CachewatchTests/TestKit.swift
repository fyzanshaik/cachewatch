import Foundation

/// Minimal assertion harness standing in for Swift Testing until Xcode is installed.
/// Cases registered here are 1:1 with Tests/CollectorEngineTests and get ported there verbatim.
final class TestKit {
    private(set) var failures = 0
    private(set) var passes = 0
    private var currentCase = ""

    func run(_ name: String, _ body: (TestKit) throws -> Void) {
        currentCase = name
        do {
            try body(self)
            print("PASS \(name)")
            passes += 1
        } catch {
            fail("threw \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        guard !condition else { return }
        fail("\(message) (\(file):\(line))")
    }

    func expectEqual<V: Equatable>(_ actual: V?, _ expected: V?, _ label: String, file: String = #fileID, line: Int = #line) {
        expect(actual == expected, "\(label): expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
    }

    private func fail(_ message: String) {
        print("FAIL \(currentCase): \(message)")
        failures += 1
    }

    func finish() -> Never {
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Fixtures live in the test target; in this dev-checkout-only runner we reach them by repo path.
func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CachewatchTests
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // repo root
    return try Data(contentsOf: root.appending(path: "Tests/CollectorEngineTests/Fixtures/\(name)"))
}
