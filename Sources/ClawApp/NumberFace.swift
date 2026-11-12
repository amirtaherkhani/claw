import CoreText
import Foundation
import SwiftUI

/// Claw's face for numbers: Big Shoulders, bundled under the SIL Open Font License (ADR-0007).
/// One scale for every count in the app, with tabular figures so changing numbers keep their width.
enum NumberFace {
    enum Step: CaseIterable {
        /// Overview hero count.
        case xl
        /// Overview card counts.
        case l
        /// Section counts.
        case m
        /// Scan progress and list counts.
        case s

        var points: CGFloat {
            switch self {
            case .xl: 96
            case .l: 56
            case .m: 20
            case .s: 13
            }
        }

        /// Weight runs against size: the hero is thin because it is huge, small counts are heavier to stay legible.
        var weight: Double {
            switch self {
            case .xl: 200
            case .l: 800
            case .m: 400
            case .s: 600
            }
        }
    }

    /// What the number says about the content. A quiet number (zero, nothing yet) steps back.
    enum Tone {
        case standard
        case quiet
    }

    /// The weight for a step and tone: quiet numbers are light (300), never heavier than the step itself.
    static func weight(_ step: Step, _ tone: Tone) -> Double {
        tone == .quiet ? min(step.weight, 300) : step.weight
    }

    /// The font for one step: Big Shoulders when the bundled file loads, else the system font with monospaced digits.
    static func font(_ step: Step, tone: Tone = .standard) -> Font {
        let weight = weight(step, tone)
        guard let descriptor = baseDescriptor else {
            return .system(size: step.points, weight: fallbackWeight(weight)).monospacedDigit()
        }
        return Font(ctFont(step, weight: weight, descriptor: descriptor))
    }

    /// The nearest system weight, for the fallback face.
    static func fallbackWeight(_ weight: Double) -> Font.Weight {
        switch weight {
        case ..<250: .ultraLight
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    /// Whether the bundled face loaded; the fallback is used otherwise.
    static var isBundledFaceAvailable: Bool { baseDescriptor != nil }

    static func ctFont(_ step: Step, weight: Double, descriptor: CTFontDescriptor) -> CTFont {
        // Optical size follows the point size, so hero numbers stay tight and small counts open up.
        let variation: [NSNumber: NSNumber] = [
            axis("wght"): NSNumber(value: weight),
            axis("opsz"): NSNumber(value: Double(step.points)),
        ]
        let tabular: [[String: Any]] = [
            [kCTFontOpenTypeFeatureTag as String: "tnum", kCTFontOpenTypeFeatureValue as String: 1]
        ]
        let attributes: [CFString: Any] = [
            kCTFontVariationAttribute: variation,
            kCTFontFeatureSettingsAttribute: tabular,
        ]
        let styled = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(styled, step.points, nil)
    }

    /// Loaded once from the app's resources; no system-wide registration.
    nonisolated(unsafe) private static let baseDescriptor: CTFontDescriptor? = {
        guard let url = resourceURL(name: "BigShoulders-Variable", extension: "ttf"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()

    /// The Xcode app target copies resources into the main bundle; `swift run` keeps them in the package's bundle.
    private static func resourceURL(name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        #if SWIFT_PACKAGE
            return Bundle.module.url(forResource: name, withExtension: ext)
        #else
            return nil
        #endif
    }

    /// A variation axis identifier, such as `wght`, as CoreText expects it: the four characters packed into a number.
    private static func axis(_ tag: String) -> NSNumber {
        NSNumber(value: tag.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
}

extension View {
    /// Sets a number in Claw's number face at one step of the scale.
    func numberFace(_ step: NumberFace.Step, tone: NumberFace.Tone = .standard) -> some View {
        font(NumberFace.font(step, tone: tone))
    }

    /// Quiet when the count is zero: "nothing here" should not shout.
    func numberFace(_ step: NumberFace.Step, value: Int) -> some View {
        numberFace(step, tone: value == 0 ? .quiet : .standard)
    }
}
