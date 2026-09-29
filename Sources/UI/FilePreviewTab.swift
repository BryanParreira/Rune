import AppKit
import RuneKit
import SwiftUI
import WebKit

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
    func find(_ request: NSMenuItem) { view.find(request) }
    func reveal(line: Int) { view.reveal(line: line) }
    /// A "Run…" button on a shell snippet was clicked: (command, the file's folder).
    var onRunSnippet: ((String, String) -> Void)? {
        get { view.onRunSnippet }
        set { view.onRunSnippet = newValue }
    }
    func apply(_ snapshot: ConfigSnapshot) { view.apply(snapshot) }
    func closeContent() { view.stopWatching() }
}

final class FilePreviewHeaderModel: ObservableObject {
    enum Mode: String { case preview = "Preview", source = "Source" }

    @Published var path = ""
    @Published var detail = ""
    @Published var note: String?
    @Published var palette = ChromePalette(theme: .runeDark)
    /// Rendered/source switch (Markdown only).
    @Published var mode: Mode? = nil
    /// Line wrapping for the text view (nil when not applicable).
    @Published var wraps: Bool? = nil

    var onModeChange: (Mode) -> Void = { _ in }
    var onToggleWrap: () -> Void = {}
}

final class FilePreviewView: NSView {
    private let headerModel = FilePreviewHeaderModel()
    private let header: NSHostingView<FilePreviewHeader>
    private let scrollView = NSScrollView()
    /// TextKit 1 from the start: the line-number gutter reads the layout manager, and letting
    /// AppKit switch a live TextKit 2 view over leaves it blank until the next relayout.
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let gutter: LineNumberGutter
    private var gutterWidth: NSLayoutConstraint?
    private let imageView = NSImageView()
    /// Created on first use (Markdown only); `webViewIfLoaded` never creates it.
    private var webViewIfLoaded: WKWebView?
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Rendered documents never run scripts.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Belt and braces: never load anything from the network in the viewer.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = linkHandler
        view.setValue(false, forKey: "drawsBackground")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
        self.webViewIfLoaded = view
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: header.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return view
    }()
    private let linkHandler = PreviewLinkHandler()
    /// Commands behind the rendered document's "Run…" buttons.
    private var snippets: [String] = []
    var onRunSnippet: ((String, String) -> Void)?
    private var currentText = ""
    private var wrapLines = false
    private let messageHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var snapshot: ConfigSnapshot
    private var palette: ChromePalette
    private var currentPath = ""
    private var language: CodeLanguage = .plain
    private var watcher: DirectoryWatcher?
    private var loadGeneration = 0
    /// Modification date and size of the file as last shown; the folder watcher fires for
    /// any change next to it (e.g. the shell writing its history), so reloads compare this.
    private var shownStamp: FileStamp?
    /// Highlighting for `currentText`, computed off the main thread.
    private var tokens: [CodeHighlighter.Token] = []

    /// Files larger than this (UTF-16 units) are shown without syntax colors.
    private static let highlightLimit = 400_000

    init(snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
        palette = ChromePalette(theme: snapshot.theme)
        header = NSHostingView(rootView: FilePreviewHeader(model: headerModel))
        gutter = LineNumberGutter(textView: textView)
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
        textView.textContainerInset = NSSize(width: 8, height: 16)
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
        // The window uses a full-size content view; automatic insets would offset the text
        // under a titlebar that isn't there.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        // Line numbers live in a plain view beside the scroll view, not an NSRulerView: recent
        // macOS versions back rulers with a window-sized layer that paints over everything.
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        gutter.onWidthChange = { [weak self] width in self?.gutterWidth?.constant = width }

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        addSubview(imageView)

        messageHost.safeAreaRegions = []
        messageHost.translatesAutoresizingMaskIntoConstraints = false
        messageHost.isHidden = true
        addSubview(messageHost)

        // The header always draws above the scrolling content.
        header.removeFromSuperview()
        addSubview(header, positioned: .above, relativeTo: nil)
        // Line numbers follow the text on every scroll step.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in self?.gutter.needsDisplay = true }
        let gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.thickness)
        self.gutterWidth = gutterWidth

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            gutter.topAnchor.constraint(equalTo: header.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
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
        headerModel.onModeChange = { [weak self] mode in
            self?.headerModel.mode = mode
            self?.showCurrentTextMode()
        }
        linkHandler.onRun = { [weak self] index in
            guard let self, self.snippets.indices.contains(index) else { return }
            self.onRunSnippet?(self.snippets[index], (self.currentPath as NSString).deletingLastPathComponent)
        }
        headerModel.onToggleWrap = { [weak self] in
            guard let self else { return }
            self.setWrapping(!self.wrapLines)
        }
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

    /// A line to scroll to and select once the file is shown (1-based).
    private var pendingLine: Int?

    func reveal(line: Int) {
        pendingLine = line
        if !currentText.isEmpty { revealPendingLine() }
    }

    private func revealPendingLine() {
        guard let line = pendingLine else { return }
        pendingLine = nil
        if headerModel.mode == .preview { headerModel.onModeChange(.source) }
        let text = textView.string as NSString
        var start = 0
        var current = 1
        while current < line, start < text.length {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            current += 1
        }
        let range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    /// Find bar actions for the code view (the rendered Markdown view has none).
    func find(_ request: NSMenuItem) {
        guard !scrollView.isHidden else { NSSound.beep(); return }
        window?.makeFirstResponder(textView)
        textView.performTextFinderAction(request)
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
        gutter.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, snapshot.font.pointSize - 2), weight: .regular)
        gutter.textColor = palette.foreground.withAlphaComponent(0.28)
        gutter.backgroundColor = palette.background
        restyleText()
        if headerModel.mode == .preview { renderMarkdown() }
    }

    // MARK: Loading

    func load(path: String) {
        let isNewFile = path != currentPath
        currentPath = path
        loadGeneration += 1
        let generation = loadGeneration
        headerModel.path = path
        if isNewFile { shownStamp = nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = FileStamp(path: path)
            var preview = FilePreview.load(path: path)
            var note: String?
            var tokens: [CodeHighlighter.Token] = []
            // Everything expensive (pretty-printing, highlighting) happens here, off the main thread.
            if case .text(let text, let language, let truncated) = preview {
                var shown = text
                if language == .json, let pretty = Self.prettyJSONIfMinified(text) {
                    shown = pretty
                    note = "Formatted"
                }
                if (shown as NSString).length <= Self.highlightLimit {
                    tokens = CodeHighlighter.tokens(in: shown, language: language)
                } else {
                    note = note ?? "Large file · no colors"
                }
                preview = .text(shown, language: language, truncated: truncated)
            }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                // A change elsewhere in the folder: nothing to redraw.
                if !isNewFile, let stamp, stamp == self.shownStamp { return }
                self.shownStamp = stamp
                self.tokens = tokens
                self.show(preview, size: stamp?.size, note: note)
            }
        }
        watch(path)
    }

    private func show(_ preview: FilePreview, size: Int64?, note: String? = nil) {
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        headerModel.note = note
        switch preview {
        case .text(let text, let language, let truncated):
            let languageChanged = language != self.language || headerModel.mode == nil && language == .markdown
            self.language = language
            let lines = text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
            headerModel.detail = [language.displayName, "\(lines) line\(lines == 1 ? "" : "s")", sizeText].compactMap { $0 }.joined(separator: " · ")
            if truncated { headerModel.note = "Showing the first 2 MB" }
            if languageChanged {
                // Prose wraps by default; code keeps its lines.
                setWrapping(language == .markdown || language == .plain, restyle: false)
                headerModel.mode = language == .markdown ? .preview : nil
            }
            let visible = scrollView.contentView.bounds.origin
            let reloadingSameFile = !textView.string.isEmpty && textView.window != nil
            currentText = text
            textView.string = text
            restyleText()
            gutter.invalidateLineIndex()
            if reloadingSameFile { scrollView.contentView.scroll(to: visible) }
            showCurrentTextMode()
            revealPendingLine()
        case .image:
            headerModel.mode = nil
            headerModel.wraps = nil
            headerModel.detail = ["Image", sizeText].compactMap { $0 }.joined(separator: " · ")
            imageView.image = NSImage(contentsOfFile: currentPath)
            showOnly(imageView)
        case .binary:
            headerModel.mode = nil
            headerModel.wraps = nil
            headerModel.detail = ["Binary file", sizeText].compactMap { $0 }.joined(separator: " · ")
            showMessage(symbol: "doc.zipper", text: "This file isn't text, so Rune can't preview it.", action: "Open with Default App")
        case .unreadable(let reason):
            headerModel.detail = "Can't open"
            showMessage(symbol: "lock", text: reason, action: nil)
        }
    }

    private func showOnly(_ view: NSView) {
        scrollView.isHidden = view !== scrollView
        gutter.isHidden = view !== scrollView
        imageView.isHidden = view !== imageView
        messageHost.isHidden = view !== messageHost
        webViewIfLoaded?.isHidden = view !== webViewIfLoaded
    }

    private func showCurrentTextMode() {
        if headerModel.mode == .preview {
            renderMarkdown()
            showOnly(webView)
        } else {
            showOnly(scrollView)
        }
    }

    private func setWrapping(_ wraps: Bool, restyle: Bool = true) {
        wrapLines = wraps
        headerModel.wraps = wraps
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? max(100, scrollView.contentSize.width) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if wraps { textView.frame.size.width = scrollView.contentSize.width }
        scrollView.hasHorizontalScroller = !wraps
        if restyle { gutter.needsDisplay = true }
    }

    /// Pretty-prints JSON whose lines are too long to read (minified files).
    static func prettyJSONIfMinified(_ text: String) -> String? {
        guard text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.count > 400 }),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    private func renderMarkdown() {
        let rendered = MarkdownRenderer.renderRunnable(currentText)
        snippets = rendered.snippets
        let body = Self.inlineLocalImages(rendered.html, relativeTo: (currentPath as NSString).deletingLastPathComponent)
        let page = MarkdownPage.document(body: body, palette: palette, font: snapshot.font)
        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["RUNE_DEBUG_HTML"] { try? page.write(toFile: out, atomically: true, encoding: .utf8) }
        #endif
        webView.loadHTMLString(page, baseURL: nil)
    }

    /// Relative <img src> paths become data URIs so images in a README show up. Remote images
    /// become small labeled chips instead: previewing a file never touches the network.
    static func inlineLocalImages(_ html: String, relativeTo folder: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"src="([^"]+)""#),
              let remote = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="https?://[^"]*"[^>]*>"#, options: [.caseInsensitive]),
              let alt = try? NSRegularExpression(pattern: #"\balt="([^"]*)""#)
        else { return html }
        var html = html
        for match in remote.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).reversed() {
            let tag = (html as NSString).substring(with: match.range)
            let label = alt.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
                .map { (tag as NSString).substring(with: $0.range(at: 1)) } ?? "image"
            html = (html as NSString).replacingCharacters(in: match.range, with: "<span class=\"remote-image\" title=\"Remote image not loaded\">\(label)</span>")
        }
        var result = html
        for match in regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed() {
            let src = (result as NSString).substring(with: match.range(at: 1))
            guard !src.hasPrefix("http"), !src.hasPrefix("data:") else { continue }
            let path = src.hasPrefix("/") ? src : (folder as NSString).appendingPathComponent(src)
            guard let data = FileManager.default.contents(atPath: path), data.count < 8_000_000 else { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            let mime = ext == "svg" ? "image/svg+xml" : ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "gif" ? "image/gif" : "image/png"
            let replacement = "src=\"data:\(mime);base64,\(data.base64EncodedString())\""
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
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

    /// Applies fonts and colors (and the precomputed highlighting) to the shown text.
    private func restyleText() {
        guard let storage = textView.textStorage else { return }
        let font = snapshot.font
        let full = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(snapshot.config.lineHeight)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: palette.text, .paragraphStyle: paragraph], range: full)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for token in tokens where NSMaxRange(token.range) <= full.length {
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
        gutter.needsDisplay = true
    }

    // MARK: Live reload

    /// Watches the file (in-place writes, appends) and its folder (editors that save by
    /// replacing the file). Re-armed on every load so a replaced file is followed.
    private func watch(_ path: String) {
        let file = URL(fileURLWithPath: path)
        let folder = file.deletingLastPathComponent()
        if watcher == nil {
            watcher = DirectoryWatcher(debounce: 0.4) { [weak self] in
                guard let self else { return }
                self.load(path: self.currentPath)
            }
        }
        watcher?.watch([folder, file])
    }

    #if DEBUG
    func debugScroll(by points: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + points))
        scrollView.reflectScrolledClipView(clip)
        let used = textView.layoutManager.flatMap { lm in textView.textContainer.map { lm.usedRect(for: $0) } } ?? .zero
        // Capture the scroll view itself (window-level offscreen capture ignores clip offsets).
        if let out = ProcessInfo.processInfo.environment["RUNE_DEBUG_SCROLLSHOT"],
           let rep = textView.bitmapImageRepForCachingDisplay(in: textView.visibleRect) {
            textView.cacheDisplay(in: textView.visibleRect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        print("SCROLL textFrame=\(textView.frame) visible=\(textView.visibleRect) used=\(used) clip=\(clip.bounds) container=\(textView.textContainer?.containerSize ?? .zero)")
        fflush(stdout)
    }

    func debugWebSnapshot(to path: String) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("WEBSHOT failed \(String(describing: error))"); fflush(stdout); return
            }
            try? png.write(to: URL(fileURLWithPath: path))
            print("WEBSHOT ok \(Int(image.size.width))x\(Int(image.size.height)) mode=\(self.headerModel.mode?.rawValue ?? "-") webHidden=\(self.webView.isHidden)")
            fflush(stdout)
        }
    }

    func debugRunSnippet(_ index: Int) { linkHandler.onRun?(index) }

    var debugSummary: String {
        "selection=\(textView.selectedRange()) language=\(language.displayName) chars=\((textView.string as NSString).length) detail=\(headerModel.detail) textVisible=\(!scrollView.isHidden) colored=\(CodeHighlighter.tokens(in: textView.string, language: language).count)"
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
        let entry = FileListing.Entry(name: url.lastPathComponent, path: model.path, isDirectory: false, isHidden: false)
        HStack(spacing: 12) {
            Image(systemName: FileIcon.symbol(for: entry, expanded: false))
                .font(.system(size: 15))
                .foregroundColor(Color(nsColor: FileIcon.color(for: entry, palette: p)))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: p.surface1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(nsColor: p.text))
                    .lineLimit(1)
                Text(breadcrumb(url))
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: p.hint))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 16)
            if let note = model.note {
                MetaChip(text: note, palette: p, color: p.ansiYellow)
            }
            ForEach(model.detail.components(separatedBy: " · ").filter { !$0.isEmpty }, id: \.self) { item in
                MetaChip(text: item, palette: p, color: nil)
            }
            if let mode = model.mode {
                ModeSwitch(mode: mode, palette: p, onChange: model.onModeChange)
            }
            if let wraps = model.wraps, model.mode != .preview {
                IconAction(symbol: wraps ? "text.alignleft" : "arrow.left.and.right", help: wraps ? "Don't wrap lines" : "Wrap long lines",
                           palette: p, isOn: wraps, action: model.onToggleWrap)
            }
            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1, height: 18).padding(.horizontal, 2)
            IconAction(symbol: "arrow.up.forward.app", help: openTitle(url), palette: p) { NSWorkspace.shared.open(url) }
            IconAction(symbol: "folder", help: "Reveal in Finder", palette: p) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            IconAction(symbol: "doc.on.doc", help: "Copy path", palette: p) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.path, forType: .string)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: p.background))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }

    /// "Rune › Sources › UI" style path to the file's folder.
    private func breadcrumb(_ url: URL) -> String {
        let folder = TabTitle.abbreviate(path: url.deletingLastPathComponent().path, home: NSHomeDirectory())
        let parts = folder.split(separator: "/").map(String.init)
        let shown = parts.count > 4 ? ["…"] + parts.suffix(4) : parts
        return (folder.hasPrefix("/") && parts.count <= 4 ? "/ " : "") + shown.joined(separator: "  ›  ")
    }

    private func openTitle(_ url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Open" }
        return "Open in " + app.deletingPathExtension().lastPathComponent
    }
}

