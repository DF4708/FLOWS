// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// A starred address: one press plans a route to it from the current GPS fix.
struct FavoriteAddress: Codable, Identifiable, Equatable {
    /// The place's role, with its map symbol — home, office, and the other
    /// common haunts.
    enum Symbol: String, Codable, CaseIterable, Identifiable {
        case home = "Home"
        case office = "Office"
        case school = "School"
        case gym = "Gym"
        case other = "Favorite"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .office: return "briefcase.fill"
            case .school: return "graduationcap.fill"
            case .gym: return "dumbbell.fill"
            case .other: return "star.fill"
            }
        }
    }

    var id = UUID()
    var name: String
    var symbol: Symbol
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Persisted favorites — sealed on disk under their OWN key.
///
/// These used to live as plain JSON in UserDefaults. A favourite is, almost
/// always, the driver's home address with coordinates, and UserDefaults is
/// included in iCloud and local backups by default — so the single most
/// identifying fact the app holds was the one thing it wrote in the clear
/// and let leave the device. It is now sealed like the learned data but
/// under a separate key (`Keyspace.favorites`), because "Erase everything
/// FLOWS has learned" must not delete the Home the driver typed in.
///
/// Injectable defaults so tests run against their own suite instead of the
/// app's: a non-standard suite keeps the old defaults-backed path, which
/// keeps tests hermetic and off the Keychain.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteAddress] = []

    private let defaults: UserDefaults
    private static let key = "flows.favorites"
    /// nil when running against a test suite (defaults-backed).
    private let sealedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults == UserDefaults.standard,
           let dir = FileManager.default.urls(
               for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            sealedURL = dir.appendingPathComponent("flows_favorites.json")
        } else {
            sealedURL = nil
        }
        if let url = sealedURL {
            if let saved = SecureBehaviorStore.load(
                [FavoriteAddress].self, from: url, keyspace: .favorites) {
                favorites = saved
            } else if let data = defaults.data(forKey: Self.key),
                      let saved = try? JSONDecoder().decode([FavoriteAddress].self, from: data) {
                // One-time upgrade from the plist: seal it, then scrub the
                // plaintext copy so the next backup no longer carries it.
                favorites = saved
                if SecureBehaviorStore.save(saved, to: url, keyspace: .favorites) {
                    defaults.removeObject(forKey: Self.key)
                    FlowsDiag.log(.info, "privacy",
                                  "favorites moved out of UserDefaults into sealed storage")
                }
            }
        } else if let data = defaults.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode([FavoriteAddress].self, from: data) {
            favorites = saved
        }
    }

    /// Add (or update by same name) and persist.
    func add(_ favorite: FavoriteAddress) {
        if let i = favorites.firstIndex(where: { $0.name == favorite.name }) {
            favorites[i] = favorite
        } else {
            favorites.append(favorite)
        }
        persist()
    }

    func remove(_ favorite: FavoriteAddress) {
        // Match by id OR name: add() dedups by name and can replace an entry with
        // a new struct (new id), so a UI holding the pre-replacement value must
        // still be able to remove it. Names are unique here, so name-match is safe.
        favorites.removeAll { $0.id == favorite.id || $0.name == favorite.name }
        persist()
    }

    func contains(name: String) -> Bool {
        favorites.contains { $0.name == name }
    }

    private func persist() {
        if let url = sealedURL {
            if !SecureBehaviorStore.save(favorites, to: url, keyspace: .favorites) {
                print("[Favorites] sealed persist failed")
            }
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(favorites), forKey: Self.key)
        } catch {
            // Surface the failure instead of swallowing it — a silent encode
            // failure would desync the persisted list from what's on screen.
            print("[Favorites] persist failed: \(error)")
        }
    }
}
