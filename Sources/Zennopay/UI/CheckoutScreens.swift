#if canImport(SwiftUI)
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Root container that renders one screen per `CheckoutState`. Presented
/// modally by `presentCheckout`. Screens match the partner-approved reference
/// designs: full-screen scanner with corridor branding, LOCAL-currency-primary
/// review, processing card + tip banner, and a receipt card that waits for an
/// explicit Done (no auto-dismiss).
@available(iOS 14.0, macOS 13.0, *)
struct CheckoutContainerView: View {
    @ObservedObject var vm: CheckoutViewModel
    /// The last raw payload we scanned, retained so we can silently re-quote.
    @State private var lastRawPayload: String = ""

    private var theme: ZTheme { vm.theme }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                content
                PoweredByZennopay(darkSurface: isDarkSurface, theme: theme)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
        }
        .preferredColorScheme(theme.forcedColorScheme)
        .task { await vm.start() }
    }

    /// The scanner is always chrome-on-black (a camera surface); every other
    /// screen uses the themed background.
    private var background: Color {
        switch vm.state {
        case .scanning: return .black
        case .validatingScan: return vm.validatingFromKeypad ? theme.bg : .black
        default: return theme.bg
        }
    }

    /// Whether the current screen sits on the black camera surface (footer
    /// must use the white-wordmark variant there).
    private var isDarkSurface: Bool {
        switch vm.state {
        case .scanning: return true
        case .validatingScan: return !vm.validatingFromKeypad
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .scanning, .validatingScan:
            if vm.validatingFromKeypad, case .validatingScan = vm.state {
                QuoteLoadingScreen(theme: theme)
            } else {
                ScannerScreen(vm: vm, lastRawPayload: $lastRawPayload)
            }
        case .amountEntry:
            KeypadScreen(vm: vm)
        case .quoted(let quote):
            ReviewScreen(vm: vm, quote: quote, rawPayload: lastRawPayload, confirming: false)
        case .confirming:
            if let quote = vm.lastQuote {
                ReviewScreen(vm: vm, quote: quote, rawPayload: lastRawPayload, confirming: true)
            } else {
                ProcessingScreen(vm: vm)
            }
        case .awaitingResult:
            ProcessingScreen(vm: vm)
        case .finished(let result):
            ResultScreen(result: result, vm: vm)
        }
    }
}

// MARK: - Shared chrome

/// Trust footer rendered at the bottom of EVERY PaymentSheet screen:
/// "Powered by" + the Zennopay wordmark. Deliberately not part of the partner
/// appearance API — the payment surface is always visibly Zennopay-operated.
/// The wordmark asset has a light-surface (dark text) and dark-surface (white
/// text) variant; the scanner's camera surface forces the dark variant.
struct PoweredByZennopay: View {
    /// Forces the white-wordmark variant (used over the black camera surface).
    var darkSurface: Bool = false
    let theme: ZTheme

    @Environment(\.colorScheme) private var scheme

    private var assetName: String {
        (darkSurface || scheme == .dark) ? "zp-powered-dark" : "zp-powered-light"
    }

