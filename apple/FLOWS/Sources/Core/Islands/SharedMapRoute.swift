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

/// A map line's points, read and written without a pointer in sight.
///
/// MapKit hands coordinates in and out through C buffers.
///
/// PROMISE (each member): the buffer is an array this code owns, the count
/// given to MapKit is that array's own count, the range asked for lies
/// inside the line's `pointCount`, and MapKit copies during the call and
/// keeps no pointer.
extension MKPolyline {
    /// Every point of the line, in order.
    var coordinateList: [CLLocationCoordinate2D] {
        let n = pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        unsafe getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    /// One point of the line; nil when `index` is outside it.
    func coordinate(at index: Int) -> CLLocationCoordinate2D? {
        guard index >= 0, index < pointCount else { return nil }
        var one = CLLocationCoordinate2D()
        unsafe getCoordinates(&one, range: NSRange(location: index, length: 1))
        return one
    }
}

enum MapLines {
    /// A straight-segment line through `points`.
    static func line(_ points: [CLLocationCoordinate2D]) -> MKPolyline {
        unsafe MKPolyline(coordinates: points, count: points.count)
    }

    /// The great-circle line through `points` (a flight's arc).
    static func greatCircle(_ points: [CLLocationCoordinate2D]) -> MKGeodesicPolyline {
        unsafe MKGeodesicPolyline(coordinates: points, count: points.count)
    }
}
