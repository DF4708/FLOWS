// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// What Smartcar's token endpoint said to a token request. Only a refusal
/// says anything about the grant: no signal, the host breaker, a server
/// error or rate limiting are not a "no".
enum SmartcarTokenReply: Equatable {
    case granted, refused, tryLater

    /// OAuth refuses a dead or revoked grant with 400 (invalid_grant) and
    /// bad client credentials with 401. `statusCode` is nil when nothing
    /// came back.
    init(statusCode: Int?, hasAccessToken: Bool) {
        switch statusCode {
        case 200 where hasAccessToken: self = .granted
        case 400, 401: self = .refused
        default: self = .tryLater
        }
    }
}

/// OEM cloud telemetry via Smartcar (aggregates ~30 brands — Ford, GM,
/// Toyota, Nissan, Hyundai, BMW, VW… — behind one OAuth): real FUEL LEVEL
/// and TIRE PRESSURE straight from the automaker's cloud.
///
/// Setup (once, free): dashboard.smartcar.com → create an application →
/// redirect URI `flows://smartcar` → paste Client ID + Secret into
/// Settings → Data sources → tap Connect vehicle → sign into the car brand
/// → done. (Storing the secret on-device is a personal-build pattern; a
/// shipped app would proxy the token exchange through a server.)
///
/// Tokens persist in UserDefaults; refresh is automatic; fuel + tires poll
/// at launch, on demand, and every few minutes while navigating, and feed
/// VehicleStore.telemetry — real data overrides the odometer model
/// everywhere while it is current.
@MainActor
final class SmartcarLink: ObservableObject {
    @Published var clientID: String = UserDefaults.standard.string(forKey: "flows.smartcar.id") ?? "" {
        didSet { UserDefaults.standard.set(clientID, forKey: "flows.smartcar.id") }
    }
    // Sensitive: OAuth client secret + refresh token live in the Keychain,
    // never plaintext UserDefaults (which is backed up and readable off
    // device). Migrated on first access.
    @Published var clientSecret: String =
        SecureStore.migrateFromDefaults(key: "smartcar.secret", defaultsKey: "flows.smartcar.secret") {
        didSet { SecureStore.set(clientSecret, for: "smartcar.secret") }
    }
    @Published private(set) var connected =
        SecureStore.get("smartcar.refresh") != nil
    @Published private(set) var status = ""
    @Published private(set) var fuelFraction: Double?
    /// When `fuelFraction` was fetched — the app refreshes it while driving,
    /// and an old one stops standing in for the tank (`FuelReading.freshest`).
    private(set) var fuelReadAt: Date?
    @Published private(set) var tirePressuresPsi: [String: Double] = [:]

    var fuelReading: FuelReading? {
        guard let fuelFraction, let fuelReadAt else { return nil }
        return FuelReading(fraction: fuelFraction, at: fuelReadAt)
    }

    private var accessToken: String?
    private var refreshToken: String? = {
        let v = SecureStore.migrateFromDefaults(key: "smartcar.refresh", defaultsKey: "flows.smartcar.refresh")
        return v.isEmpty ? nil : v
    }()

    static let redirectURI = "flows://smartcar"

    /// CSRF nonce binding the authorize request to its callback. Generated once
    /// per connect (reused until a callback consumes it) and verified in
    /// `handleCallback`, so an injected `flows://smartcar?code=…` deep link with
    /// no/incorrect state can't connect the app to an attacker's grant.
    private var oauthState: String?

    /// The OAuth page to open in the browser (test mode works without a
    /// real car: mode=simulated).
    var connectURL: URL? {
        guard !clientID.isEmpty else { return nil }
        if oauthState == nil { oauthState = UUID().uuidString }
        let state = oauthState!
        let scope = "read_fuel read_tires read_battery read_vehicle_info"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirect = Self.redirectURI
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        return URL(string: "https://connect.smartcar.com/oauth/authorize?response_type=code"
                   + "&client_id=\(clientID)&redirect_uri=\(redirect)&scope=\(scope)"
                   + "&state=\(state)&mode=live")
    }

