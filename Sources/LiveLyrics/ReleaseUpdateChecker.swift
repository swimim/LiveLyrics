import Combine
import Foundation

struct AvailableRelease {
    let version: String
    let downloadURL: URL
}

@MainActor final class ReleaseUpdateChecker: ObservableObject {
    @Published private(set) var availableRelease: AvailableRelease?

    private var timer: Timer?
    private var isChecking = false

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    func start() {
        guard timer == nil else { return }
        Task { await checkForUpdate() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkForUpdate() }
        }
    }

    func checkForUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/swimim/LiveLyrics/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LiveLyrics", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(ReleaseResponse.self, from: data),
                  let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  Self.isNewer(release.tagName, than: currentVersion),
                  let archive = release.assets.first(where: { $0.name == "LiveLyrics.zip" }),
                  archive.browserDownloadURL.scheme?.lowercased() == "https" else {
                availableRelease = nil
                return
            }
            availableRelease = AvailableRelease(version: release.tagName, downloadURL: archive.browserDownloadURL)
        } catch {
            // An unavailable update service should not affect lyric playback.
        }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "v" || $0 == "V" })
            let numericPart = normalized.split(separator: "-", maxSplits: 1).first ?? ""
            let values = numericPart.split(separator: ".").compactMap { Int($0) }
            return values.isEmpty ? nil : values
        }

        guard let candidateParts = components(candidate), let currentParts = components(current) else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }
}