    var body: some View {
        HStack(spacing: 7) {
            Text("Powered by")
                .zpFont(theme, 13)
                .foregroundColor(darkSurface ? Color.white.opacity(0.55) : theme.text3)
            Image(assetName, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .offset(y: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Powered by Zennopay")
        .accessibilityIdentifier("zp.poweredBy")
    }
}

/// Header row used by the themed screens: leading close/back, centered title
/// (+ optional subtitle), optional trailing control.
@available(iOS 14.0, macOS 13.0, *)
struct SheetHeader<Trailing: View>: View {
    let theme: ZTheme
    var title: String
    var subtitle: String? = nil
    var leadingSystemImage: String = "xmark"
    let onLeading: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(title)
                    .zpFont(theme, 17, .semibold)
                    .foregroundColor(theme.text)
                if let subtitle {
                    Text(subtitle)
                        .zpFont(theme, 13)
                        .foregroundColor(theme.text2)
                }
            }
            HStack {
                Button(action: onLeading) {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(theme.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(leadingSystemImage == "xmark" ? "Close" : "Back")
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, ZTokens.xs)
    }
}

@available(iOS 14.0, macOS 13.0, *)
extension SheetHeader where Trailing == EmptyView {
    init(
        theme: ZTheme, title: String, subtitle: String? = nil,
        leadingSystemImage: String = "xmark", onLeading: @escaping () -> Void
    ) {
        self.init(
            theme: theme, title: title, subtitle: subtitle,
            leadingSystemImage: leadingSystemImage, onLeading: onLeading
        ) { EmptyView() }
    }
}

// MARK: - Scanner screen

/// Full-screen camera scanner per the reference: grey corner-bracket reticle
/// with an animated accent scan-line, corridor-aware "Look for these logos
/// before scanning" chips, and a bottom control row (gallery / Paste code /
/// torch) plus an "I need help scanning" link.
@available(iOS 14.0, macOS 13.0, *)
struct ScannerScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    @Binding var lastRawPayload: String

    @State private var torchOn = false
    @State private var showGallery = false
    @State private var showPasteSheet = false
    @State private var showHelpSheet = false
    @State private var galleryHint: String?

    private var theme: ZTheme { vm.theme }
    private var branding: CorridorBranding.Entry? { CorridorBranding.entry(for: vm.corridor) }

    var body: some View {
        ZStack {
            cameraViewport
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: ZTokens.md)
                ScannerReticle(accent: theme.accent)
                    .frame(maxWidth: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, ZTokens.xl)
                Spacer(minLength: ZTokens.md)
                brandingSection
                controlsRow
                helpLink
            }
            .padding(.bottom, ZTokens.sm)
            if case .validatingScan = vm.state {
                checkingPill
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteCodeSheet(theme: theme) { raw in
                showPasteSheet = false
                lastRawPayload = raw
                Task { await vm.submitScannedCode(raw) }
            }
        }
        .sheet(isPresented: $showHelpSheet) {
            ScanHelpSheet(theme: theme, branding: branding)
        }
        .modifier(GallerySheet(isPresented: $showGallery, onDecode: handleGalleryDecode))
    }

    // MARK: viewport

    @ViewBuilder
    private var cameraViewport: some View {
        #if canImport(AVFoundation) && os(iOS)
        // The camera can be authorized but have NO capture device — every iOS
        // Simulator, and any hardware without a rear camera. The chrome (and
        // the Paste code / gallery paths) still render over black there.
        if vm.cameraAuthorization == .authorized,
           AVCaptureDevice.default(for: .video) != nil {
            QRScannerView(
                onCode: { raw in
                    lastRawPayload = raw
                    Task { await vm.submitScannedCode(raw) }
                },
                torchOn: torchOn
            )
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
        #else
        Color.black.ignoresSafeArea()
        #endif
    }

    private var topBar: some View {
        HStack {
            Button(action: { vm.cancel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
        }
        .padding(.horizontal, ZTokens.sm)
        .overlay(cameraHint)
    }

    /// Small hint when there is no usable camera (Simulator / denied): steer
    /// to the paste + gallery affordances without blocking the chrome.
    @ViewBuilder
    private var cameraHint: some View {
        if vm.cameraAuthorization == .denied || !hasCameraDevice {
            Text(vm.cameraAuthorization == .denied
                 ? "Camera access is off — use Paste code, or allow camera in Settings."
                 : "Camera unavailable — use Paste code or your gallery.")
                .zpSystemFont(12)
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, ZTokens.xxl)
        }
    }

    private var hasCameraDevice: Bool {
        #if canImport(AVFoundation) && os(iOS)
        return AVCaptureDevice.default(for: .video) != nil
        #else
        return false
        #endif
    }

    private var checkingPill: some View {
        HStack(spacing: ZTokens.sm) {
            ProgressView().tint(.white)
            Text("Checking…")
                .zpSystemFont(15, .medium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, ZTokens.lg)
        .padding(.vertical, ZTokens.md)
        .background(Color.black.opacity(0.7))
        .clipShape(Capsule())
    }

    // MARK: corridor branding

    @ViewBuilder
    private var brandingSection: some View {
        VStack(spacing: ZTokens.md) {
            if let hint = galleryHint ?? vm.transientError.map(humanMessage) {
                Text(hint)
                    .zpSystemFont(13)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ZTokens.sm)
                    .padding(.vertical, ZTokens.xs)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(theme.radiusCard)
                    .padding(.horizontal, ZTokens.lg)
            }
            if let branding {
                Text("Look for these logos before scanning")
                    .zpSystemFont(15, .medium)
                    .foregroundColor(.white)
                HStack(spacing: 14) {
                    ForEach(branding.chips, id: \.id) { chip in
                        SchemeChipView(chip: chip)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Supported schemes: \(branding.chips.map(\.id).joined(separator: ", "))")
            }
        }
        .padding(.bottom, ZTokens.lg)
    }

    // MARK: bottom controls

    private var controlsRow: some View {
        HStack(spacing: ZTokens.md) {
            circleButton(systemImage: "photo.fill", label: "Choose a QR from your photos") {
                galleryHint = nil
                showGallery = true
            }

            Button {
                showPasteSheet = true
            } label: {
                Text("Paste code")
                    .zpSystemFont(17, .semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("zp.scan.pasteCode")

            circleButton(
                systemImage: torchOn ? "bolt.fill" : "bolt.slash.fill",
                label: torchOn ? "Turn flashlight off" : "Turn flashlight on",
                disabled: !torchAvailable
            ) {
                torchOn.toggle()
            }
        }
        .padding(.horizontal, ZTokens.lg)
    }

    private var torchAvailable: Bool {
        #if canImport(AVFoundation) && os(iOS)
        return AVCaptureDevice.default(for: .video)?.hasTorch ?? false
        #else
        return false
        #endif
    }

    private func circleButton(
        systemImage: String, label: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.16))
                .clipShape(Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(label)
    }

    private var helpLink: some View {
        Button { showHelpSheet = true } label: {
            Text("I need help scanning")
                .zpSystemFont(16, .semibold)
                .foregroundColor(.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.top, ZTokens.xs)
    }

    private func handleGalleryDecode(_ raw: String?) {
        guard let raw, !raw.isEmpty else {
            galleryHint = "No QR code found in that image. Try another."
            return
        }
        galleryHint = nil
        lastRawPayload = raw
        Task { await vm.submitScannedCode(raw) }
    }
}

/// Grey corner-bracket reticle with the animated accent scan-line: a bright
/// line with a translucent trail sweeping top→bottom on repeat (reference).
@available(iOS 14.0, macOS 13.0, *)
struct ScannerReticle: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .top) {
                CornerBrackets()
                    .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // Scan line + trail, clipped to the bracket bounds.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 3)
                    LinearGradient(
                        colors: [accent.opacity(0.30), accent.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 54)
                }
                .padding(.horizontal, 10)
                // Reduce Motion: a static line resting mid-reticle instead of
                // the repeating sweep.
                .offset(y: reduceMotion ? (h - 60) * 0.45 : (sweep ? h - 60 : 4))
                .animation(
                    reduceMotion ? nil
                        : .linear(duration: 2.0).repeatForever(autoreverses: false),
                    value: sweep
                )
            }
            .clipped()
        }
        .onAppear { if !reduceMotion { sweep = true } }
        .accessibilityHidden(true)
    }
}

/// The four rounded corner brackets of the scan reticle.
@available(iOS 13.0, macOS 13.0, *)
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = min(rect.width, rect.height) * 0.12
        let r: CGFloat = 14

        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r + len))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r + len, y: rect.minY))

        // Top-right
        p.move(to: CGPoint(x: rect.maxX - r - len, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + len))

        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - len))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r - len, y: rect.maxY))

        // Bottom-left
        p.move(to: CGPoint(x: rect.minX + r + len, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - len))

        return p
    }
}

/// One scheme chip: white (or brand-colored) rounded square with a styled
/// wordmark approximation. NOT a trademark bitmap.
@available(iOS 14.0, macOS 13.0, *)
struct SchemeChipView: View {
    let chip: CorridorBranding.SchemeChip

