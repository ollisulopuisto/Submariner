//
//  SBLastFM.swift
//  Submariner
//
//  Last.fm scrobbling support.
//

import Cocoa
import Foundation
import Combine
import Security
import CommonCrypto
import os

private let lastFMLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Submariner", category: "SBLastFM")

/// Last.fm Web Services client and scrobbler.
///
/// API credentials are read from the application's Info.plist using
/// LastFMAPIKey and LastFMAPISecret. These are deliberately not hard-coded
/// in the source tree: a Last.fm API account is required for distribution.
final class SBLastFM: NSObject, ObservableObject {
    static let shared = SBLastFM()

    private static let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private static let service = "\(Bundle.main.bundleIdentifier ?? "Submariner").lastfm"
    private static let account = "sessionKey"

    @Published private(set) var username: String?
    @Published private(set) var isAuthenticated = false
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "lastFMEnabled")
            if !enabled {
                stopProgressTimer()
            } else if let track = SBPlayer.sharedInstance().currentTrack {
                trackStarted(track)
            }
        }
    }

    private var currentTrackID: String?
    private var currentTrackStartedAt: Date?
    private var hasScrobbledCurrentTrack = false
    private var progressTimer: DispatchSourceTimer?
    private var authToken: String?

    override private init() {
        enabled = UserDefaults.standard.bool(forKey: "lastFMEnabled")
        super.init()
        loadSession()
    }

    deinit {
        progressTimer?.cancel()
    }

    // MARK: - Credentials

    private var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String
    }

    private var apiSecret: String? {
        Bundle.main.object(forInfoDictionaryKey: "LastFMAPISecret") as? String
    }

    private var hasAPIConfiguration: Bool {
        guard let key = apiKey, let secret = apiSecret else { return false }
        return !key.isEmpty && !secret.isEmpty
    }

    // MARK: - Authentication

    func authenticate() {
        guard hasAPIConfiguration else {
            presentConfigurationAlert()
            return
        }

        Task {
            do {
                let token = try await requestToken()
                await MainActor.run {
                    self.authToken = token
                    guard var components = URLComponents(string: "https://www.last.fm/api/auth"),
                          let apiKey = self.apiKey else {
                        self.presentError(title: "Last.fm Authentication Failed", error: SBLastFMError.missingAPIConfiguration)
                        return
                    }
                    components.queryItems = [
                        URLQueryItem(name: "api_key", value: apiKey),
                        URLQueryItem(name: "token", value: token)
                    ]
                    guard let authURL = components.url else {
                        self.presentError(title: "Last.fm Authentication Failed", error: SBLastFMError.invalidResponse)
                        return
                    }
                    NSWorkspace.shared.open(authURL)

                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "Authorize Submariner on Last.fm"
                    alert.informativeText =
                        "A Last.fm authorization page has been opened in your browser. "
                        + "Authorize Submariner there, then return here and click Continue."
                    alert.addButton(withTitle: "Continue")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        Task {
                            do {
                                try await self.finishAuthentication(token: token)
                            } catch {
                                lastFMLogger.error("Last.fm session creation failed: \(error.localizedDescription, privacy: .public)")
                                await MainActor.run {
                                    self.presentError(title: "Last.fm Authentication Failed", error: error)
                                }
                            }
                        }
                    }
                }
            } catch {
                lastFMLogger.error("Last.fm authentication request failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.presentError(title: "Last.fm Authentication Failed", error: error)
                }
            }
        }
    }

    func disconnect() {
        deleteSessionKey()
        authToken = nil
        username = nil
        isAuthenticated = false
        enabled = false
        stopProgressTimer()
    }

    private func requestToken() async throws -> String {
        let response = try await call(method: "auth.getToken", parameters: [:], authenticated: false)
        guard let token = response["token"] as? String, !token.isEmpty else {
            throw SBLastFMError.invalidResponse
        }
        return token
    }

    private func finishAuthentication(token: String) async throws {
        let response = try await call(method: "auth.getSession",
                                       parameters: ["token": token],
                                       authenticated: false)
        guard
            let session = response["session"] as? [String: Any],
            let key = session["key"] as? String,
            let name = session["name"] as? String
        else {
            throw SBLastFMError.invalidResponse
        }

        try saveSessionKey(key)
        await MainActor.run {
            self.username = name
            self.isAuthenticated = true
            self.enabled = true
        }
        lastFMLogger.info("Authenticated with Last.fm as \(name, privacy: .public)")
    }

    private func loadSession() {
        guard let key = readSessionKey() else { return }

        Task {
            do {
                let response = try await call(method: "user.getInfo", parameters: [:], sessionKey: key)
                let session = response["user"] as? [String: Any]
                let name = session?["name"] as? String
                await MainActor.run {
                    self.username = name
                    self.isAuthenticated = name != nil
                }
                if name != nil {
                    try? await self.flushQueuedScrobbles()
                }
            } catch {
                lastFMLogger.error("Could not validate Last.fm session: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.isAuthenticated = false
                }
            }
        }
    }

    // MARK: - Playback

    func trackStarted(_ track: SBTrack) {
        guard enabled, isAuthenticated, !(track is SBEpisode) else { return }

        currentTrackID = track.objectIDString
        currentTrackStartedAt = Date()
        hasScrobbledCurrentTrack = false

        let metadata = metadata(for: track)
        Task {
            do {
                _ = try await call(method: "track.updateNowPlaying",
                                   parameters: metadata,
                                   sessionKey: readSessionKey())
            } catch {
                // Last.fm explicitly recommends not retrying failed Now Playing requests.
                lastFMLogger.error("Last.fm Now Playing failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        startProgressTimer()
    }

    func trackStopped() {
        stopProgressTimer()
        currentTrackID = nil
        currentTrackStartedAt = nil
        hasScrobbledCurrentTrack = false
    }

    /// Last.fm's scrobbling rule: a track qualifies once it has played for at
    /// least half its duration, or 4 minutes, whichever comes first — and
    /// only if the track itself is longer than 30 seconds.
    static func shouldScrobble(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 30 else { return false }
        return elapsed >= min(duration / 2, 240)
    }

    func checkProgress(currentTrack: SBTrack?, elapsed: TimeInterval, duration: TimeInterval) {
        guard
            enabled,
            isAuthenticated,
            let track = currentTrack,
            !(track is SBEpisode),
            currentTrackID == track.objectIDString,
            !hasScrobbledCurrentTrack
        else { return }

        let trackDuration = duration > 0 ? duration : TimeInterval(track.duration?.intValue ?? 0)
        guard Self.shouldScrobble(elapsed: elapsed, duration: trackDuration) else { return }

        hasScrobbledCurrentTrack = true
        let timestamp = Int((currentTrackStartedAt ?? Date()).timeIntervalSince1970)
        let metadata = metadata(for: track)

        Task {
            do {
                // Last.fm recommends sending cached scrobbles before newer ones.
                try await flushQueuedScrobbles()
                try await scrobble(metadata: metadata, timestamp: timestamp)
            } catch {
                // Scrobble failures are queued and retried in order. An invalid
                // session is queued too, so reconnecting later does not lose it.
                queueScrobble(metadata: metadata, timestamp: timestamp)
                lastFMLogger.error("Last.fm scrobble queued after failure: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                let player = SBPlayer.sharedInstance()
                self.checkProgress(currentTrack: player.currentTrack,
                                   elapsed: player.currentTime,
                                   duration: player.durationTime)
            }
        }
        progressTimer = timer
        timer.resume()
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func metadata(for track: SBTrack) -> [String: String] {
        var result: [String: String] = [:]
        result["artist"] = track.artistName ?? track.artistString ?? "Unknown Artist"
        result["track"] = track.itemName ?? "Unknown Track"

        if let album = track.albumString, !album.isEmpty {
            result["album"] = album
        }
        if let number = track.trackNumber {
            result["trackNumber"] = number.stringValue
        }
        if let duration = track.duration?.intValue, duration > 0 {
            result["duration"] = String(duration)
        }
        return result
    }

    // MARK: - API

    private func scrobble(metadata: [String: String], timestamp: Int) async throws {
        var parameters = metadata
        parameters["timestamp"] = String(timestamp)

        let response = try await call(method: "track.scrobble",
                                       parameters: parameters,
                                       sessionKey: readSessionKey())

        guard let scrobbles = response["scrobbles"] as? [String: Any] else {
            throw SBLastFMError.invalidResponse
        }

        let accepted = Self.parseResponseCount(scrobbles, key: "accepted")
        let ignored = Self.parseResponseCount(scrobbles, key: "ignored")
        if accepted == 0 && ignored == 0 {
            throw SBLastFMError.invalidResponse
        }
    }

    private func flushQueuedScrobbles() async throws {
        guard let sessionKey = readSessionKey() else { return }
        let queued = queuedScrobbles()
        guard !queued.isEmpty else { return }

        // Last.fm supports batches of up to 50 scrobbles.
        let batch = Array(queued.prefix(50))
        var parameters: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            for (key, value) in item.metadata {
                parameters["\(key)[\(index)]"] = value
            }
            parameters["timestamp[\(index)]"] = String(item.timestamp)
        }

        let response = try await call(method: "track.scrobble",
                                       parameters: parameters,
                                       sessionKey: sessionKey)
        guard let scrobbles = response["scrobbles"] as? [String: Any] else {
            throw SBLastFMError.invalidResponse
        }
        let accepted = Self.parseResponseCount(scrobbles, key: "accepted")
        let ignored = Self.parseResponseCount(scrobbles, key: "ignored")
        guard accepted + ignored >= batch.count else {
            throw SBLastFMError.invalidResponse
        }

        removeQueuedScrobbles(count: batch.count)
    }

    /// Reads a scrobble count (e.g. "accepted"/"ignored") from a Last.fm
    /// `track.scrobble` response. Last.fm reports these as either a
    /// top-level field (single scrobble) or nested under "@attr" (batch),
    /// and as either a String or a number depending on endpoint.
    static func parseResponseCount(_ object: [String: Any], key: String) -> Int {
        if let value = object[key] as? String {
            return Int(value) ?? 0
        }
        if let value = object[key] as? Int {
            return value
        }
        if let attributes = object["@attr"] as? [String: Any] {
            if let value = attributes[key] as? String {
                return Int(value) ?? 0
            }
            if let value = attributes[key] as? Int {
                return value
            }
        }
        return 0
    }

    private struct QueuedScrobble: Codable {
        let metadata: [String: String]
        let timestamp: Int
    }

    private func queueScrobble(metadata: [String: String], timestamp: Int) {
        var queue = queuedScrobbles()
        queue.append(QueuedScrobble(metadata: metadata, timestamp: timestamp))
        if queue.count > 500 {
            queue.removeFirst(queue.count - 500)
        }
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: "lastFMScrobbleQueue")
        }
    }

    private func queuedScrobbles() -> [QueuedScrobble] {
        guard let data = UserDefaults.standard.data(forKey: "lastFMScrobbleQueue"),
              let queue = try? JSONDecoder().decode([QueuedScrobble].self, from: data) else {
            return []
        }
        return queue
    }

    private func removeQueuedScrobbles(count: Int) {
        var queue = queuedScrobbles()
        guard count <= queue.count else { return }
        queue.removeFirst(count)
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: "lastFMScrobbleQueue")
        }
    }

    private func call(method: String,
                      parameters: [String: String],
                      authenticated: Bool = true,
                      sessionKey: String? = nil) async throws -> [String: Any] {
        guard let apiKey, let apiSecret else {
            throw SBLastFMError.missingAPIConfiguration
        }

        var params = parameters
        params["method"] = method
        params["api_key"] = apiKey

        if authenticated {
            guard let sessionKey = sessionKey else {
                throw SBLastFMError.notAuthenticated
            }
            params["sk"] = sessionKey
        }

        params["api_sig"] = Self.apiSignature(parameters: params, secret: apiSecret)
        params["format"] = "json"

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SBLastFMError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SBLastFMError.invalidResponse
        }

        if let error = json["error"] as? Int {
            if error == 9 {
                throw SBLastFMError.invalidSession
            }
            let message = json["message"] as? String ?? "Last.fm error \(error)"
            throw SBLastFMError.api(error, message)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SBLastFMError.http(http.statusCode)
        }

        if let status = json["lfm"] as? [String: Any],
           let statusString = status["status"] as? String,
           statusString == "failed" {
            let message = status["message"] as? String ?? "Last.fm request failed"
            let code = status["error"] as? Int ?? 0
            if code == 9 {
                throw SBLastFMError.invalidSession
            }
            throw SBLastFMError.api(code, message)
        }

        return json
    }

    /// Encodes parameters as `application/x-www-form-urlencoded`, with keys
    /// sorted for stable, reproducible request bodies.
    static func formEncode(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map {
            URLQueryItem(name: $0, value: values[$0, default: ""])
        }
        return components.percentEncodedQuery ?? ""
    }

    static func md5Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Last.fm's request signature: the sorted "key" + "value" pairs of
    /// every parameter (excluding "format" and "callback", per Last.fm's
    /// API rules) concatenated, with the shared secret appended, then MD5'd.
    static func apiSignature(parameters: [String: String], secret: String) -> String {
        let signed = parameters.filter { $0.key != "format" && $0.key != "callback" }
        let base = signed.keys.sorted().map { "\($0)\(signed[$0, default: ""])" }.joined() + secret
        return md5Hex(base)
    }
}

// MARK: - Keychain

extension SBLastFM {
    private func saveSessionKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SBLastFMError.keychain(status) }
    }

    private func readSessionKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteSessionKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - UI

extension SBLastFM {
    private func presentConfigurationAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Last.fm is not configured"
        alert.informativeText =
            "Submariner needs a Last.fm API key and shared secret. "
            + "Add LastFMAPIKey and LastFMAPISecret to the application's Info.plist/build settings."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum SBLastFMError: LocalizedError {
    case missingAPIConfiguration
    case notAuthenticated
    case invalidSession
    case invalidResponse
    case http(Int)
    case api(Int, String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIConfiguration:
            return "Last.fm API credentials are missing."
        case .notAuthenticated:
            return "Submariner is not authenticated with Last.fm."
        case .invalidSession:
            return "The Last.fm session is no longer valid. Please connect Last.fm again."
        case .invalidResponse:
            return "Last.fm returned an unexpected response."
        case .http(let status):
            return "Last.fm returned HTTP status \(status)."
        case let .api(code, message):
            return "Last.fm error \(code): \(message)"
        case .keychain(let status):
            return "Could not access the macOS Keychain (status \(status))."
        }
    }
}
