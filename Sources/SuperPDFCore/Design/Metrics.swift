import AppKit

// The measured sizes of every window, panel and control (ux §2.1, §4, §5.1, §6). Points throughout.

public enum SPMetrics {
    /// Document windows (ux §2.1).
    public enum Window {
        public static let defaultSize = NSSize(width: 1100, height: 760)
        public static let minimumSize = NSSize(width: 640, height: 440)
        /// Unified title/toolbar.
        public static let toolbarHeight: CGFloat = 52
        public static let trafficLights = NSPoint(x: 20, y: 18)
    }

    /// Toolbar items (ux §2.1).
    public enum Toolbar {
        /// The Tools button: bordered-prominent capsule, `square.grid.2x2` at 13 pt on the left.
        public static let toolsButtonHeight: CGFloat = 28
        public static let toolsButtonPadding: CGFloat = 16
        public static let toolsSymbolSize: CGFloat = 13
        public static let toolsSymbol = "square.grid.2x2"
        public static let searchFieldWidth: CGFloat = 180
    }

    /// The thumbnail sidebar (ux §2.1).
    public enum Sidebar {
        public static let defaultWidth: CGFloat = 197
        public static let minimumWidth: CGFloat = 140
        public static let maximumWidth: CGFloat = 360
        /// Thumbnail width is the sidebar width minus this.
        public static let thumbnailInset: CGFloat = 32
        public static let thumbnailRadius: CGFloat = 8
        public static let thumbnailBorder: CGFloat = 1
        public static let thumbnailShadow: CGFloat = 4
        /// Vertical gap between thumbnails; the page number under each is an 11 pt label (`SPFont.secondary`).
        public static let thumbnailGap: CGFloat = 12
        /// Selected: 2 pt accent ring with a 15 % accent fill behind.
        public static let selectionRing: CGFloat = 2
        public static let selectionFillOpacity: CGFloat = 0.15
        public static let minimumThumbnailWidth: CGFloat = 100
        /// "12 pages  [+]".
        public static let bottomBarHeight: CGFloat = 29
        /// Table of Contents rows (Preview's).
        public static let outlineRowHeight: CGFloat = 24
        /// Bookmarks cells (Preview's).
        public static let bookmarkRowHeight: CGFloat = 45
        /// Search result thumbnails (Preview's).
        public static let searchThumbnail = NSSize(width: 38, height: 50)
    }

    /// The document well (Preview's PDFContentView defaults, ux §2.1: 4 pt at the sides, 4.75 pt above and below, which
    /// is also PDFView's own default).
    public enum Document {
        public static let pageBreakMargins = NSEdgeInsets(top: 4.75, left: 4, bottom: 4.75, right: 4)
        public static let scaleRange: ClosedRange<CGFloat> = 0.1...20
    }

    /// The inline tool panel (ux §2.1, §5.1).
    public enum ToolPanel {
        public static let width: CGFloat = 320
        /// Below this window width the panel overlays the document as a card instead of pushing it.
        public static let overlayBelowWindowWidth: CGFloat = 1000
        public static let minimumDocumentWidth: CGFloat = 360
        public static let headerHeight: CGFloat = 52
        public static let contentInset: CGFloat = 20
        public static let footerHeight: CGFloat = 76
        /// At most three visible controls and seven popup items (ux §5.1).
        public static let maximumVisibleControls = 3
        public static let maximumPopupItems = 7
        public static let textFieldHeight: CGFloat = 28
    }

    /// The panel's primary button (ux §2.1).
    public enum PrimaryButton {
        public static let height: CGFloat = 36
        public static let radius: CGFloat = 10
        public static let disabledOpacity: CGFloat = 0.4
    }

    /// Preview's markup bar under the toolbar.
    public enum MarkupBar {
        public static let height: CGFloat = 31
    }

    /// The result banner (ux §2.1, §7.3).
    public enum Banner {
        public static let height: CGFloat = 44
        public static let separator: CGFloat = 1
        /// Hides after this long unless the pointer is inside.
        public static let autoHideDelay: TimeInterval = 8
    }

    /// The page organiser (ux §2.1, §6.2).
    public enum Organiser {
        public static let defaultThumbnailWidth: CGFloat = 160
        public static let thumbnailWidthRange: ClosedRange<CGFloat> = 80...320
        public static let gap: CGFloat = 24
        public static let radius: CGFloat = 12
        public static let insertionLine: CGFloat = 3
        /// Pages from another file keep a bar in that file's colour until saved.
        public static let fileColorBar: CGFloat = 3
    }

    /// The Tools sheet (ux §2.1, §4).
    public enum ToolsSheet {
        public static let size = NSSize(width: 880, height: 620)
        /// Clamped to the window minus this each way.
        public static let windowInset: CGFloat = 80
        public static let minimumSize = NSSize(width: 640, height: 480)
        public static let cornerRadius: CGFloat = 16
        public static let searchFieldHeight: CGFloat = 32
        public static let columns = 5
        public static let gap: CGFloat = 16
        public static let margin: CGFloat = 24
        public static let sectionHeaderHeight: CGFloat = 32
        /// "Recently used" shows at most this many tiles.
        public static let recentTiles = 5
    }

    /// A tile (ux §2.1).
    public enum Tile {
        public static let size = NSSize(width: 150, height: 116)
        public static let radius: CGFloat = 12
        public static let border: CGFloat = 1
        /// The icon circle in the category colour at 15 % with the symbol in the category colour.
        public static let iconCircle: CGFloat = 40
        public static let iconCircleOpacity: CGFloat = 0.15
        public static let symbolSize: CGFloat = 20
        public static let hintLines = 2
        public static let hoverLift: CGFloat = 1
    }

    /// The welcome window (ux §2.1, §6.1).
    public enum Welcome {
        public static let size = NSSize(width: 760, height: 520)
        public static let targetSize = NSSize(width: 160, height: 140)
        public static let targetRadius: CGFloat = 14
        public static let targetIcon: CGFloat = 36
        public static let recentRowHeight: CGFloat = 36
        public static let recentThumbnail: CGFloat = 24
    }

    /// Drop targets (ux §2.5, §3): a 2 pt accent ring and an 8 % accent tint.
    public enum DropTarget {
        public static let ring: CGFloat = 2
        public static let tintOpacity: CGFloat = 0.08
    }

    /// Redaction marks before applying (ux §2.3).
    public enum Redaction {
        public static let outline: CGFloat = 1.5
    }
}