    var body: some View {
        Group {
            if chip.stacked {
                VStack(spacing: -2) { segmentTexts }
            } else {
                HStack(spacing: 0) { segmentTexts }
            }
        }
        .frame(width: 56, height: 56)
        .background(Color(rgb: chip.backgroundRGB))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var segmentTexts: some View {
        ForEach(Array(chip.segments.enumerated()), id: \.offset) { _, seg in
            Text(seg.text)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(Color(rgb: seg.rgb))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// The paste-QR sheet (replaces the old inline paste field). Keeps the
/// existing accessibility identifiers the XCUITest depends on:
/// `zp.scan.pasteField`, `zp.scan.pasteButton`, `zp.scan.continue`.
@available(iOS 14.0, macOS 13.0, *)
struct PasteCodeSheet: View {
    let theme: ZTheme
    let onSubmit: (String) -> Void
    @State private var pasteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ZTokens.md) {
            Text("Paste code")
                .zpFont(theme, 20, .semibold)
                .foregroundColor(theme.text)
                .padding(.top, ZTokens.lg)
            Text("Paste the QR code text to continue.")
                .zpFont(theme, 14)
                .foregroundColor(theme.text2)
            TextEditor(text: $pasteText)
                .accessibilityIdentifier("zp.scan.pasteField")
                .frame(height: 120)
                .padding(ZTokens.sm)
                .background(theme.surface)
                .cornerRadius(theme.radiusInput)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusInput)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
            #if canImport(UIKit) && os(iOS)
            // One-tap paste: fills the field from the system clipboard. Reliable
            // where the keyboard Cmd+V/long-press paste isn't wired (Simulator).
            Button {
                pasteText = UIPasteboard.general.string ?? pasteText
            } label: {
                Text("Paste from clipboard")
                    .zpSystemFont(14, .medium)
                    .foregroundColor(theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("zp.scan.pasteButton")
            #endif
            Button("Continue") { onSubmit(pasteText) }
                .accessibilityIdentifier("zp.scan.continue")
                .buttonStyle(PrimaryButtonStyle(theme: theme))
                .disabled(pasteText.isEmpty)
            Spacer()
        }
        .padding(ZTokens.md)
        .background(theme.bg.ignoresSafeArea())
    }
}

/// "I need help scanning" sheet: which QRs the corridor supports + the
/// alternate capture paths.
@available(iOS 14.0, macOS 13.0, *)
struct ScanHelpSheet: View {
    let theme: ZTheme
    let branding: CorridorBranding.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: ZTokens.md) {
            Text("Scanning help")
                .zpFont(theme, 20, .semibold)
                .foregroundColor(theme.text)
                .padding(.top, ZTokens.lg)
            if let branding {
                helpRow(
                    icon: "qrcode",
                    text: "This payment goes to \(branding.countryName). \(branding.supportedQRHelp)"
                )
            } else {
                helpRow(
                    icon: "qrcode",
                    text: "Point the camera at the merchant's payment QR. We'll show you the amount before anything is charged."
                )
            }
            helpRow(
                icon: "photo",
                text: "Have a screenshot? Tap the photo button to pick the QR image from your gallery."
            )
            helpRow(
                icon: "doc.on.clipboard",
                text: "Have the code as text? Tap Paste code and paste it in."
            )
            helpRow(
                icon: "lock.shield",
                text: "You always review the amount and merchant before paying — nothing is charged while scanning."
            )
            Spacer()
        }
        .padding(ZTokens.md)
        .background(theme.bg.ignoresSafeArea())
    }

    private func helpRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: ZTokens.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(theme.accent)
                .frame(width: 28)
            Text(text)
                .zpFont(theme, 14)
                .foregroundColor(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Presents the iOS photo-library QR picker as a sheet. A no-op on macOS so the
/// shared screen still compiles on the SwiftPM host.
@available(iOS 14.0, macOS 13.0, *)
struct GallerySheet: ViewModifier {
    @Binding var isPresented: Bool
    let onDecode: (String?) -> Void

    func body(content: Content) -> some View {
        #if canImport(PhotosUI) && os(iOS)
        content.sheet(isPresented: $isPresented) {
            GalleryQRPicker(onDecode: { decoded in
                isPresented = false
                onDecode(decoded)
            })
        }
        #else
        content
        #endif
    }
}

// MARK: - Static-QR amount keypad

/// Local-currency amount entry for STATIC QRs (no amount in the code), per the
/// reference: huge local amount, converted-amount chip (once a rate is known),
/// Review button, and a large in-sheet numeric keypad (1-9, 000, 0, ⌫).
@available(iOS 14.0, macOS 13.0, *)
struct KeypadScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    /// Entered amount in MAJOR units as a digit string ("35000").
    @State private var digits: String = ""
    /// Increments on each refused keypress to drive the hero shake.
    @State private var shakes: CGFloat = 0
    /// Non-nil while the "why was my key refused" copy is shown.
    @State private var limitHint: KeypadInputPolicy.Hint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: ZTheme { vm.theme }
    /// Static QRs carry no currency until scanned; infer from the corridor.
    private var currencyNumeric: String {
        vm.corridor == "th_promptpay" ? "764" : "704"
    }
    private var minorUnits: Int { (Int(digits) ?? 0) * 100 }
    private var overLimit: Bool {
        DisbursementLimit.exceedsVNDPerTransaction(
            minorUnits: minorUnits, currencyNumeric: currencyNumeric
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                theme: theme, title: "Payment",
                leadingSystemImage: "chevron.left",
                onLeading: { vm.reScanFromKeypad() }
            )
            Spacer()
            amountHero
                .modifier(ShakeEffect(animatableData: shakes))
            Spacer()
            if let limitHint {
                Text(hintCopy(limitHint))
                    .zpFont(theme, 13, .medium)
                    .foregroundColor(theme.pending)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZTokens.md)
                    .padding(.bottom, ZTokens.sm)
                    .accessibilityIdentifier("zp.keypad.limitHint")
                    .transition(.opacity)
            }
            if overLimit {
                // Belt-and-braces: unreachable via the keypad (input past the
                // cap is refused), but kept for any restored/edge state.
                InlineError(
                    message: "This is above the ₫5,000,000 limit per payment. Enter a smaller amount.",
                    theme: theme
                )
                .padding(.horizontal, ZTokens.md)
                .padding(.bottom, ZTokens.sm)
            }
            Button("Review") {
                Task { await vm.submitStaticAmount(minorUnits: minorUnits) }
            }
            .buttonStyle(PrimaryButtonStyle(theme: theme))
            .disabled(minorUnits <= 0 || overLimit)
            .accessibilityIdentifier("zp.keypad.review")
            .padding(.horizontal, ZTokens.md)
            .padding(.bottom, ZTokens.md)
            NumericKeypad(theme: theme) { key in handle(key) }
                .padding(.horizontal, ZTokens.lg)
                .padding(.bottom, ZTokens.md)
        }
    }

