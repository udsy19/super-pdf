import Foundation
import SuperPDFCore

/// EditKit's own copy (ux §5.3 Edit text & images, Headers & footers, Watermark, Bates, Stamps, Links; §1.1 tone).
enum EditKitStrings {
    // MARK: Undo action names (features §2.3)

    enum Undo {
        static let editText = "Edit Text"
        static let addText = "Add Text"
        static let deleteText = "Delete Text"
        static let moveImage = "Move Picture"
        static let resizeImage = "Resize Picture"
        static let rotateImage = "Rotate Picture"
        static let flipImage = "Flip Picture"
        static let cropImage = "Crop Picture"
        static let replaceImage = "Replace Picture"
        static let deleteImage = "Delete Picture"
        static let addImage = "Add Picture"
        static let replaceText = "Replace Text"
        static let headers = "Add Headers & Footers"
        static let removeHeaders = "Remove Headers & Footers"
        static let pageNumbers = "Add Page Numbers"
        static let removePageNumbers = "Remove Page Numbers"
        static let bates = "Add Bates Numbers"
        static let removeBates = "Remove Bates Numbers"
        static let watermark = "Add Watermark"
        static let removeWatermark = "Remove Watermark"
        static let background = "Add Background"
        static let removeBackground = "Remove Background"
        static let stamp = "Add Stamp"
        static let link = "Add Link"
        static let links = "Add Links"
        static let removeScripts = "Remove Scripts"
        static let properties = "Change Properties"
        static let transitions = "Change Page Transitions"
        static let destinations = "Change Destinations"
        static let layers = "Change Layers"

        static func remove(_ kind: DecorationKind) -> String {
            switch kind {
            case .headerFooter: removeHeaders
            case .pageNumbers: removePageNumbers
            case .bates: removeBates
            case .watermark: removeWatermark
            case .background: removeBackground
            }
        }

        static func add(_ kind: DecorationKind) -> String {
            switch kind {
            case .headerFooter: headers
            case .pageNumbers: pageNumbers
            case .bates: bates
            case .watermark: watermark
            case .background: background
            }
        }
    }

    // MARK: Edit text & images (D)

    enum Edit {
        static let hint = "Click a paragraph to retype it, or a picture to move, resize or swap it. Everything can be undone."
        static let select = "Select"
        static let addText = "Add text"
        static let addImage = "Add picture"
        static let findReplace = "Find & replace"
        static let selectNote = "Click some words or a picture on the page."
        static let addTextNote = "Click on the page where the new text should start."
        static let addImageNote = "Choose a picture, then click on the page where it goes."
        static let pictureLabel = "Picture"
        static let blockSelected = "Click inside the words to change them. Click somewhere else when you’re done."
        static let imageSelected = "Drag the picture to move it, or its corners to resize it."
        static let notEditable = "This text is part of a shared drawing and can’t be changed here."
        static let fontsSubstituted = "Fonts not on this Mac are substituted."
        static let font = "Font"
        static let size = "Size"
        static let bold = "Bold"
        static let italic = "Italic"
        static let colour = "Colour"
        static let alignment = "Alignment"
        static let alignLeft = "Left"
        static let alignCenter = "Centre"
        static let alignRight = "Right"
        static let alignJustified = "Justified"
        static let flipHorizontal = "Flip"
        static let rotate = "Turn 90°"
        static let replaceImage = "Swap picture…"
        static let editIn = "Edit in another app…"
        static let deleteImage = "Delete picture"
        static let find = "Find"
        static let replaceWith = "Replace with"
        static let matchCase = "Match upper and lower case"
        static let wholeWords = "Whole words only"
        static let replaceAll = "Replace everywhere"
        static let nothingFound = "Nothing to replace."
        static func replaced(_ count: Int, notFitting: Int) -> String {
            let replaced = count == 1 ? "Replaced 1 word." : "Replaced \(count) words."
            guard notFitting > 0 else { return replaced }
            return replaced + (notFitting == 1 ? " 1 didn’t fit and was left as it was." : " \(notFitting) didn’t fit and were left as they were.")
        }
        static let scriptsFound = "This file has scripts. Remove them?"
        static let removeScripts = "Remove scripts"
        static let scriptsRemoved = "The scripts are gone."
        static let placeholderText = "Type here"
        static let fontMissingDetails = "The text was retyped with a font that has every letter you used."
        static let typeOnPage = "Type on the page, then click somewhere else."
        static let shortcuts = "⌘Z undoes a change. Esc puts a paragraph back as it was."
    }

    // MARK: Headers & footers (C)

    enum Headers {
        static let hint = "Put a title, the date or page numbers at the top or bottom of every page. The page shows them as you type."
        static let fieldsLabel = "Fields"
        static let topLeft = "Top left", topCenter = "Top centre", topRight = "Top right"
        static let bottomLeft = "Bottom left", bottomCenter = "Bottom centre", bottomRight = "Bottom right"
        static let insert = "Insert"
        static let tokenPageNumber = "Page number", tokenPageCount = "Page count", tokenDate = "Date", tokenTitle = "Title"
        static let tokenFileName = "File name", tokenAuthor = "Author", tokenBates = "Bates number"
        static let font = "Font"
        static let size = "Size"
        static let margins = "Distance from the edge"
        static let shrink = "Shrink the page a little to make room"
        static let replace = "Replace the ones already there"
        static let dateFormat = "Date looks like"
        static let startNumber = "First page number"
        static let add = "Add to pages"
        static let remove = "Remove headers & footers"
        static let nothingToAdd = "Type something in one of the fields first."
        static let removed = "Headers and footers removed."
    }

