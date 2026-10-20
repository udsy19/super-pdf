import Foundation
import SuperPDFCore

// ViewerKit's own copy (ux §1.1 tone; shared copy lives in `Strings`). Words come from ux §2.1, §3, §6 and the mockups
// (docs/mockups/main-window.html, organizer.html, welcome.html).
public enum ViewerStrings {
    /// "12 pages" under the thumbnails and in the organiser's status line.
    public static func pages(_ count: Int) -> String { Formatting.count(count, "page", "pages") }

    // MARK: Thumbnail context menu (ux §6.3, main-window.png)

    public enum PageMenu {
        public static let rotateLeft = "Rotate Left"
        public static let rotateRight = "Rotate Right"
        public static func delete(_ count: Int) -> String { count > 1 ? "Delete Pages" : "Delete Page" }
        public static func extract(_ count: Int) -> String { count > 1 ? "Extract Pages…" : "Extract Page…" }
        public static let insert = "Insert Page"
        public static let duplicate = "Duplicate"
        public static func blackOut(_ count: Int) -> String { count > 1 ? "Black out these pages…" : "Black out this page…" }
        public static let makeSmaller = "Make smaller…"
        public static func share(_ count: Int) -> String { count > 1 ? "Share Pages…" : "Share Page…" }
    }

    /// The sidebar's [+] and Insert Page ▸ (ux §2.1 "Add pages" menu).
    public enum AddPages {
        public static let fromFile = "From file…"
        public static let blankPage = "Blank page"
        public static let fromScanner = "From scanner…"
        public static let fromIPhone = "From iPhone…"
        /// Edit › Insert ▸ titles (Preview's).
        public static let menuFromFile = "From File…"
        public static let menuBlankPage = "Blank Page"
        public static let menuFromScanner = "From Scanner…"
        public static let menuFromIPhone = "From iPhone…"
        public static let addPages = "Add pages"
    }

    // MARK: Toolbar (ux §2.1)

    public enum Toolbar {
        public static let view = "View"
        public static let zoom = "Zoom"
        public static let zoomOut = "Zoom Out"
        public static let actualSize = "Actual Size"
        public static let zoomIn = "Zoom In"
        public static let markup = "Markup"
        public static let rotate = "Rotate"
        public static let formFilling = "Form Filling"
        public static let tools = "Tools"
        public static let share = "Share"
        public static let search = "Search"
        public static let edited = "— Edited"
        public static let hideSidebar = "Hide Sidebar"
        public static let showSidebar = "Show Sidebar"
    }

    // MARK: Page organiser (ux §6.2, organizer.html)

    public enum Organiser {
        public static let title = "Rearrange pages"
        public static let done = "Done"
        public static let size = "Size"
        public static let delete = "Delete"
        public static let hint = "Drag pages to rearrange. Drop files here to add them. Drag pages to the Desktop to save them as a new PDF."
        /// "12 pages · 1 selected · 3 pages from “Inventory.pdf”".
        public static func status(pages: Int, selected: Int, files: [(name: String, pages: Int)]) -> String {
            var parts = [ViewerStrings.pages(pages)]
            if selected > 0 { parts.append("\(selected) selected") }
            parts += files.map { "\(ViewerStrings.pages($0.pages)) from \(Strings.quoted($0.name))" }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Welcome window (ux §6.1, welcome.html)

    public enum Welcome {
        public static let subtitle = "Open a PDF, or drop any file here to turn it into one."
        public static let open = "Open a PDF"
        public static let openHint = "Or drop one anywhere in this window"
        public static let combine = "Combine files"
        public static let combineHint = "Make one PDF from several files or pictures"
        public static let scan = "Scan"
        public static let scanHint = "With your iPhone or a scanner"
        public static let convert = "Convert a file"
        public static let convertHint = "Word, Excel, photos, web pages and more → PDF"
        public static let recent = "Recent"
        public static let showInFinder = "Show in Finder"
        public static let removeFromList = "Remove from list"
        /// The unsaved document Combine makes (ux §5.3: "Combined.pdf").
        public static let combinedName = "Combined"
    }

    // MARK: Sidebar modes (ux §6.3)

    public enum Sidebar {
        public static func matches(_ count: Int) -> String { Formatting.count(count, "match", "matches") }
        public static func page(_ label: String) -> String { "Page \(label)" }
        public static let pageOrder = "Page Order"
        public static let searchRank = "Search Rank"
        public static let reply = "Reply"
        public static let resolve = "Resolve"
        public static let all = "All"
        public static let mine = "Mine"
        public static let unresolved = "Unresolved"
        public static let newEntry = "Add Entry"
        public static let verifyAll = "Verify all"
        public static let changedAfterSigning = "Changed after signing"
        public static let tableOfContentsEmptyHint = "Add entries with +, or let us find headings."
        public static let saveAttachment = "Save…"
        public static let attachment = "Attachment"
        public static let removeBookmark = "Remove Bookmark"
        public static let rename = "Rename Entry"
        public static let delete = "Delete Entry"
        public static let moveEntry = "Move Entry"
    }

    // MARK: Read aloud and Contents panels (ux §5.3; archetype A)

    public enum ReadAloud {
        public static let readFromThisPage = "Read from this page"
        public static let pause = "Pause"
        public static let resume = "Resume"
        public static let stop = "Stop"
        public static let speed = "Speed"
        public static let voice = "Voice"
        public static let systemVoice = "System voice"
        public static let nothingToRead = "This page has no text to read. Recognise text first to read a scan."
    }

    public enum Contents {
        public static let findHeadings = Strings.Empty.findHeadings
        public static let noHeadings = "No headings found. Add entries with + in the sidebar."
        public static func found(_ count: Int) -> String { "Added \(Formatting.count(count, "entry", "entries")) to the table of contents." }
    }

    /// A locked PDF's window (Preview's in-window prompt).
    public enum Locked {
        public static let message = "This PDF is locked. Enter the password to open it."
        public static let placeholder = "Password"
        public static let open = "Open"
    }

    /// Go › Go to Page… (Preview's words).
    public enum GoToPage {
        public static let title = "Go to Page"
        public static func message(_ count: Int) -> String { "Enter a page number between 1 and \(count)." }
        public static let go = "Go"
    }
}
