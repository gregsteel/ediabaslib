import Foundation

/// Walks up from this source file until `marker` exists next to it.
private func findUp(_ marker: String) -> URL {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path) { return url }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

/// Root of the whole repository (contains EdiabasLib/ and ios/).
let repoRoot = findUp("EdiabasLib")
/// This Swift package (EdiabasKit/).
let kitRoot = findUp("Package.swift")
