// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// Shared alert/notification components: the imminent-warning banner (used
/// while planning AND navigating — a red alert matters either way), the
/// analog refuel gauge, the towing card, and the demo gallery that previews
/// every alert with sample data (Settings → Preview alerts).

func alertEntityColor(_ name: String?) -> Color {
    switch name {
    case "red", "maroon": return .red
    case "blue", "dark blue", "light blue": return .blue
    case "green", "dark green", "light green": return .green
    case "black": return .black
    case "white": return .white
    case "silver", "gray", "grey", "dark gray", "light gray": return .gray
    case "yellow", "gold": return .yellow
    case "orange": return .orange
    case "purple": return .purple
    case "brown", "tan", "beige": return .brown
    case "pink": return .pink
    default: return .white.opacity(0.85)
    }
}

/// The imminent hazard / emergency-broadcast banner. RED alerts must be
/// PRESSED to dismiss; AMBER-style descriptions render the generic colored
/// vehicle + brand badge + person silhouette composite.
struct ImminentBannerView: View {
    @Environment(\.golden) private var golden
    let warning: AppModel.ImminentWarning
    let isCompact: Bool
    var onDismiss: () -> Void
    var onShelterDelay: (() -> Void)?
    var onFindRest: (() -> Void)?

    @Environment(\.openURL) private var openURL

