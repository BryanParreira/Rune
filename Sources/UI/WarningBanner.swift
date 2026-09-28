import SwiftUI

/// Non-blocking strip shown when config has problems.
final class WarningModel: ObservableObject {
    @Published var warnings: [String] = []
    @Published var dismissed = false
    @Published var palette: ChromePalette

    var onOpenConfig: () -> Void = {}

    init(palette: ChromePalette) {
        self.palette = palette
    }

    var isVisible: Bool { !warnings.isEmpty && !dismissed }
}

struct WarningBanner: View {
    @ObservedObject var model: WarningModel
    @State private var expanded = false

    private let amber = Color(red: 0.95, green: 0.75, blue: 0.35)

    var body: some View {
        if model.isVisible {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(amber)
                        .font(.system(size: 11))
                    Text(headline)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: model.palette.foreground))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if model.warnings.count > 1 {
                        Button(expanded ? "Less" : "+\(model.warnings.count - 1) more") { expanded.toggle() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    Spacer(minLength: 8)
                    Button("Open config", action: model.onOpenConfig)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Button {
                        model.dismissed = true
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(nsColor: model.palette.secondary))
                    .help("Dismiss")
                }
                if expanded {
                    ForEach(Array(model.warnings.dropFirst().enumerated()), id: \.offset) { _, warning in
                        Text("• \(warning)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: model.palette.secondary))
                    }
                    .padding(.leading, 19)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(amber.opacity(0.10))
        } else {
            // A definite zero height: an empty body has no intrinsic size, which left the
            // window layout ambiguous (the banner could take arbitrary space).
            Color.clear.frame(height: 0)
        }
    }

    private var headline: String {
        "Config: \(model.warnings.first ?? "")"
    }
}