    private var amountHero: some View {
        VStack(spacing: ZTokens.md) {
            HStack(alignment: .top, spacing: 2) {
                Text(CurrencyDisplay.symbol(forNumeric: currencyNumeric))
                    .zpFont(theme, 34, .bold, hero: true)
                    .foregroundColor(theme.text)
                    .padding(.top, 6)
                Text(digits.isEmpty ? "0" : CurrencyDisplay.groupedNumber(Double(Int(digits) ?? 0), fractionDigits: 0))
                    .zpFont(theme, 64, .bold, hero: true)
                    .monospacedDigit()
                    .foregroundColor(digits.isEmpty ? theme.text3 : theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(digits.isEmpty
                ? "Amount, not yet entered"
                : "Amount: \(CurrencyDisplay.groupedNumber(Double(Int(digits) ?? 0), fractionDigits: 0)) \(CurrencyDisplay.label(forNumeric: currencyNumeric))")
            .accessibilityIdentifier("zp.amount.entry")
            Text("Enter the amount from the merchant")
                .zpFont(theme, 13)
                .foregroundColor(theme.text3)
        }
        .padding(.horizontal, ZTokens.lg)
    }

    private func handle(_ key: NumericKeypad.Key) {
        switch key {
        case .digit(let d):
            apply(KeypadInputPolicy.appendingDigit(digits, d, currencyNumeric: currencyNumeric))
        case .tripleZero:
            apply(KeypadInputPolicy.appendingTripleZero(digits, currencyNumeric: currencyNumeric))
        case .backspace:
            if !digits.isEmpty { digits.removeLast() }
            if limitHint != nil { withAnimation(ZTokens.stateChange) { limitHint = nil } }
        }
    }

    /// Accepted keys update the digits (and clear any hint); refused keys
    /// shake the hero and surface the limit copy — the amount NEVER exceeds
    /// the cap, so the hero cannot overflow.
    private func apply(_ outcome: KeypadInputPolicy.Outcome) {
        switch outcome {
        case .accepted(let next):
            if next != digits { digits = next }
            if limitHint != nil { withAnimation(ZTokens.stateChange) { limitHint = nil } }
        case .refused(let hint):
            withAnimation(ZTokens.stateChange) { limitHint = hint }
            if reduceMotion {
                shakes = 0  // no motion; the hint copy alone signals refusal
            } else {
                withAnimation(.linear(duration: ZTokens.durMedium)) { shakes += 1 }
            }
        }
    }

    private func hintCopy(_ hint: KeypadInputPolicy.Hint) -> String {
        switch hint {
        case .vndPerTransactionLimit:
            return "The limit is ₫5,000,000 per payment."
        case .maxLength:
            return "That's the largest amount the keypad accepts."
        }
    }
}

/// The reference keypad: 1..9, 000, 0, backspace — accent-colored glyphs.
@available(iOS 14.0, macOS 13.0, *)
struct NumericKeypad: View {
    enum Key: Equatable {
        case digit(String), tripleZero, backspace
    }
    let theme: ZTheme
    let onKey: (Key) -> Void

    private let rows: [[Key]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.tripleZero, .digit("0"), .backspace],
    ]

    var body: some View {
        VStack(spacing: ZTokens.sm) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: ZTokens.sm) {
                    ForEach(0..<rows[r].count, id: \.self) { c in
                        keyButton(rows[r][c])
                    }
                }
            }
        }
    }

    private func keyButton(_ key: Key) -> some View {
        Button {
            onKey(key)
        } label: {
            Group {
                switch key {
                case .digit(let d):
                    Text(d).zpSystemFont(30, .medium, hero: true)
                case .tripleZero:
                    Text("000").zpSystemFont(26, .medium, hero: true)
                case .backspace:
                    Image(systemName: "arrow.left").font(.system(size: 24, weight: .medium))
                }
            }
            .monospacedDigit()
            .foregroundColor(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(keyLabel(key))
    }

    private func keyLabel(_ key: Key) -> String {
        switch key {
        case .digit(let d): return d
        case .tripleZero: return "triple zero"
        case .backspace: return "delete"
        }
    }
}

/// Simple themed loading state while a keypad-entered amount is being quoted.
@available(iOS 14.0, macOS 13.0, *)
struct QuoteLoadingScreen: View {
    let theme: ZTheme
    var body: some View {
        VStack(spacing: ZTokens.md) {
            ProgressView().tint(theme.accent)
            Text("Getting your rate…")
                .zpFont(theme, 15)
                .foregroundColor(theme.text2)
        }
    }
}

// MARK: - Review screen (LOCAL currency primary)

/// The quote/review screen per the reference: merchant card with flag avatar +
/// bank/account + verified badge, the LOCAL amount as the hero, the USD amount
/// as a secondary chip, a fees row, an optional purpose field, and slide-to-pay
/// (whose knob becomes a spinner while the confirm runs).
@available(iOS 14.0, macOS 13.0, *)
struct ReviewScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    let quote: CheckoutState.Quote
    let rawPayload: String
    let confirming: Bool

    @State private var now = Date()
    @State private var showBreakdown = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var theme: ZTheme { vm.theme }
    private var branding: CorridorBranding.Entry? { CorridorBranding.entry(for: vm.corridor) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(theme: theme, title: "Payment", onLeading: { vm.cancel() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: ZTokens.lg) {
                    merchantCard
                        .padding(.top, ZTokens.sm)
                    amountHero
                        .padding(.vertical, ZTokens.md)
                    detailRows
                    purposeField
                    if let err = vm.transientError {
                        InlineError(message: humanMessage(err), theme: theme)
                    }
                }
                .padding(.horizontal, ZTokens.md)
            }
            SlideToConfirm(
                label: "Slide to pay",
                theme: theme,
                isConfirming: confirming
            ) {
                Task { await vm.confirm() }
            }
            .padding(.horizontal, ZTokens.md)
            .padding(.bottom, ZTokens.md)
        }
        .onReceive(ticker) { t in
            now = t
            if quote.isExpired(now: t), !confirming {
                Task { await vm.refreshQuote(rawPayload: rawPayload) }
            }
        }
        .sheet(isPresented: $showBreakdown) {
            FeeBreakdownSheet(quote: quote, theme: theme)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: merchant card

    private var merchantCard: some View {
        HStack(spacing: ZTokens.md) {
            Text(CurrencyDisplay.flag(forNumeric: quote.localCurrency))
                .font(.system(size: 26))
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color(rgb: 0xE94B4B).opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.displayMerchantName)
                    .zpFont(theme, 16, .semibold)
                    .foregroundColor(theme.text)
                if let bankLine {
                    Text(bankLine)
                        .zpFont(theme, 13)
                        .monospacedDigit()
                        .foregroundColor(theme.text2)
                }
                if let payoutLine {
                    Text(payoutLine)
                        .zpFont(theme, 12, .medium)
                        .foregroundColor(theme.success)
                }
                if let scheme = schemeName {
                    Label("Verified on \(scheme)", systemImage: "checkmark.seal.fill")
                        .zpFont(theme, 12, .medium)
                        .foregroundColor(theme.success)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(ZTokens.md)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    /// "VIETCOMBANK • 10230…0000" from the display-only QR peek.
    private var bankLine: String? {
        let bank = vm.qrPeek?.bankName
        let account = vm.qrPeek?.accountMasked
        switch (bank, account) {
        case let (b?, a?): return "\(b) • \(a)"
        case let (b?, nil): return b
        case let (nil, a?): return a
        default: return quote.merchantCity
        }
    }

    /// "Vietnam (VietQR Payout)".
    private var payoutLine: String? {
        guard let branding else { return nil }
        return "\(branding.countryName) (\(branding.schemeName) Payout)"
    }

    private var schemeName: String? {
        switch quote.scheme?.lowercased() {
        case "promptpay": return "PromptPay"
        case "vietqr": return "VietQR"
        case .some(let s) where !s.isEmpty: return s.uppercased()
        default: return branding?.schemeName
        }
    }

    // MARK: amount hero — LOCAL primary, USD chip secondary

    private var amountHero: some View {
        VStack(spacing: ZTokens.md) {
            Text(localHeadline)
                .zpFont(theme, 56, .bold, hero: true)
                .monospacedDigit()
                .foregroundColor(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .accessibilityIdentifier("zp.amount.local")
            HStack(spacing: 6) {
                Text("🇺🇸")
                    .font(.system(size: 14))
                Text(usdString)
                    .zpFont(theme, 15, .semibold)
                    .monospacedDigit()
                    .foregroundColor(theme.text)
                    .accessibilityLabel("US dollar equivalent \(usdString)")
                    .accessibilityIdentifier("zp.amount.usd")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        }
    }

    private var localHeadline: String {
        guard let minor = quote.localAmountMinorUnits else { return usdString }
        return CurrencyDisplay.formatMinor(minor, numeric: quote.localCurrency)
    }

    private var usdString: String {
        CurrencyDisplay.formatUSDCents(quote.amountUSDCents)
    }

    // MARK: rows

    private var detailRows: some View {
        VStack(spacing: 0) {
            Button {
                showBreakdown = true
            } label: {
                row {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You'll pay exactly")
                            .zpFont(theme, 15, .semibold)
                            .foregroundColor(theme.text)
                        Text("Total with fees")
                            .zpFont(theme, 13)
                            .foregroundColor(theme.text2)
                    }
                } value: {
                    HStack(spacing: 4) {
                        Text(usdString)
                            .zpFont(theme, 15, .semibold)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(theme.text)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.text3)
                    }
                    .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the full payment breakdown, including fees and the exchange rate")
            .accessibilityIdentifier("zp.review.breakdown")
            if let rate = CurrencyDisplay.exchangeRateLine(
                usdCents: quote.amountUSDCents,
                localMinorUnits: quote.localAmountMinorUnits,
                localCurrency: quote.localCurrency
            ) {
                Divider().background(theme.border)
                row {
                    Text("Exchange rate")
                        .zpFont(theme, 13)
                        .foregroundColor(theme.text2)
                } value: {
                    Text(rate)
                        .zpFont(theme, 13)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(theme.text2)
                        .layoutPriority(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, ZTokens.md)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private func row<L: View, V: View>(
        @ViewBuilder label: () -> L, @ViewBuilder value: () -> V
    ) -> some View {
        HStack {
            label()
            Spacer()
            value()
        }
        .padding(.vertical, 14)
    }

    private var purposeField: some View {
        TextField("Purpose of payment (optional)", text: $vm.purposeText)
            .zpFont(theme, 15)
            .foregroundColor(theme.text)
            .padding(ZTokens.md)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusSlide)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusSlide)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .disabled(confirming)
            .accessibilityIdentifier("zp.review.purpose")
    }
}

// MARK: - Processing screen

/// Post-confirm processing per the reference: a card with a spinner and the
/// 30-second promise, a dark tip banner, and a Done button that lets the user
/// leave while processing continues (delivers `.pending`). After ~30s a bottom
/// sheet escalates: "taking longer than usual".
@available(iOS 14.0, macOS 13.0, *)
// MARK: - Fee breakdown sheet

/// Tapping "You'll pay exactly" opens the full cost breakdown: what the
/// merchant receives, the locked FX rate, the subtotal, fees, and any offer
/// applied. The staging quote carries no fee model yet, so the fee line is
/// $0.00 and the offer row is hidden until a quote carries one — the layout
/// is already structured for both.
struct FeeBreakdownSheet: View {
    let quote: CheckoutState.Quote
    let theme: ZTheme

    @Environment(\.dismiss) private var dismiss

    /// Fee in USD cents. Comes from the quote the day the backend prices
    /// fees; until then the total IS the wallet debit.
    private var feeUSDCents: Int { 0 }
    /// Offer/promo line (e.g. "Zero-fee launch offer"). Rendered only when
    /// present.
    private var offerLabel: String? { feeUSDCents == 0 ? "Zero-fee launch pricing" : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: ZTokens.md) {
            HStack {
                Text("Payment breakdown")
                    .zpFont(theme, 17, .semibold)
                    .foregroundColor(theme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.text2)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(theme.surface))
                }
                .accessibilityLabel("Close breakdown")
                .accessibilityIdentifier("zp.breakdown.close")
            }
            .padding(.top, ZTokens.lg)

            VStack(spacing: 0) {
                breakdownRow("Merchant receives", localString, emphasized: false)
                divider
                if let rate = CurrencyDisplay.exchangeRateLine(
                    usdCents: quote.amountUSDCents,
                    localMinorUnits: quote.localAmountMinorUnits,
                    localCurrency: quote.localCurrency
                ) {
                    breakdownRow("Exchange rate", rate, emphasized: false)
                    divider
                }
                breakdownRow("Subtotal", CurrencyDisplay.formatUSDCents(quote.amountUSDCents), emphasized: false)
                divider
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Convenience fee")
                            .zpFont(theme, 14)
                            .foregroundColor(theme.text2)
                        if let offerLabel {
                            Text(offerLabel)
                                .zpFont(theme, 12, .semibold)
                                .foregroundColor(theme.success)
                        }
                    }
                    Spacer()
                    Text(CurrencyDisplay.formatUSDCents(feeUSDCents))
                        .zpFont(theme, 14)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundColor(feeUSDCents == 0 ? theme.success : theme.text)
                        .layoutPriority(1)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                divider
                breakdownRow(
                    "You'll pay exactly",
                    CurrencyDisplay.formatUSDCents(quote.amountUSDCents + feeUSDCents),
                    emphasized: true
                )
            }
            .padding(.horizontal, ZTokens.md)
            .background(RoundedRectangle(cornerRadius: theme.radiusCard).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusCard).strokeBorder(theme.border, lineWidth: 1))

            Text("The merchant always receives the exact QR amount in their currency. Your wallet is debited in USD at the locked rate above — no hidden margin is added to the rate.")
                .zpFont(theme, 12)
                .foregroundColor(theme.text3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZTokens.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg.ignoresSafeArea())
    }

    private var localString: String {
        guard let minor = quote.localAmountMinorUnits else {
            return CurrencyDisplay.formatUSDCents(quote.amountUSDCents)
        }
        return CurrencyDisplay.formatMinorWithLabel(minor, numeric: quote.localCurrency)
    }

    private var divider: some View {
        Divider().background(theme.border)
    }

    private func breakdownRow(_ label: String, _ value: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .zpFont(theme, emphasized ? 15 : 14, emphasized ? .semibold : .regular)
                .foregroundColor(emphasized ? theme.text : theme.text2)
            Spacer()
            Text(value)
                .zpFont(theme, emphasized ? 16 : 14, emphasized ? .semibold : .regular)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(theme.text)
                .layoutPriority(1)
        }
        .padding(.vertical, 12)
        // One VoiceOver element per row: "Subtotal, $140.00".
        .accessibilityElement(children: .combine)
    }
}

struct ProcessingScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    @State private var showDelaySheet = false

    private var theme: ZTheme { vm.theme }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: ZTokens.md) {
                SheetHeader(theme: theme, title: "", onLeading: { vm.leaveWhileProcessing() })
                processingCard
                tipBanner
                Button("Done") { vm.leaveWhileProcessing() }
                    .buttonStyle(PrimaryButtonStyle(theme: theme))
                    .accessibilityIdentifier("zp.processing.done")
            }
            .padding(.horizontal, ZTokens.md)
            .padding(.bottom, ZTokens.md)

            if showDelaySheet {
                delaySheet
                    .transition(.move(edge: .bottom))
            }
        }
        .task {
            // Delay escalation (reference f62): after ~30s of processing, slide
            // up the "taking longer than usual" sheet. Polling continues.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            withAnimation(ZTokens.stateChange) { showDelaySheet = true }
        }
    }

    private var processingCard: some View {
        VStack(spacing: ZTokens.md) {
            Spacer()
            ProgressView()
                .scaleEffect(1.8)
                .tint(theme.accent)
                .padding(.bottom, ZTokens.lg)
            Text("Payment processing…")
                .zpFont(theme, 16, .semibold)
                .foregroundColor(theme.text)
                .accessibilityIdentifier("zp.processing.title")
            Text("This can take up to 30 seconds")
                .zpFont(theme, 14)
                .foregroundColor(theme.text2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var tipBanner: some View {
        HStack(alignment: .top, spacing: ZTokens.md) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 16))
                .foregroundColor(Color(rgb: 0xF5C242))
            Text("The merchant may have already received your payment. Check with them to confirm.")
                .zpFont(theme, 13)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZTokens.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .fill(Color(rgb: 0x171C26))
        )
    }

    /// Reference f62: bottom sheet after ~30s.
    private var delaySheet: some View {
        VStack(spacing: ZTokens.sm) {
            Capsule()
                .fill(theme.text3.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, ZTokens.sm)
            Text("Payment processing")
                .zpFont(theme, 20, .bold)
                .foregroundColor(theme.text)
            Text("This payment is taking longer than usual to process. You can check with the merchant in the meantime — if it does not complete, the money will be refunded back to your account.")
                .zpFont(theme, 14)
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ZTokens.md)
            Button("Done") { vm.leaveWhileProcessing() }
                .buttonStyle(PrimaryButtonStyle(theme: theme))
                .padding(ZTokens.md)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedCorner(radius: 16)
                .fill(theme.surface)
                .shadow(color: Color.black.opacity(0.25), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Top-rounded rectangle for the delay bottom sheet.
@available(iOS 13.0, macOS 13.0, *)
struct RoundedCorner: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Result screens

@available(iOS 14.0, macOS 13.0, *)
struct ResultScreen: View {
    let result: PaymentResult
    @ObservedObject var vm: CheckoutViewModel

    private var theme: ZTheme { vm.theme }

    var body: some View {
        switch result {
        case .completed:
            ReceiptScreen(vm: vm)
        case let .failed(_, error):
            FailureScreen(vm: vm, error: error)
        case .pending:
            PendingDetailScreen(vm: vm)
        case .canceled:
            // No UI — the host receives PaymentResult.canceled.
            Color.clear
        }
    }
}

/// Success receipt per the reference: Receipt title + share, a white card with
/// the green check, "Payment successful", timestamp, the LOCAL amount as hero,
/// and merchant/account/transaction/purpose rows. NO auto-dismiss — Done
/// delivers `.completed` and closes.
@available(iOS 14.0, macOS 13.0, *)
struct ReceiptScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    private var theme: ZTheme { vm.theme }
    private var receipt: CheckoutViewModel.Receipt? { vm.receipt }
    /// True when reopened via `presentReceipt` and the payment was refunded —
    /// the debit happened then was returned, so the receipt swaps to refund copy.
    private var isRefunded: Bool { vm.receiptDisplayStatus == .refunded }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(theme: theme, title: "Receipt", onLeading: { vm.closeFromResult() }) {
                Button(action: share) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(theme.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share receipt")
            }
            ScrollView(showsIndicators: false) {
                ReceiptCardBody(theme: theme, receipt: receipt, isRefunded: isRefunded, entered: entered)
                    .padding(.horizontal, ZTokens.md)
                    .padding(.top, ZTokens.sm)
            }
            Button("Done") { vm.closeFromResult() }
                .buttonStyle(PrimaryButtonStyle(theme: theme))
                .accessibilityIdentifier("zp.receipt.done")
                .padding(.horizontal, ZTokens.md)
                .padding(.bottom, ZTokens.md)
        }
        .onAppear {
            if reduceMotion {
                entered = true
            } else {
                withAnimation(.easeOut(duration: ZTokens.durMedium)) { entered = true }
            }
        }
    }

    static func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy, h:mm:ss a"
        return f.string(from: date)
    }

    private func share() {
        #if canImport(UIKit) && os(iOS)
        guard let r = receipt else { return }
        var lines = ["Payment successful"]
        if let minor = r.localMinorUnits {
            lines.append(CurrencyDisplay.formatMinorWithLabel(minor, numeric: r.localCurrency))
        }
        lines.append("Paid: \(CurrencyDisplay.formatUSDCents(r.usdCents))")
        lines.append("Merchant: \(r.merchantName)")
        if let account = r.accountMasked { lines.append("Account: \(account)") }
        lines.append("Transaction: \(r.transactionID ?? r.intentID)")
        if !r.purpose.isEmpty { lines.append("Purpose: \(r.purpose)") }
        lines.append("Date: \(Self.timestampString(r.timestamp))")
        let activity = UIActivityViewController(
            activityItems: [lines.joined(separator: "\n")], applicationActivities: nil
        )
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(activity, animated: true)
        #endif
    }
}