    private var isRed: Bool { warning.action == .shelter }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isRed
                      ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .scaledFont(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.event)
                        .scaledFont(size: 16, weight: .heavy)
                        .lineLimit(1)
                    if warning.vehicleEntity != nil || warning.personEntity != nil {
                        HStack(spacing: 10) {
                            if let v = warning.vehicleEntity {
                                HStack(spacing: 5) {
                                    Image(systemName: v.kind.symbol)
                                        .scaledFont(size: 28)
                                        .foregroundStyle(alertEntityColor(v.colorName))
                                        .shadow(color: .black.opacity(0.45), radius: 1)
                                    if let brand = v.brand {
                                        Text(brand.uppercased())
                                            .scaledFont(size: 11, weight: .heavy)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.white)
                                            .foregroundStyle(.black)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            if let person = warning.personEntity {
                                Image(systemName: person.symbol)
                                    .scaledFont(size: 26)
                                    .foregroundStyle(alertEntityColor(person.colorName))
                                    .shadow(color: .black.opacity(0.45), radius: 1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text(warning.headline)
                        .scaledFont(size: 13, weight: .semibold)
                        .lineLimit(2)
                    if let detail = warning.detail {
                        Text(detail)
                            .font(.caption)
                            .opacity(0.85)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .opacity(0.8)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if let url = warning.sourceURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Official alert", systemImage: "link")
                            .scaledFont(size: 13, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(Color.white.opacity(0.25))
                    .clipShape(Capsule())
                }
                Spacer()
                switch warning.action {
                case .shelter:
                    if let onShelterDelay {
                        Button("Sheltering here (+1 h)") { onShelterDelay() }
                            .scaledFont(size: 14, weight: .heavy)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.tapMinimum)
                            .background(Color.white)
                            .foregroundStyle(Theme.riskRed)
                            .clipShape(Capsule())
                    }
                case .restArea:
                    Text("Passes in 1–2 h — wait it out?")
                        .font(.footnote.weight(.semibold))
                    if let onFindRest {
                        Button("Find rest area") { onFindRest() }
                            .scaledFont(size: 14, weight: .heavy)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.tapMinimum)
                            .background(Color.white)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                    }
                case .monitor:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        .background((isRed ? Theme.riskRed : Theme.riskYellow).opacity(0.95))
        .foregroundStyle(isRed ? .white : .black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
    }
}

/// The analog refuel gauge: a semicircular dial with a draggable red needle
/// — "where was the needle BEFORE you filled?" Trains the refuel-prediction
/// learning toward its 80% accuracy floor.
struct GasGaugeCard: View {
    @Environment(\.golden) private var golden
    /// Starting position (the model's own prediction).
    let predictedFraction: Double
    var accuracy: Double
    var onConfirm: (Double) -> Void
    var onNoRefuel: () -> Void
    var onDismiss: () -> Void

    @State private var fraction: Double = 0.5
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Just refueled?", systemImage: "fuelpump.circle.fill")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                // Physical dismiss assumes "yes, filled to full".
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("Drag the needle to where the gauge sat BEFORE filling — "
                 + "it teaches the range prediction (currently "
                 + String(format: "%.0f%%", accuracy * 100) + " accurate).")
                .font(.caption)
                .foregroundStyle(.secondary)
            GaugeDial(fraction: $fraction)
                // A draggable needle is unusable without sight and hard
                // with a tremor — VoiceOver gets the value spoken as a
                // percentage and adjusts it in 5% steps instead.
                .accessibilityElement()
                .accessibilityLabel("Fuel level before filling")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: fraction = min(fraction + 0.05, 1)
                    case .decrement: fraction = max(fraction - 0.05, 0)
                    @unknown default: break
                    }
                }
                // Golden sizing rather than the old hardcoded 220×130 — both
                // sides improved this control, in different dimensions.
                .frame(width: golden.step(1), height: golden.step(1) * 0.6)
            HStack(spacing: 8) {
                Button("Didn't refuel") { onNoRefuel() }
                    .scaledFont(size: 13, weight: .semibold)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .background(Theme.fill(0.06))
                    .clipShape(Capsule())
                Spacer()
                Button(String(format: "It was at %.0f%% — filled up", fraction * 100)) {
                    onConfirm(fraction)
                }
                .scaledFont(size: 13, weight: .heavy)
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(Theme.cta)
                .foregroundStyle(Theme.onCTA)
                .clipShape(Capsule())
            }
        }
        .floatingCard()
        .frame(maxWidth: golden.cardMax)
        .onAppear {
            if !appeared {
                fraction = min(max(predictedFraction, 0), 1)
                appeared = true
            }
        }
    }
}

/// The dial itself: E→F arc, ticks, centrally rotating red needle. The
/// filled arc takes its color from the tank level on an exponential curve
/// (FuelWarning.band) — green through the ordinary middle of a tank, yellow
/// only in the last third, red in the final stretch where range is a real
/// planning problem.
struct GaugeDial: View {
    @Binding var fraction: Double
    /// Set while the tank is low enough to demand action — the arc pulses.
    var alarming = false
    /// The big refuel dial labels its quartiles; the small HUD one doesn't.
    var showsQuartileLabels = true
    @State private var alarmPulse = false

    private var levelColor: Color {
        switch FuelWarning.band(fraction: fraction) {
        case .green: return Theme.riskGreen
        case .yellow: return Theme.riskYellow
        case .red: return Theme.riskRed
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let center = CGPoint(x: w / 2, y: geo.size.height - 10)
            let radius = min(w / 2 - 14, geo.size.height - 24)
            ZStack {
                // Arc E (left) → F (right).
                Circle()
                    .trim(from: 0.5, to: 1.0)
                    .stroke(Theme.fill(0.15), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                Circle()
                    .trim(from: 0.5, to: 0.5 + fraction / 2)
                    .stroke(levelColor.opacity(alarming && alarmPulse ? 0.25 : 0.75),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                // Ticks + labels.
                ForEach(0..<5) { i in
                    let angle = Angle(degrees: 180 + Double(i) * 45)
                    let inner = point(center, radius - 12, angle)
                    let outer = point(center, radius + 2, angle)
                    Path { p in
                        p.move(to: inner)
                        p.addLine(to: outer)
                    }
                    .stroke(Color.secondary, lineWidth: 2)
                    // Quartile percent callouts belong on the big refuel
                    // dial, not the small HUD one — at instrument size they
                    // crowd the needle and read as clutter.
                    if showsQuartileLabels, i > 0, i < 4 {
                        Text("\(i * 25)%")
                            .scaledFont(size: 8, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .position(point(center, radius + 14, angle))
                    }
                }
                Text("E").font(.caption.weight(.heavy)).foregroundStyle(Theme.riskRed)
                    .position(point(center, radius + 16, Angle(degrees: 180)))
                Text("F").font(.caption.weight(.heavy)).foregroundStyle(Theme.riskGreen)
                    .position(point(center, radius + 16, Angle(degrees: 360)))
                // The centrally rotating red needle. The offset puts the
                // needle's base at the bounds center (= the hub), so the
                // rotation must anchor at .center to pivot ON the hub —
                // fraction 0 lies exactly on E, 1 exactly on F. A .bottom
                // anchor pivots half a needle-length below the hub and
                // slides the needle off the dial toward the ends.
                Capsule()
                    .fill(Color.red)
                    .frame(width: 4, height: radius - 6)
                    .offset(y: -(radius - 6) / 2)
                    .rotationEffect(Angle(degrees: -90 + fraction * 180), anchor: .center)
                    .position(center)
                Circle().fill(Color.red).frame(width: 12, height: 12).position(center)
            }
            .onChange(of: alarming, initial: true) { _, on in
                // Pulse only while the tank actually demands action, and
                // stop cleanly when it doesn't (a forever-animation left
                // running costs a redraw every frame for nothing).
                if on {
                    withAnimation(.easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)) {
                        alarmPulse = true
                    }
                } else {
                    withAnimation(.default) { alarmPulse = false }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = value.location.x - center.x
                    let dy = center.y - value.location.y
                    // A finger drifting BELOW the baseline gets a negative
                    // angle near -pi, which `1 - angle/pi` maps to ~2 — the
                    // needle snapped from Empty to Full (and fed the refuel
                    // learning a reading at the wrong end of the scale).
                    // Clamp to the semicircle by the finger's SIDE instead.
                    let angle = dy >= 0
                        ? atan2(dy, dx)                // 0 = right, π = left
                        : (dx >= 0 ? 0 : .pi)          // below baseline → nearest end
                    let f = 1 - angle / .pi
                    fraction = min(max(f, 0), 1)
                }
            )
        }
    }

    private func point(_ center: CGPoint, _ r: CGFloat, _ angle: Angle) -> CGPoint {
        CGPoint(x: center.x + r * cos(angle.radians),
                y: center.y + r * sin(angle.radians))
    }
}

/// Towing card: two horizontal scales (vehicle weight, towed weight) checked
/// live against the manufacturer's GVWR / tow capacity / GCWR — violations
/// FLASH red with what actually goes wrong.
struct TowingCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    @State private var flash = false

    var body: some View {
        let ratings = model.towingRatings
        let violations = model.towingViolations
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Towing", systemImage: "link.circle.fill")
                    .scaledFont(size: 15, weight: .bold)
                Spacer()
                Toggle("", isOn: $model.towingActive)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Button { model.showTowingCard = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if model.towingActive {
                Text("Route filters set: avoiding steep grades, low bridges, "
                     + "high winds, and roads with weight signs under your "
                     + "vehicle + towing weight. Fuel prediction switched to the "
                     + "towing pattern (kept separate from your normal pattern).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(String(format: "Vehicle: %.0f lb", model.towVehicleWeightLbs))
                    .font(.caption.weight(.semibold))
                    .frame(width: 120, alignment: .leading)
                Slider(value: $model.towVehicleWeightLbs, in: 2000...40000, step: 100)
            }
            HStack {
                Text(String(format: "Towing: %.0f lb", model.towTrailerWeightLbs))
                    .font(.caption.weight(.semibold))
                    .frame(width: 120, alignment: .leading)
                Slider(value: $model.towTrailerWeightLbs, in: 0...45000, step: 100)
            }
            // Static ratings, flashing red where exceeded.
            HStack(spacing: 12) {
                ratingBadge("GVWR", ratings.gvwrLbs,
                            violated: violations.contains { if case .overGVWR = $0 { return true } else { return false } })
                ratingBadge("Tow cap", ratings.towCapacityLbs,
                            violated: violations.contains { if case .overTowCapacity = $0 { return true } else { return false } })
                ratingBadge("GCWR", ratings.effectiveGCWR,
                            violated: violations.contains { if case .overGCWR = $0 { return true } else { return false } })
            }
            ForEach(Array(violations.enumerated()), id: \.offset) { _, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.title)
                        .scaledFont(size: 13, weight: .heavy)
                        .foregroundStyle(Theme.riskRed)
                        .opacity(flash ? 1 : 0.35)
                    Text(v.consequences)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if ratings.estimated {
                Text("Class-typical ESTIMATES — the manufacturer publishes no "
                     + "ratings for this vehicle. Verify against the door-jamb "
                     + "sticker and owner's manual before towing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ratings.gvwrLbs == nil {
                Text("No ratings available — add a vehicle for towing checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .floatingCard()
        .frame(maxWidth: golden.cardMax)
        // Scoped to THIS view — see the note on the escalation card: a
        // repeatForever run through withAnimation catches every view in the
        // transaction, not just the one being pulsed.
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                   value: flash)
        .onAppear { flash = true }
    }

    private func ratingBadge(_ label: String, _ value: Double?, violated: Bool) -> some View {
        VStack(spacing: 1) {
            Text(label).scaledFont(size: 9, weight: .bold).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f lb", $0) } ?? "—")
                .scaledFont(size: 13, weight: .heavy).monospacedDigit()
                .foregroundStyle(violated ? Theme.riskRed : .primary)
                .opacity(violated && flash ? 0.35 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((violated ? Theme.riskRed.opacity(0.12) : Theme.fill(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Preview gallery: every alert/notification with sample data, plus the
/// live red-alert demo trigger (Settings → Preview alerts & notifications).
struct DemoAlertsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var sampleAmber: AppModel.ImminentWarning {
        let headline = "AMBER Alert: suspect vehicle is a red Toyota pickup truck"
        let detail = "The child is a 7-year-old girl wearing a blue jacket. "
            + "If seen, call 911 — do not approach."
        return AppModel.ImminentWarning(
            alertID: "gallery-amber", event: "Child Abduction Emergency",
            headline: headline, detail: detail,
            sourceURL: URL(string: "https://www.missingkids.org/amber"),
            action: .shelter, etaSeconds: 300,
            vehicleEntity: AlertEntityParser.vehicle(in: headline + " " + detail),
            personEntity: AlertEntityParser.person(in: detail))
    }

    private var sampleStorm: AppModel.ImminentWarning {
        AppModel.ImminentWarning(
            alertID: "gallery-storm", event: "Severe Thunderstorm Warning",
            headline: "Quarter-size hail and 60 mph gusts through 5:30 PM",
            detail: "Radar-indicated severe thunderstorm moving east at 35 mph.",
            sourceURL: URL(string: "https://www.weather.gov"),
            action: .restArea, etaSeconds: 420)
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Alert & notification gallery")
                        .scaledFont(size: 17, weight: .bold)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
                Text("Sample data — exactly what each alert looks like in use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("RED emergency broadcast (press-to-dismiss)")
                    .font(.caption.weight(.bold))
                ImminentBannerView(warning: sampleAmber, isCompact: true,
                                   onDismiss: {}, onShelterDelay: {}, onFindRest: nil)
                Text("Transient storm → rest-area recommendation")
                    .font(.caption.weight(.bold))
                ImminentBannerView(warning: sampleStorm, isCompact: true,
                                   onDismiss: {}, onShelterDelay: nil, onFindRest: {})

                Text("Refuel gauge (analog needle — drag it)")
                    .font(.caption.weight(.bold))
                    .id("cards")
                GasGaugeCard(predictedFraction: 0.35, accuracy: 0.62,
                             onConfirm: { _ in }, onNoRefuel: {}, onDismiss: {})

                Text("Towing card (weights vs manufacturer ratings)")
                    .font(.caption.weight(.bold))
                TowingCard()

                Button {
                    dismiss()
                    model.showSettings = false
                    let center = model.location.coordinate
                        ?? .init(latitude: 43.0731, longitude: -89.4012)
                    model.demoRedAlert(near: center)
                } label: {
                    Label("Demo red alert on the map (symbol + reach circle)",
                          systemImage: "exclamationmark.octagon.fill")
                        .scaledFont(size: 14, weight: .heavy)
                        .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                        .background(Theme.riskRed)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["FLOWS_DEMO_SECTION"] == "cards" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    scroller.scrollTo("cards", anchor: .top)
                }
            }
        }
        }
        // macOS panel sizing only — an iPhone sheet is narrower than 460 pt
        // and the floor pushed the gallery's edge off-screen in portrait.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

/// Review stars (yellow → shimmering gold as the count climbs) and cost "$"
/// (dark → light green with tier). Tier semantics are income-anchored — see
/// RatingsAndCost. Only renders what a public source actually supplied.
struct StarsAndBucks: View {
    let stars: Double?
    let costTier: Int?
    /// GPS-selected cost country (currency label + income anchoring).
    var currency: String = "US$"
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        HStack(spacing: 8) {
            if let stars {
                let c = RatingsAndCost.starColor(stars: stars)
                let starColor = Color(red: c.r, green: c.g, blue: c.b)
                HStack(spacing: 1) {
                    ForEach(0..<5) { i in
                        Image(systemName: Double(i) < stars.rounded(.down) ? "star.fill"
                              : (Double(i) < stars ? "star.leadinghalf.filled" : "star"))
                            .scaledFont(size: 11)
                            .foregroundStyle(starColor)
                    }
                    Text(String(format: "%.1f", stars))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                // Gold shimmer: intensity rises with the star count.
                .overlay {
                    if stars >= 4 {
                        LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 30)
                            .offset(x: shimmerPhase * 90)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                            .onAppear {
                                withAnimation(.linear(duration: 1.6)
                                    .repeatForever(autoreverses: false)) {
                                    shimmerPhase = 1
                                }
                            }
                    }
                }
                .clipped()
            }
            if let tier = costTier {
                let c = RatingsAndCost.dollarColor(tier: tier)
                let dollarColor = Color(red: c.r, green: c.g, blue: c.b)
                HStack(spacing: 0) {
                    ForEach(0..<5) { i in
                        Text("$")
                            .scaledFont(size: 11, weight: .heavy)
                            .foregroundStyle(i < tier ? dollarColor : Theme.fill(0.15))
                    }
                    Text(" \(currency)")
                        .scaledFont(size: 8, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .help("$ = affordable on that country's minimum-wage dining "
                      + "budget; $$$$$ = top 1–3% income territory. Anchors "
                      + "switch by GPS: US (USD/BLS), Canada (CAD/StatCan), "
                      + "Mexico (MXN/CONASAMI-ENIGH).")
            }
        }
    }
}

#if os(iOS)
import ContactsUI

/// The sanctioned iOS path to "pull the emergency contact from the phone":
/// Medical ID is never app-readable, but the Contacts picker needs no
/// permission and hands over exactly one chosen card.
struct ContactPicker: UIViewControllerRepresentable {
    var onPick: (String, String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String, String) -> Void
        init(onPick: @escaping (String, String) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController,
                           didSelect contact: CNContact) {
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            onPick(name, phone)
        }
    }
}
#endif


/// A park bench, drawn — SF Symbols ships no bench glyph, and the rest-area
/// button deserves the real thing.
struct BenchIcon: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width, h = canvasSize.height
            var p = Path()
            // Backrest slats.
            p.addRoundedRect(in: CGRect(x: w * 0.08, y: h * 0.10,
                                        width: w * 0.84, height: h * 0.12),
                             cornerSize: CGSize(width: 1, height: 1))
            p.addRoundedRect(in: CGRect(x: w * 0.08, y: h * 0.28,
                                        width: w * 0.84, height: h * 0.12),
                             cornerSize: CGSize(width: 1, height: 1))
            // Seat.
            p.addRoundedRect(in: CGRect(x: w * 0.04, y: h * 0.52,
                                        width: w * 0.92, height: h * 0.14),
                             cornerSize: CGSize(width: 1, height: 1))
            // Legs.
            p.addRect(CGRect(x: w * 0.14, y: h * 0.66, width: w * 0.10, height: h * 0.30))
            p.addRect(CGRect(x: w * 0.76, y: h * 0.66, width: w * 0.10, height: h * 0.30))
            ctx.fill(p, with: .style(.primary))
        }
        .frame(width: size, height: size)
    }
}
