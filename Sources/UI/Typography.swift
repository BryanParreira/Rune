import SwiftUI

/// Rune's type accents (bundled SIL OFL fonts, registered via ATSApplicationFontsPath):
/// Caveat for handwritten margin notes, Instrument Serif for headings. Interface text stays
/// in the system font and code in the terminal font.
extension Font {
    /// Handwritten accent (Caveat).
    static func hand(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("Caveat", size: size).weight(weight)
    }

    /// Editorial heading (Instrument Serif).
    static func serif(_ size: CGFloat) -> Font {
        .custom("Instrument Serif", size: size)
    }
}

/// A short handwritten note, slightly tilted, like a comment in the margin.
struct MarginNote: View {
    let text: String
    var color: NSColor
    var size: CGFloat = 20
    var angle: Double = -2.5

    var body: some View {
        // Caveat leans right, so a last tall letter (the "l" of "optional") reaches past the
        // text's width and was cut off; a thin space gives it room.
        Text(text + "\u{2009}")
            .font(.hand(size))
            .foregroundColor(Color(nsColor: color))
            .rotationEffect(.degrees(angle))
            .fixedSize()
    }
}

extension View {
    /// A highlighter-pen stroke behind the lower part of the text.
    func highlighterMark(_ color: NSColor) -> some View {
        background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(height: 9)
                .padding(.horizontal, -3)
                .offset(y: -2)
        }
    }
}