/// The receipt card body (green check / refund glyph, status title, timestamp,
/// LOCAL amount hero, and the merchant / account / transaction / paid rows).
/// Extracted from `ReceiptScreen` so it renders both inside the scroll view AND
/// directly (SwiftUI previews / offscreen `ImageRenderer` QA, which does not
/// rasterize `ScrollView` content). Pure display — no view model, no side
/// effects — fed the same `Receipt` model on the checkout and receipt-reopen
/// paths alike.
@available(iOS 14.0, macOS 13.0, *)
struct ReceiptCardBody: View {
    let theme: ZTheme
    let receipt: CheckoutViewModel.Receipt?
    var isRefunded: Bool = false
    var entered: Bool = true

    var body: some View {
        VStack(spacing: ZTokens.md) {
            Image(systemName: isRefunded ? "arrow.uturn.left.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(isRefunded ? theme.pending : theme.success)
                .scaleEffect(entered ? 1 : 0.8)
                .opacity(entered ? 1 : 0)
                .padding(.top, ZTokens.lg)
            Text(isRefunded ? "Payment refunded" : "Payment successful")
                .zpFont(theme, 20, .bold)
                .foregroundColor(isRefunded ? theme.pending : theme.success)
                .accessibilityIdentifier("zp.result.title")
            if let r = receipt {
                Text(ReceiptScreen.timestampString(r.timestamp))
                    .zpFont(theme, 14)
                    .monospacedDigit()
                    .foregroundColor(theme.text2)
                if isRefunded {
                    Text("This payment was refunded to your wallet.")
                        .zpFont(theme, 14)
                        .foregroundColor(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, ZTokens.md)
                        .accessibilityIdentifier("zp.receipt.refundNote")
                }
                if let minor = r.localMinorUnits {
                    Text(CurrencyDisplay.formatMinorWithLabel(minor, numeric: r.localCurrency))
                        .zpFont(theme, 34, .bold, hero: true)
                        .monospacedDigit()
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, ZTokens.md)
                        .accessibilityIdentifier("zp.receipt.amount")
                        .padding(.bottom, ZTokens.sm)
                }
                VStack(spacing: 0) {
                    receiptRow("Merchant name", r.merchantName)
                    if let account = r.accountMasked {
                        receiptRow("Account number", account)
                    }
                    receiptRow("Transaction ID", r.transactionID ?? r.intentID, monospaced: true)
                    receiptRow("You paid exactly", CurrencyDisplay.formatUSDCents(r.usdCents), monospaced: true)
                    if !r.purpose.isEmpty {
                        receiptRow("Purpose of payment", r.purpose)
                    }
                }
                .padding(.horizontal, ZTokens.md)
            }
            Spacer(minLength: ZTokens.lg)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusSlide)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private func receiptRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .zpFont(theme, 13)
                .foregroundColor(theme.text2)
            Text(value)
                .zpFont(theme, 16, .semibold)
                .monospacedDigit()
                .foregroundColor(theme.text)
            Divider().background(theme.border).padding(.top, ZTokens.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ZTokens.sm)
        // One VoiceOver element per row: "Merchant name, Cà Phê Sài Gòn".
        .accessibilityElement(children: .combine)
    }
}