    /// Handle the flows://smartcar?code=…&state=… callback.
    func handleCallback(url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        // Verify the CSRF state BEFORE touching the code — reject a callback that
        // doesn't carry the exact nonce we issued.
        let returnedState = items?.first(where: { $0.name == "state" })?.value
        guard let expected = oauthState, returnedState == expected else {
            oauthState = nil
            status = "Connection rejected (state mismatch)."
            return
        }
        oauthState = nil
        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            status = "Connection cancelled."
            return
        }
        status = "Exchanging tokens…"
        await exchange(body: "grant_type=authorization_code&code=\(code)"
                       + "&redirect_uri=\(Self.redirectURI)")
        if connected { await refreshData() }
    }

    @discardableResult
    private func exchange(body: String) async -> SmartcarTokenReply {
        guard !clientID.isEmpty, !clientSecret.isEmpty,
              let url = URL(string: "https://auth.smartcar.com/oauth/token") else {
            status = "Enter the Client ID and Secret first."
            return .tryLater   // nothing was asked, so nothing was refused
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        let response = try? await ThrottledNet.fetch(request)
        let json = response.flatMap {
            try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any]
        }
        let access = json?["access_token"] as? String
        let reply = SmartcarTokenReply(
            statusCode: (response?.1 as? HTTPURLResponse)?.statusCode,
            hasAccessToken: access != nil)
        guard reply == .granted, let json, let access else {
            status = reply == .refused
                ? "Token exchange failed — check Client ID/Secret."
                : "Can't reach Smartcar right now."
            return reply
        }
        accessToken = access
        if let refresh = json["refresh_token"] as? String {
            refreshToken = refresh
            SecureStore.set(refresh, for: "smartcar.refresh")
        }
        connected = true
        status = "Connected."
        return .granted
    }

    /// A refresh is under way. Refreshes run at launch, every few minutes
    /// while navigating and on the Refresh button; overlapping ones posted
    /// the same refresh token twice.
    private var refreshing = false

    /// Pull fresh fuel + tires (auto-refreshing the token when expired).
    func refreshData() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if accessToken == nil, let refresh = refreshToken {
            let reply = await exchange(body: "grant_type=refresh_token&refresh_token=\(refresh)")
            // Smartcar refused the grant (revoked/expired) → tear down the stale
            // session instead of leaving it "Connected" forever with dead data
            // and a dead token that every refresh keeps re-posting. No signal is
            // not a refusal: this runs on the road, and one dead zone after the
            // 2-hour access token lapsed signed the driver out for good. (A grant
            // a reconnect replaced meanwhile is not the one refused.)
            if reply == .refused, refreshToken == refresh {
                disconnect()
                status = "Sign-in expired — reconnect Smartcar."
                return
            }
        }
        guard let token = accessToken else { return }   // not connected, or the exchange said why
        guard let ids = await get("https://api.smartcar.com/v2.0/vehicles", token: token) else {
            // No answer (or an expired token, renewed next time) is not an
            // empty account — and on the road this runs in dead zones.
            status = "Can't reach Smartcar right now."
            return
        }
        guard let vehicles = ids["vehicles"] as? [String], let first = vehicles.first else {
            status = "No vehicles on the account."
            return
        }
        if let fuel = await get("https://api.smartcar.com/v2.0/vehicles/\(first)/fuel",
                                token: token),
           let percent = fuel["percentRemaining"] as? Double {
            fuelFraction = percent
            fuelReadAt = Date()
        }
        if let tires = await get("https://api.smartcar.com/v2.0/vehicles/\(first)/tires/pressure",
                                 token: token) {
            // kPa → psi.
            let keys = ["frontLeft": "Front left", "frontRight": "Front right",
                        "backLeft": "Rear left", "backRight": "Rear right"]
            var out: [String: Double] = [:]
            for (key, label) in keys {
                if let kPa = tires[key] as? Double {
                    out[label] = (kPa * 0.145038 * 10).rounded() / 10
                }
            }
            if !out.isEmpty { tirePressuresPsi = out }
        }
        status = fuelFraction.map { String(format: "Cloud fuel: %.0f%%", $0 * 100) }
            ?? "Connected (no fuel endpoint on this model)."
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        fuelFraction = nil
        fuelReadAt = nil
        tirePressuresPsi = [:]
        connected = false
        SecureStore.set(nil, for: "smartcar.refresh")
        status = "Disconnected."
    }

    private func get(_ url: String, token: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await ThrottledNet.fetch(request) else { return nil }
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            accessToken = nil   // expired → next call refreshes
            return nil
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
