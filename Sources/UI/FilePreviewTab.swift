import AppKit
import RuneKit
import SwiftUI

/// A read-only file viewer in a tab: code with line numbers and syntax colors, images, or a
/// friendly message for binaries. Reloads when the file changes on disk.
final class FilePreviewTab: TabContent {
    let id = UUID()
    private(set) var path: String
    /// Preview tabs are replaced by the next file you click; pinned ones stay (double-click).
    var isPinned: Bool
    let runningProgram: String? = nil
    private let view: FilePreviewView

    var title: String { (path as NSString).lastPathComponent }
    var contentView: NSView { view }

    init(path: String, pinned: Bool, snapshot: ConfigSnapshot) {
        self.path = path
        self.isPinned = pinned
        view = FilePreviewView(snapshot: snapshot)
        view.load(path: path)
    }

    func show(path: String) {
        guard path != self.path else { return }
        self.path = path
        view.load(path: path)
    }

    func focus() { view.focus() }
    func apply(_ snapshot: ConfigSnapshot) { view.apply(snapshot) }
    func closeContent() { view.stopWatching() }
}

final class FilePreviewHeaderModel: ObservableObject {
    @Published var path = ""
    @Published var detail = ""
    @Published var note: String?
    @Published var palette = ChromePalette(theme: .runeDark)
}

final class FilePreviewView: NSView {
    private let headerModel = FilePreviewHeaderModel()
    private let header: NSHostingView<FilePreviewHeader>
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let ruler: LineNumberRuler
    private let imageView = NSImageView()
    private let messageHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var snapshot: ConfigSnapshot
    private var palette: ChromePalette
    private var currentPath = ""
    private var language: CodeLanguage = .plain
    private var watcher: DirectoryWatcher?
    private var loadGeneration = 0

    init(snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
        palette = ChromePalette(theme: snapshot.theme)
        header = NSHostingView(rootView: FilePreviewHeader(model: headerModel))
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: .zero)
        wantsLayer = true

        header.safeAreaRegions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        addSubview(imageView)

        messageHost.safeAreaRegions = []
        messageHost.translatesAutoresizingMaskIntoConstraints = false
        messageHost.isHidden = true
        addSubview(messageHost)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            messageHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            messageHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(snapshot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func focus() {
        if !scrollView.isHidden { window?.makeFirstResponder(textView) }
    }

    func apply(_ snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
        palette = ChromePalette(theme: snapshot.theme)
        headerModel.palette = palette
        layer?.backgroundColor = palette.background.cgColor
        scrollView.backgroundColor = palette.background
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.accent
        textView.selectedTextAttributes = [.backgroundColor: palette.accent.withAlphaComponent(0.3)]
        ruler.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, snapshot.font.pointSize - 2), weight: .regular)
        ruler.textColor = palette.hint
        ruler.backgroundColor = palette.background
        ruler.separatorColor = palette.outline
        restyleText()
    }

    // MARK: Loading

    func load(path: String) {
        currentPath = path
        loadGeneration += 1
        let generation = loadGeneration
        headerModel.path = path
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = FilePreview.load(path: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.show(preview, size: size)
            }
        }
        watch(path)
    }

    private func show(_ preview: FilePreview, size: Int64?) {
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        headerModel.note = nil
        switch preview {
        case .text(let text, let language, let truncated):
            self.language = language
            let lines = text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
            headerModel.detail = [language.displayName, "\(lines) line\(lines == 1 ? "" : "s")", sizeText].compactMap { $0 }.joined(separator: " · ")
            if truncated { headerModel.note = "Showing the first 2 MB" }
            let wraps = language == .markdown || language == .plain
            textView.isHorizontallyResizable = !wraps
            textView.textContainer?.widthTracksTextView = wraps
            textView.textContainer?.containerSize = NSSize(width: wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
            let visible = scrollView.contentView.bounds.origin
            let reloadingSameFile = textView.string.isEmpty == false && textView.window != nil
            textView.string = text
            restyleText()
            ruler.invalidateLineIndex()
            if reloadingSameFile { scrollView.contentView.scroll(to: visible) }
            showOnly(scrollView)
        case .image:
            headerModel.detail = ["Image", sizeText].compactMap { $0 }.joined(separator: " · ")
            imageView.image = NSImage(contentsOfFile: currentPath)
            showOnly(imageView)
        case .binary:
            headerModel.detail = ["Binary file", sizeText].compactMap { $0 }.joined(separator: " · ")
            showMessage(symbol: "doc.zipper", text: "This file isn't text, so Rune can't preview it.", action: "Open with Default App")
        case .unreadable(let reason):
            headerModel.detail = "Can't open"
            showMessage(symbol: "lock", text: reason, action: nil)
        }
    }

    private func showOnly(_ view: NSView) {
        scrollView.isHidden = view !== scrollView
        imageView.isHidden = view !== imageView
        messageHost.isHidden = view !== messageHost
    }

    private func showMessage(symbol: String, text: String, action: String?) {
        let palette = palette
        let path = currentPath
        messageHost.rootView = AnyView(
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 30)).foregroundColor(Color(nsColor: palette.hint))
                Text(text).font(.system(size: 13)).foregroundColor(Color(nsColor: palette.secondary)).multilineTextAlignment(.center)
                if let action {
                    Button(action) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(.plain)
                        .foregroundColor(Color(nsColor: palette.accent))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: palette.background))
        )
        showOnly(messageHost)
    }

    private func restyleText() {
        guard let storage = textView.textStorage else { return }
        let font = snapshot.font
        let full = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(snapshot.config.lineHeight)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: palette.text, .paragraphStyle: paragraph], range: full)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for token in CodeHighlighter.tokens(in: storage.string, language: language) where NSMaxRange(token.range) <= full.length {
            switch token.kind {
            case .comment: storage.addAttribute(.foregroundColor, value: palette.hint, range: token.range)
            case .string: storage.addAttribute(.foregroundColor, value: palette.success, range: token.range)
            case .number: storage.addAttribute(.foregroundColor, value: palette.ansiYellow, range: token.range)
            case .keyword: storage.addAttribute(.foregroundColor, value: palette.ansiMagenta, range: token.range)
            case .type: storage.addAttribute(.foregroundColor, value: palette.ansiCyan, range: token.range)
            case .tag, .attribute: storage.addAttribute(.foregroundColor, value: palette.ansiBlue, range: token.range)
            case .heading:
                storage.addAttribute(.foregroundColor, value: palette.text, range: token.range)
                storage.addAttribute(.font, value: bold, range: token.range)
            }
        }
        storage.endEditing()
        ruler.needsDisplay = true
    }

    // MARK: Live reload

    private func watch(_ path: String) {
        let folder = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        if watcher == nil {
            watcher = DirectoryWatcher(debounce: 0.4) { [weak self] in
                guard let self else { return }
                self.load(path: self.currentPath)
            }
        }
        watcher?.watch([folder])
    }

    #if DEBUG
    var debugSummary: String {
        "language=\(language.displayName) chars=\((textView.string as NSString).length) detail=\(headerModel.detail) textVisible=\(!scrollView.isHidden) colored=\(CodeHighlighter.tokens(in: textView.string, language: language).count)"
    }
    #endif

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}