/// Failure per the redesign: red icon, human reason, refund reassurance when
/// the wallet was debited, and Try again / Done.
@available(iOS 14.0, macOS 13.0, *)
struct FailureScreen: View {
    @ObservedObject var vm: CheckoutViewModel
    let error: ZennopayError

    private var theme: ZTheme { vm.theme }

    var body: some View {
        VStack(spacing: ZTokens.lg) {
            SheetHeader(theme: theme, title: "", onLeading: { vm.closeFromResult() })
            Spacer()
            ZStack {
                Circle().fill(theme.failureSoft).frame(width: 84, height: 84)
                Image(systemName: "xmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(theme.failure)
            }
            Text("Payment failed")
                .zpFont(theme, 24, .semibold)
                .foregroundColor(theme.text)
                .accessibilityIdentifier("zp.result.title")
            Text(failureReason(error))
                .zpFont(theme, 14)
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ZTokens.lg)
            if vm.walletDebited {
                Text("If the payment does not complete, the money will be refunded back to your account.")
                    .zpFont(theme, 14)
                    .foregroundColor(theme.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ZTokens.lg)
            }
            Spacer()
            VStack(spacing: ZTokens.sm) {
                if canRetry {
                    Button("Try again") { Task { await vm.retry() } }
                        .buttonStyle(PrimaryButtonStyle(theme: theme))
                }
                Button { vm.closeFromResult() } label: {
                    Text("Done")
                        .zpFont(theme, 16, .medium)
                        .foregroundColor(theme.text2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.bottom, ZTokens.md)
        }
        .padding(.horizontal, ZTokens.md)
    }

    /// Retry re-fires confirm with the same idempotency key — only sensible
    /// when a quote existed and the failure wasn't a session-level dead end.
    private var canRetry: Bool {
        switch error {
        case .sessionExpired, .jwtExpired, .invalidJWT, .malformedToken, .intentMismatch:
            return false
        default:
            return vm.lastQuote != nil
        }
    }
}

/// Pending detail (reference f68): the payment is still processing after the
/// poll budget — status, the 30-minute promise + auto-refund reassurance, and
/// the known facts (rate, totals, date). Done delivers `.pending`.
@available(iOS 14.0, macOS 13.0, *)
struct PendingDetailScreen: View {
    @ObservedObject var vm: CheckoutViewModel

    private var theme: ZTheme { vm.theme }
    private var receipt: CheckoutViewModel.Receipt? { vm.receipt }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(theme: theme, title: "Payment", onLeading: { vm.closeFromResult() })
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: ZTokens.md) {
                    HStack {
                        Spacer()
                        VStack(spacing: ZTokens.sm) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 44))
                                .foregroundColor(theme.pending)
                            Text("Processing")
                                .zpFont(theme, 15, .medium)
                                .foregroundColor(theme.text2)
                                .accessibilityIdentifier("zp.result.title")
                            if let r = receipt {
                                Text(CurrencyDisplay.formatUSDCents(r.usdCents))
                                    .zpFont(theme, 32, .bold, hero: true)
                                    .monospacedDigit()
                                    .foregroundColor(theme.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .accessibilityLabel(
                                        "You paid \(CurrencyDisplay.formatUSDCents(r.usdCents)) US dollars"
                                    )
                                if let minor = r.localMinorUnits {
                                    Text(CurrencyDisplay.formatMinorWithLabel(minor, numeric: r.localCurrency))
                                        .zpFont(theme, 15)
                                        .monospacedDigit()
                                        .foregroundColor(theme.text2)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, ZTokens.lg)

                    detailBlock("Status", "Processing")
                    Text("Payment is still processing. It may take up to 30 minutes. You can check with the merchant in the meantime. If the payment does not complete, the money will be refunded back to your account.")
                        .zpFont(theme, 14)
                        .foregroundColor(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let r = receipt {
                        if let rate = CurrencyDisplay.exchangeRateLine(
                            usdCents: r.usdCents,
                            localMinorUnits: r.localMinorUnits,
                            localCurrency: r.localCurrency
                        ) {
                            Divider().background(theme.border)
                            detailBlock("Exchange rate", rate)
                        }
                        Divider().background(theme.border)
                        detailBlock("You paid exactly", CurrencyDisplay.formatUSDCents(r.usdCents))
                        Divider().background(theme.border)
                        detailBlock("Date", ReceiptScreen.timestampString(r.timestamp))
                    }
                }
                .padding(.horizontal, ZTokens.md)
            }
            Button("Done") { vm.closeFromResult() }
                .buttonStyle(PrimaryButtonStyle(theme: theme))
                .accessibilityIdentifier("zp.pending.done")
                .padding(.horizontal, ZTokens.md)
                .padding(.bottom, ZTokens.md)
        }
    }

