// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit

/// A road MapKit answered with, shared between tasks.
///
/// `MKRoute` is a class MapKit has not marked `Sendable`, so the compiler
/// cannot prove sharing it is safe.
///
/// PROMISE: FLOWS only reads a route. MapKit builds it once, in answer to a
/// directions request, and gives no way to change it afterwards (every
/// property is read-only), so two tasks reading it at once cannot race.
struct SharedMapRoute: @unchecked Sendable {
    let route: MKRoute
    init(_ route: MKRoute) { self.route = route }
}
