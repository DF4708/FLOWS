import Foundation
import os
/// Names RiskFieldService mentions that the oracle never exercises: the perf
/// signposter, and the seasonal model's week (the harness passes weeks
/// itself, through HarmonicClimatology.WeekTrig).
let flowsSignposter = OSSignposter(subsystem: "oracle", category: "perf")
enum SeasonalRiskModel { nonisolated static func week(_ date: Date = Date()) -> Int { 0 } }
