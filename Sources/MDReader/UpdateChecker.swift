import AppKit

/// Checks GitHub for a newer release. One small HTTPS request, at most once a week,
/// and only when "Check for updates" is on. Nothing is downloaded or installed automatically.
enum UpdateChecker {
    struct Release {
        let version: String
        let url: URL
    }

    enum Result {
        case available(Release)
        case upToDate
        case failed(String)
    }

    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "MDRGitHubRepo") as? String ?? "rboundi/mdreader"
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer release seen by an earlier check, so the badge survives relaunches between checks.
    static var knownUpdate: Release? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.checkForUpdates),
            let version = defaults.string(forKey: Prefs.latestVersion),
            let url = defaults.url(forKey: Prefs.latestVersionURL),
            isNewer(version, than: currentVersion)
        else { return nil }
        return Release(version: version, url: url)
    }

    static func checkIfDue(completion: @escaping (Release) -> Void) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.checkForUpdates) else { return }
        let last = defaults.double(forKey: Prefs.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 7 * 24 * 60 * 60 else { return }
        check { result in
            if case .available(let release) = result { completion(release) }
        }
    }

    static func check(completion: @escaping (Result) -> Void) {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MDReader/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                result = .upToDate  // no releases published yet
            } else if let data, status == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String,
                let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                result = isNewer(version, than: currentVersion)
                    ? .available(Release(version: version, url: page)) : .upToDate
            } else {
                result = .failed(error?.localizedDescription ?? "GitHub returned status \(status).")
            }
            DispatchQueue.main.async {
                let defaults = UserDefaults.standard
                switch result {
                case .available(let release):
                    defaults.set(release.version, forKey: Prefs.latestVersion)
                    defaults.set(release.url, forKey: Prefs.latestVersionURL)
                    defaults.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheck)
                case .upToDate:
                    defaults.removeObject(forKey: Prefs.latestVersion)
                    defaults.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheck)
                case .failed:
                    break
                }
                completion(result)
            }
        }.resume()
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let (x, y) = (parse(a), parse(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }
}
