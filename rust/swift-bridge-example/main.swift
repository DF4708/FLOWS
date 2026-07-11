// FLOWS — Swift ↔ Rust FFI demonstration (Phase R0).
//
// Shows the Swift UI calling the Rust flows-core static library over the
// C ABI. In the real app this lives inside a SwiftUI view model; here it is
// a standalone snippet proving the bridge.
//
// Build (once flows-core is compiled to libflows_core.a):
//   1. cd rust && cargo build --release          # produces libflows_core.a
//   2. clang -x c -c bridge_shim.c ...            # or use the bridging header
//   3. swiftc main.swift -import-objc-header flows_core.h \
//        -L target/release -lflows_core -o ffi_demo
//   4. ./ffi_demo
//
// The bridging header (flows_core.h) declares:
//   const char* flows_risk_label(double score);
//   const char* flows_risk_rgb_hex(double score);
//   int32_t flows_distance_matrix(const double* a, size_t n,
//                                 const double* b, size_t m, double* out);

import Foundation

// These are the extern "C" symbols exported by flows-core/src/ffi.rs.
// Declared here for the standalone snippet; the real app imports them via a
// bridging header generated in the Xcode build.
@_silgen_name("flows_risk_label")
func flows_risk_label(_ score: Double) -> UnsafePointer<CChar>

@_silgen_name("flows_distance_matrix")
func flows_distance_matrix(
    _ a: UnsafePointer<Double>, _ n: Int,
    _ b: UnsafePointer<Double>, _ m: Int,
    _ out: UnsafeMutablePointer<Double>
) -> Int32

func riskLabel(_ score: Double) -> String {
    // The Rust side returns a 'static C string — safe to wrap, never freed.
    String(cString: flows_risk_label(score))
}

func distanceMatrix(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [Double] {
    let aFlat = a.flatMap { [$0.0, $0.1] }
    let bFlat = b.flatMap { [$0.0, $0.1] }
    var out = [Double](repeating: 0, count: a.count * b.count)
    _ = out.withUnsafeMutableBufferPointer { outBuf in
        aFlat.withUnsafeBufferPointer { aBuf in
            bFlat.withUnsafeBufferPointer { bBuf in
                flows_distance_matrix(
                    aBuf.baseAddress!, a.count,
                    bBuf.baseAddress!, b.count,
                    outBuf.baseAddress!
                )
            }
        }
    }
    return out
}

// Demonstrate: risk band + a 3-4-5 distance, computed by the Rust core.
print("risk 0.75 ->", riskLabel(0.75))          // expect: Yellow
print("risk 0.20 ->", riskLabel(0.20))          // expect: Transparent
let d = distanceMatrix([(0, 0)], [(3, 4)])
print("distance (0,0)->(3,4) ->", d[0])          // expect: 5.0