private struct MetaChip: View {
    let text: String
    let palette: ChromePalette
    let color: NSColor?

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color(nsColor: color ?? palette.secondary))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: (color ?? palette.foreground).withAlphaComponent(0.07))))
    }
}

private struct ModeSwitch: View {
    let mode: FilePreviewHeaderModel.Mode
    let palette: ChromePalette
    let onChange: (FilePreviewHeaderModel.Mode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([FilePreviewHeaderModel.Mode.preview, .source], id: \.rawValue) { option in
                Button { onChange(option) } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(nsColor: option == mode ? palette.text : palette.secondary))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: option == mode ? palette.surface3 : .clear)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: palette.surface1)))
    }
}

private struct IconAction: View {
    let symbol: String
    let help: String
    let palette: ChromePalette
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: hovering || isOn ? palette.text : palette.secondary))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: hovering ? palette.surface2 : (isOn ? palette.surface1 : .clear))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Line numbers for a (read-only) text view, drawn beside its scroll view. Only the visible
/// lines are drawn, so scrolling a large file stays cheap.
final class LineNumberGutter: NSView {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { updateThickness(); needsDisplay = true }
    }
    var textColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    /// Called when the width needed for the largest line number changes.
    var onWidthChange: ((CGFloat) -> Void)?
    private(set) var thickness: CGFloat = 44

    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        // Since macOS 14 views don't clip by default and `draw(_:)` may be handed a dirty rect
        // far outside the view; unclipped, this gutter's background painted over the window.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

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
        updateThickness()
        needsDisplay = true
    }

    /// Width of the widest line number actually needed (min 2 digits) plus even padding.
    private func updateThickness() {
        let digits = max(2, String(lineStarts.count).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 24
        guard width != thickness else { return }
        thickness = width
        onWidthChange?(width)
    }

    private func lineNumber(forCharacter index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = dirtyRect.intersection(bounds)
        guard !area.isEmpty else { return }
        backgroundColor.setFill()
        area.fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let origin = textView.textContainerOrigin
        var lastLine = -1

        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragmentRect, usedRect, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.lineNumber(forCharacter: charIndex)
            guard line != lastLine else { return } // wrapped continuation
            lastLine = line
            // Convert from the text view's coordinates so numbers track the text exactly.
            let lineTop = self.convert(NSPoint(x: 0, y: fragmentRect.minY + origin.y), from: textView).y
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = lineTop + (usedRect.height - size.height) / 2
            guard y + size.height >= area.minY - 2, y <= area.maxY + 2 else { return }
            label.draw(at: NSPoint(x: self.bounds.maxX - size.width - 12, y: y), withAttributes: attributes)
        }
    }
}

