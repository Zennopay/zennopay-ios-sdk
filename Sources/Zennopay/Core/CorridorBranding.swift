import Foundation

/// Corridor-aware scanner branding: which country the user is paying into and
/// which scheme logos to surface under the reticle ("Look for these logos
/// before scanning"). Keyed by the backend corridor identifier carried in the
/// session JWT's `zennopay:corridor` claim (e.g. `vn_vietqr`, `th_promptpay`).
///
/// The chips are STYLED TEXT/VECTOR approximations of the scheme wordmarks
/// (VietQR red/blue, MoMo pink square, ZaloPay blue, NAPAS red/blue) — we do
/// NOT ship trademark bitmaps. Rendering happens in the UI layer; this registry
/// is pure data so it is unit-testable on the macOS SwiftPM host and extensible
/// as corridors launch (add an `Entry` via `register`).
enum CorridorBranding {

    /// A colored run of text inside a chip wordmark, e.g. ("Viet", red) +
    /// ("QR", blue). Colors are packed 0xRRGGBB.
    struct Segment: Equatable {
        let text: String
        let rgb: UInt32
    }

    /// One scheme chip: a white (or brand-colored) rounded square with a
    /// wordmark approximation.
    struct SchemeChip: Equatable {
        let id: String
        /// Chip background, packed 0xRRGGBB. White for wordmark-on-light chips;
        /// a brand color (e.g. MoMo pink) for logo-on-brand chips.
        let backgroundRGB: UInt32
        /// The wordmark runs. Rendered on one line, or stacked when `stacked`.
        let segments: [Segment]
        /// Stack the segments vertically (MoMo's "mo / mo" block).
        let stacked: Bool

        init(id: String, backgroundRGB: UInt32 = 0xFFFFFF, segments: [Segment], stacked: Bool = false) {
            self.id = id
            self.backgroundRGB = backgroundRGB
            self.segments = segments
            self.stacked = stacked
        }
    }

    /// The branding entry for one corridor.
    struct Entry: Equatable {
        /// Backend corridor id, e.g. "vn_vietqr".
        let corridor: String
        /// Destination-country display name ("Vietnam").
        let countryName: String
        /// Human scheme label for captions ("VietQR").
        let schemeName: String
        /// The logo chips to show under the reticle, in display order.
        let chips: [SchemeChip]
        /// One-line help copy: which QRs this corridor accepts.
        let supportedQRHelp: String
    }

    // MARK: - Built-in corridors (v1 scope: VN + TH)

    static let vietnam = Entry(
        corridor: "vn_vietqr",
        countryName: "Vietnam",
        schemeName: "VietQR",
        chips: [
            SchemeChip(id: "vietqr", segments: [
                Segment(text: "Viet", rgb: 0xDA251D),
                Segment(text: "QR", rgb: 0x00559F),
            ]),
            SchemeChip(id: "momo", backgroundRGB: 0xA50064, segments: [
                Segment(text: "mo", rgb: 0xFFFFFF),
                Segment(text: "mo", rgb: 0xFFFFFF),
            ], stacked: true),
            SchemeChip(id: "zalopay", segments: [
                Segment(text: "Zalo", rgb: 0x0068FF),
                Segment(text: "pay", rgb: 0x00A85F),
            ], stacked: true),
            SchemeChip(id: "napas", segments: [
                Segment(text: "na", rgb: 0xED1C24),
                Segment(text: "pas", rgb: 0x21409A),
            ]),
        ],
        supportedQRHelp: "Vietnamese bank-transfer QRs on the NAPAS VietQR network — including QRs shown in MoMo, ZaloPay, and bank apps."
    )

    static let thailand = Entry(
        corridor: "th_promptpay",
        countryName: "Thailand",
        schemeName: "PromptPay",
        chips: [
            SchemeChip(id: "promptpay", segments: [
                Segment(text: "Prompt", rgb: 0x113F67),
                Segment(text: "Pay", rgb: 0x1B9DD9),
            ], stacked: true),
            SchemeChip(id: "truemoney", segments: [
                Segment(text: "True", rgb: 0xF05A22),
                Segment(text: "Money", rgb: 0x2B2B2B),
            ], stacked: true),
        ],
        supportedQRHelp: "Thai PromptPay merchant QRs — including QRs shown in TrueMoney and Thai bank apps."
    )

    /// The mutable registry. Seeded with the v1 corridors; partners/future
    /// corridors extend it via `register`.
    private(set) static var registry: [String: Entry] = [
        vietnam.corridor: vietnam,
        thailand.corridor: thailand,
    ]

    /// Add or replace a corridor entry.
    static func register(_ entry: Entry) {
        registry[entry.corridor] = entry
    }

    /// Look up the branding for a corridor id (case-insensitive). Nil when the
    /// corridor is unknown — the UI hides the branding row rather than guessing.
    static func entry(for corridor: String?) -> Entry? {
        guard let corridor, !corridor.isEmpty else { return nil }
        return registry[corridor.lowercased()]
    }
}