struct FilePreviewHeader: View {
    @ObservedObject var model: FilePreviewHeaderModel

    var body: some View {
        let p = model.palette
        let url = URL(fileURLWithPath: model.path)
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(for: FileListing.Entry(name: url.lastPathComponent, path: model.path, isDirectory: false, isHidden: false), expanded: false))
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: FileIcon.color(for: FileListing.Entry(name: url.lastPathComponent, path: model.path, isDirectory: false, isHidden: false), palette: p)))
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: p.text))
                Text(TabTitle.abbreviate(path: url.deletingLastPathComponent().path, home: NSHomeDirectory()))
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: p.hint))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            if let note = model.note {
                Text(note).font(.system(size: 11)).foregroundColor(Color(nsColor: p.ansiYellow))
            }
            Text(model.detail)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: p.hint))
            HeaderAction(title: openTitle(url), palette: p) { NSWorkspace.shared.open(url) }
            HeaderAction(title: "Reveal", palette: p) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            HeaderAction(title: "Copy Path", palette: p) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.path, forType: .string)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: p.background))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }

    private func openTitle(_ url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Open" }
        return "Open in " + app.deletingPathExtension().lastPathComponent
    }
}

private struct HeaderAction: View {
    let title: String
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(nsColor: hovering ? palette.text : palette.secondary))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: hovering ? palette.surface2 : palette.surface1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Line numbers for a (read-only) text view.
final class LineNumberRuler: NSRulerView {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    var textColor = NSColor.secondaryLabelColor
    var backgroundColor = NSColor.textBackgroundColor
    var separatorColor = NSColor.separatorColor
    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func invalidateLineIndex() {
        guard let text = textView?.string as NSString? else { return }
        var starts = [0]
        var index = 0
        while index < text.length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < text.length || text.hasSuffix("\n") { starts.append(index) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * (font.maximumAdvancement.width + 0.5) + 22
        needsDisplay = true
    }

    private func lineNumber(forCharacter index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let inset = textView.textContainerInset.height
        var lastLine = -1

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragmentRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.lineNumber(forCharacter: charIndex)
            guard line != lastLine else { return } // wrapped continuation
            lastLine = line
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragmentRect.minY + inset - visible.minY + (fragmentRect.height - size.height) / 2
            label.draw(at: NSPoint(x: self.bounds.maxX - size.width - 12, y: y), withAttributes: attributes)
        }
    }

    override var isFlipped: Bool { true }
}