    // MARK: Watermark (C)

    enum Watermark {
        static let hint = "Stamps a word or a logo across every page. You can see it on the page as you type."
        static let text = "Text", picture = "Picture", colour = "Colour"
        static let textPlaceholder = "DRAFT"
        static let pictureLabel = "Picture or PDF"
        static let lightness = "Lightness"
        static let angle = "Angle"
        static let straight = "Straight", diagonal = "Diagonal", custom = "Custom…"
        static let customAngle = "Turn"
        static let font = "Font"
        static let size = "Size"
        static let colourLabel = "Colour"
        static let behind = "Behind the page’s content"
        static let position = "Position"
        static let printOnly = "Only when printing"
        static let screenOnly = "Only on screen"
        static let add = "Add watermark"
        static let addBackground = "Add background"
        static let remove = "Remove watermark"
        static let removeBackground = "Remove background"
        static let dragNote = "Nothing is saved until you click Add watermark."
        static let choosePicture = "Choose a picture or a PDF first."
        static let typeSomething = "Type the words first."
    }

    // MARK: Bates (C)

    enum Bates {
        static let hint = "Numbers every page with a prefix, a running number and a suffix, the way legal filings need."
        static let prefix = "Before the number"
        static let suffix = "After the number"
        static let start = "Start at"
        static let digits = "Digits"
        static let position = "Position"
        static let font = "Font"
        static let size = "Size"
        static let continueLast = "Carry on from the last file"
        static let add = "Add Bates numbers"
        static let remove = "Remove Bates numbers"
        static func example(_ label: String) -> String { "First page: \(label)" }
        static func next(_ number: Int) -> String { "The next file would start at \(number)." }
    }

    // MARK: Stamps (C)

    enum Stamps {
        static let hint = "Puts a stamp on this page: Approved, Draft, Received… or a picture of your own."
        static let stamp = "Stamp"
        static let custom = "Your own picture or PDF"
        static let size = "Size"
        static let position = "Position"
        static let turn = "Turn"
        static let opacity = "Strength"
        static let name = "Your name"
        static let everyPage = "Put it on every page"
        static let add = "Add stamp"
        static let dragNote = "The stamp goes where the dots say; drag it on the page to fine-tune."
        static func title(_ design: StampDesign) -> String {
            switch design.id {
            case "approved": "Approved"
            case "draft": "Draft"
            case "confidential": "Confidential"
            case "final": "Final"
            case "received": "Received"
            case "sign-here": "Sign here"
            case "reviewed": "Reviewed"
            case "void": "Void"
            case "approved-by": "Approved by me, dated"
            case "received-on": "Received, with date and time"
            case "revised": "Revised, dated"
            default: design.text
            }
        }
    }

    // MARK: Links (C)

    enum Links {
        static let hint = "Makes an area of the page clickable: it can jump to a page or open a web address or a file."
        static let goToPage = "Go to page", web = "Web address", file = "Open file"
        static let page = "Page"
        static let destination = "Named place"
        static let url = "Address"
        static let urlPlaceholder = "https://"
        static let fileLabel = "File"
        static let drawNote = "Drag a box on the page over the words or picture that should be clickable."
        static func area(page: Int) -> String { "Link area drawn on page \(page + 1). Drag again to change it." }
        static let detect = "Make links from the web addresses in the text"
        static func detected(_ count: Int) -> String { count == 0 ? "No web addresses found in the text." : count == 1 ? "Made 1 link." : "Made \(count) links." }
        static let add = "Add link"
        static let badURL = "That doesn’t look like a web address. It should start with https://."
        static let noArea = "Drag a box on the page first."
        static let chooseFile = "Choose the file to open first."
    }

    // MARK: Fonts offered in popups (standard faces first; Georgia and others are embedded)

    static let fontChoices: [(id: String, title: String)] = [
        ("Helvetica", "Helvetica"), ("Helvetica-Bold", "Helvetica Bold"), ("Times-Roman", "Times"), ("Times-Bold", "Times Bold"),
        ("Courier", "Courier"), ("Georgia", "Georgia"), ("Avenir Next", "Avenir Next"),
    ]

    static let colourChoices: [(id: String, title: String)] = [
        ("#000000", "Black"), ("#555555", "Grey"), ("#C0392B", "Red"), ("#1F5FBF", "Blue"), ("#2E8B57", "Green"), ("#FF9500", "Orange"), ("#FFFFFF", "White"),
    ]

    static let backgroundColours: [(id: String, title: String)] = [
        ("#FFF2CC", "Pale yellow"), ("#F2F2F2", "Light grey"), ("#E3F0FF", "Pale blue"), ("#E6F5E6", "Pale green"), ("#FDE7EF", "Pale pink"), ("#FFFFFF", "White"),
    ]

    static let dateFormats: [(id: String, title: String)] = [
        ("d MMMM yyyy", "20 October 2026"), ("dd/MM/yyyy", "20/10/2026"), ("MM/dd/yyyy", "10/20/2026"), ("yyyy-MM-dd", "2026-10-20"),
        ("MMMM d, yyyy", "October 20, 2026"), ("d MMM yyyy", "20 Oct 2026"),
    ]
}