    private func detailBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .zpFont(theme, 13)
                .foregroundColor(theme.text2)
            Text(value)
                .zpFont(theme, 16, .medium)
                .monospacedDigit()
                .foregroundColor(theme.text)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared small components

@available(iOS 13.0, macOS 13.0, *)
struct InlineError: View {
    let message: String
    var theme: ZTheme = .automatic
    var body: some View {
        HStack(spacing: ZTokens.sm) {
            Image(systemName: "exclamationmark.circle")
            Text(message).zpFont(theme, 14)
        }
        .foregroundColor(theme.failure)
        .padding(ZTokens.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.failureSoft)
        .cornerRadius(theme.radiusInput)
    }
}

@available(iOS 13.0, macOS 13.0, *)
struct PrimaryButtonStyle: ButtonStyle {
    var theme: ZTheme = .automatic
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .zpFont(theme, 16, .semibold)
            .foregroundColor(theme.primaryButtonTextColor)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(theme.primaryButtonBackground.opacity(configuration.isPressed ? 0.85 : 1))
            .cornerRadius(theme.primaryButtonRadius)
    }
}

/// Verbatim user-facing copy for the scanner / review inline banner
/// (transient, recoverable errors).
@available(iOS 13.0, macOS 13.0, *)
func humanMessage(_ error: ZennopayError) -> String {
    switch error {
    case .invalidQRCode:
        return "That code couldn't be read. Make sure it's a merchant payment QR and try again."
    case .quoteExpired:
        return "Rate refreshed, please review the new amount."
    case .sessionExpired, .jwtExpired:
        return "Your session expired. Please return to the app and try again."
    case .cameraPermissionDenied:
        return "Camera access is off. Allow camera in Settings, or paste the QR data instead."
    case .networkError:
        return "Couldn't get a rate. Try again in a moment."
    case .paymentFailed:
        return "The payment couldn't be completed."
    default:
        return "That code couldn't be read. Make sure it's a merchant payment QR and try again."
    }
}

/// Failure-reason copy for the terminal failure screen.
@available(iOS 13.0, macOS 13.0, *)
func failureReason(_ error: ZennopayError) -> String {
    switch error {
    case .paymentFailed:
        return "The payment couldn't be completed. Try again, or pay another way."
    case .networkError:
        return "Network issue. Check your connection and try again."
    case .quoteExpired:
        return "The rate changed. Review the new amount and try again."
    case .sessionExpired, .jwtExpired, .invalidJWT, .malformedToken, .intentMismatch:
        return "Something went wrong starting this payment. Please return to the app and try again."
    default:
        return "The payment couldn't be completed."
    }
}
#endif