/// Opens links from rendered documents outside the viewer.
final class PreviewLinkHandler: NSObject, WKNavigationDelegate {
    /// A snippet's "Run…" link (`rune-run:<index>`).
    var onRun: ((Int) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme == "rune-run" {
            let index = Int(url.absoluteString.dropFirst("rune-run:".count)) ?? -1
            DispatchQueue.main.async { self.onRun?(index) }
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.fragment != nil, url.scheme == nil || url.absoluteString.hasPrefix("about:") {
                decisionHandler(.allow) // in-page anchor
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// HTML shell and stylesheet for rendered Markdown, matched to Rune's theme.
enum MarkdownPage {
    static func css(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
    }

    static func document(body: String, palette p: ChromePalette, font: NSFont) -> String {
        let mono = font.familyName ?? "SF Mono"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <style>
        :root { color-scheme: \(p.isLight ? "light" : "dark"); }
        html { background: \(css(p.background)); }
        body { margin: 0; padding: 36px 48px 64px; color: \(css(p.text));
               font: 14.5px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
        main { max-width: 780px; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 { color: \(css(p.foreground)); line-height: 1.25; margin: 1.6em 0 0.6em; font-weight: 650; letter-spacing: -0.01em; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid \(css(p.outline)); }
        h2 { font-size: 1.5em; padding-bottom: .25em; border-bottom: 1px solid \(css(p.outline)); }
        h3 { font-size: 1.2em; } h4 { font-size: 1em; }
        main > :first-child { margin-top: 0; }
        p, ul, ol, table, pre, blockquote { margin: 0 0 1em; }
        a { color: \(css(p.accent)); text-decoration: none; } a:hover { text-decoration: underline; }
        strong { color: \(css(p.foreground)); font-weight: 650; }
        code { font-family: "\(mono)", ui-monospace, Menlo, monospace; font-size: 0.88em; background: \(css(p.surface2));
               padding: .15em .4em; border-radius: 5px; }
        pre { background: \(css(p.surface1)); border: 1px solid \(css(p.outline)); border-radius: 8px; padding: 14px 16px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 12.5px; line-height: 1.55; color: \(css(p.text)); }
        blockquote { margin-left: 0; padding: .2em 1em; color: \(css(p.secondary)); border-left: 3px solid \(css(p.accent.withAlphaComponent(0.6))); }
        ul, ol { padding-left: 1.6em; } li { margin: .25em 0; } li > input { margin-right: .4em; }
        hr { border: 0; height: 1px; background: \(css(p.outline)); margin: 2em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(css(p.outline)); padding: 7px 13px; }
        th { background: \(css(p.surface1)); font-weight: 600; }
        tr:nth-child(even) td { background: \(css(p.surface1.withAlphaComponent(0.5))); }
        img { max-width: 100%; border-radius: 6px; }
        del { color: \(css(p.hint)); }
        sub, sup { color: \(css(p.secondary)); }
        .snippet { position: relative; }
        .snippet .run { position: absolute; top: 8px; right: 8px; font: 600 11.5px -apple-system, sans-serif; color: \(css(p.text));
                        background: \(css(p.accent.withAlphaComponent(0.22))); border: 1px solid \(css(p.accent.withAlphaComponent(0.45)));
                        padding: 3px 10px; border-radius: 6px; text-decoration: none; }
        .snippet .run:hover { background: \(css(p.accent.withAlphaComponent(0.35))); text-decoration: none; }
        .snippet pre { padding-right: 96px; }
        .remote-image { display: inline-block; font-size: 11px; line-height: 18px; padding: 0 7px; margin: 2px 2px;
                        border-radius: 4px; background: \(css(p.surface2)); color: \(css(p.secondary)); }
        </style></head><body><main>
        \(body)
        </main></body></html>
        """
    }
}

/// Identifies one version of a file on disk.
private struct FileStamp: Equatable {
    let modified: Date?
    let size: Int64?

    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.int64Value
    }
}
