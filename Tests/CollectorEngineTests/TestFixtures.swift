import Foundation

func fixtureURL(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        fatalError("Missing test fixture: \(name)")
    }
    return url
}
