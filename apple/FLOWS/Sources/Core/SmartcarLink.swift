// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// OEM cloud telemetry via Smartcar (aggregates ~30 brands — Ford, GM,
/// Toyota, Nissan, Hyundai, BMW, VW… — behind one OAuth): real FUEL LEVEL
/// and TIRE PRESSURE straight from the automaker's cloud.
///
/// Setup (once, free): dashboard.smartcar.com → create an application →
/// redirect URI `flows://smartcar` → paste Client ID + Secret into
/// Settings → Connected vehicle → tap Connect vehicle → sign into the car
/// brand → done. (Storing the secret on-device is a personal-build pattern;
/// a shipped app would proxy the token exchange through a server.)
///
/// Tokens persist in the Keychain; refresh is automatic; fuel + tires poll
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

    /// The ID and secret as sent: a pasted value often carries a stray
    /// space or line break, which Smartcar would reject as a wrong ID.
    private var sentID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sentSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The OAuth page to open in the browser (test mode works without a
    /// real car: mode=simulated). Both halves are needed: offering Connect
    /// with no secret sent the driver through the whole sign-in only to
    /// stall at the token exchange.
    var connectURL: URL? {
        guard !sentID.isEmpty, !sentSecret.isEmpty else { return nil }
        if oauthState == nil { oauthState = UUID().uuidString }
        let state = oauthState!
        let scope = "read_fuel read_tires read_battery read_vehicle_info"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirect = Self.redirectURI
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        return URL(string: "https://connect.smartcar.com/oauth/authorize?response_type=code"
                   + "&client_id=\(sentID)&redirect_uri=\(redirect)&scope=\(scope)"
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
            status = "That sign-in didn't match this app — tap Connect to try again."
            return
        }
        oauthState = nil
        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            status = "Connection cancelled."
            return
        }
        status = "Finishing sign-in…"
        await exchange(body: "grant_type=authorization_code&code=\(code)"
                       + "&redirect_uri=\(Self.redirectURI)")
        if connected { await refreshData() }
    }

    /// How a token exchange ended. Only `rejected` — Smartcar's token server
    /// itself saying no — may end a sign-in; no signal, a timeout or a
    /// server error says nothing about the grant.
    enum ExchangeOutcome: Equatable {
        case ok, rejected, unreachable, notSetUp
    }

    /// Reads one token answer. `statusCode` is nil when no answer came back.
    /// 400 is OAuth's invalid_grant (revoked or expired) and 401 a client
    /// the server refuses; anything else — 5xx, 429, a 200 without a token —
    /// is the server having a bad moment.
    nonisolated static func exchangeOutcome(statusCode: Int?,
                                            hasAccessToken: Bool) -> ExchangeOutcome {
        switch statusCode {
        case 200? where hasAccessToken: return .ok
        case 400?, 401?: return .rejected
        default: return .unreachable
        }
    }

    @discardableResult
    private func exchange(body: String) async -> ExchangeOutcome {
        guard !sentID.isEmpty, !sentSecret.isEmpty else {
            // Said, not swallowed: this used to return in silence and leave
            // "Exchanging tokens…" up for good.
            status = "Add the Client ID and Secret, then connect again."
            return .notSetUp
        }
        guard let url = URL(string: "https://auth.smartcar.com/oauth/token") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = Data("\(sentID):\(sentSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        let answer = try? await ThrottledNet.fetch(request)
        let json = answer.flatMap {
            try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any]
        }
        let access = json?["access_token"] as? String
        let outcome = Self.exchangeOutcome(
            statusCode: (answer?.1 as? HTTPURLResponse)?.statusCode,
            hasAccessToken: access != nil)
        guard outcome == .ok, let access else {
            status = outcome == .rejected
                ? "Smartcar said no — check the Client ID and Secret."
                : "Can't reach Smartcar right now."
            return outcome
        }
        accessToken = access
        if let refresh = json?["refresh_token"] as? String {
            refreshToken = refresh
            SecureStore.set(refresh, for: "smartcar.refresh")
        }
        connected = true
        status = "Connected."
        return .ok
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
            // Refresh REFUSED (grant revoked/expired) → tear down the stale
            // session instead of leaving it "Connected" forever with dead data
            // and a dead token that every refresh keeps re-posting. Anything
            // else keeps the sign-in: a launch in a parking garage used to
            // delete the refresh token and demand the whole sign-in again.
            switch await exchange(body: "grant_type=refresh_token&refresh_token=\(refresh)") {
            case .ok:
                break
            case .rejected:
                // A grant a reconnect replaced meanwhile is not the one refused.
                guard refreshToken == refresh else { return }
                disconnect()
                status = "Sign-in expired — reconnect Smartcar."
                return
            case .unreachable, .notSetUp:
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
        status = fuelFraction.map { String(format: "Fuel from your car: %.0f%%", $0 * 100) }
            ?? "Connected — this car doesn't share its fuel level."
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
