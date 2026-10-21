import Foundation
import SuperPDFCore

// SignKit's copy (ux §5.3 Sign, Request signatures, Certificates & signatures; the mockups panel-sign.png and
// panel-request-signatures.png). Sentence case, curly quotes, a real ellipsis on anything that opens a dialog.

enum SignStrings {
    // MARK: Sign (ux §5.3, mockup)

    static let signHint = "Put your signature on the page. Click a signature, then click where it goes."
    static let mySignature = "My signature"
    static let withCertificate = "With a certificate"
    static let savedOnThisMac = "Saved on this Mac"
    static let initials = "Initials"
    static let createSignature = "Create signature…"
    static let captureNote = "You can draw on the trackpad, hold a signed piece of paper up to the camera, or sign on your iPhone."
    static let date = "Date"
    static let addDate = "Add today’s date next to it"
    static let signAndSave = "Sign and save…"
    static let text = "Text"
    static let textPlaceholder = "Words to add, like your name in capitals"
    static let certificate = "Certificate"
    static let createCertificate = "Create my certificate…"
    static let reason = "Reason"
    static let reasonPlaceholder = "I agree to this document"
    static let location = "Location"
    static let locationPlaceholder = "Where you are signing"
    static let lockAfterSigning = "Lock the document after signing"
    static let certificatePlacement = "Click the page where the signature box goes. Without a box the signature is still in the file, just not shown."
    static let deleteSignature = "Delete"
    static let encrypted = "This file has a password. Remove the password first, then sign it."
    static let unnamed = "Unknown"

    /// Accessibility labels of placed marks.
    static let signatureLabel = "Signature"
    static let initialsLabel = "Initials"
    static let dateLabel = "Date"

    // The visible certificate signature (features #82: name, date, reason, location).
    static let digitallySignedBy = "Digitally signed by"
    static func sealDate(_ date: Date) -> String { "Date: " + date.formatted(date: .abbreviated, time: .shortened) }
    static func sealReason(_ reason: String) -> String { "Reason: " + reason }
    static func sealLocation(_ location: String) -> String { "Location: " + location }

    /// Today's date as placed next to a signature ("20 Oct 2026").
    static func placedDate(_ date: Date = Date()) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    // MARK: Create signature (Preview's three: Trackpad · Camera · iPhone)

    static let trackpad = "Trackpad"
    static let camera = "Camera"
    static let iPhone = "iPhone"
    static let trackpadStart = "Click here to begin"
    static let trackpadHint = "Sign your name on the trackpad with one finger. Press any key when you’re done."
    static let cameraHint = "Sign your name in dark ink on white paper, then hold it up to the camera. Keep it level."
    static let cameraUnavailable = "Super PDF can’t use the camera. Allow it in System Settings › Privacy & Security › Camera."
    static let iPhoneHint = "Choose your iPhone or iPad, then sign on its screen with your finger and tap Done."
    static let signOnIPhone = "Sign on iPhone…"
    static let nothingCaught = "No signature yet."
    static let clear = "Clear"
    static let saveSignature = "Save signature"
    static let cancel = Strings.Panel.cancel

    // MARK: Create my certificate (features #85)

    static let createCertificateTitle = "Create my certificate"
    static let createCertificateHint = "People who open your signed files can check it was you. It stays in your login Keychain for 10 years."
    static let yourName = "Your name"
    static let email = "Email"
    static let emailPlaceholder = "Optional"
    static let create = "Create certificate"

    // MARK: Certificates & signatures (ux §5.3)

    static let signaturesInFile = "Signatures in this file"
    static let myCertificate = "My certificate"
    static let peopleITrust = "People I trust"
    static let noSignatures = "This file has no signatures."
    static let checking = "Checking signatures…"
    static let valid = "Valid"
    static let untrusted = "Not from someone you trust yet"
    static let modified = "Changed after signing"
    static let invalid = "Can’t be checked"
    static let changedLater = "Changed after signing"
    static let trustThisPerson = "Trust this person"
    static let importP12 = "Import .p12…"
    static let exportCertificate = "Export public certificate…"
    static let p12Password = "Password of the .p12 file"
    static let importAction = "Import"
    static let wrongP12Password = "That password doesn’t open this file."
    static let noIdentityInP12 = "This file holds no certificate with its key."
    static let noCertificate = "You don’t have a certificate yet."
    static let noTrusted = "Nobody yet. When someone sends you their certificate, add it here so their signatures show as valid."
    static let trustCertificateFile = "Add a certificate…"
    static let remove = "Remove"
    /// The file as a signature signed it ("Show what changed").
    static func asSigned(_ name: String) -> String { "\(name) (as signed)" }
    static func validUntil(_ date: Date) -> String { "Valid until " + date.formatted(date: .abbreviated, time: .omitted) }
    static func signed(_ date: Date) -> String { "Signed " + date.formatted(date: .abbreviated, time: .shortened) }

    // MARK: Request signatures (ux §5.3, mockup)

    static let requestHint = "Send this to people to sign. They can sign in any PDF app and send it back; we match the files when they return."
    static let steps = ["1 Who", "2 Where", "3 Send"]
    static let who = "Add the people who need to sign."
    static let name = "Name"
    static let namePlaceholder = "Their name"
    static let emailAddressPlaceholder = "Their email address"
    static let addPerson = "Add person"
    static let addFromContacts = "Add from Contacts…"
    static let signInOrder = "Sign in this order"
    static let nextWhere = "Next: Where"
    static let nextSend = "Next: Send"
    static let whereNote = "Click the page to place a field for the selected person."
    static let fieldsNote = "Fields show in each person’s colour. Everything stays on this Mac; nothing is uploaded."
    static func fields(_ count: Int) -> String { Formatting.count(count, "field", "fields") }
    static let message = "Message"
    static let sendNote = "They can sign in any PDF app and send it back. When the file comes back, open it here and we’ll match it."
    static let sendWithMail = "Send with Mail"
    static let sendWithMessages = "Send with Messages"
    static let airDrop = "AirDrop"
    static let saveSigningPackage = "Save signing package…"
    static let removePerson = "Remove"
    static func cantShare(_ channel: SharingChannel) -> String {
        switch channel {
        case .mail: "Mail isn’t set up on this Mac. Save the signing package and send it another way."
        case .messages: "Messages isn’t set up on this Mac. Save the signing package and send it another way."
        case .airDrop: "AirDrop isn’t available right now. Save the signing package and send it another way."
        }
    }
    static let everyoneNeedsAField = "Give each person at least one place to sign."

    static func fieldKind(_ kind: RequestFieldKind) -> String {
        switch kind {
        case .signature: "Signature"
        case .initials: "Initials"
        case .date: "Date"
        case .name: "Name"
        case .checkbox: "Tick box"
        }
    }

    static func defaultMessage(_ documentName: String) -> String {
        "Please sign “\(documentName)”. Open the attached PDF in any PDF app, sign in the highlighted spots, and send it back to me."
    }

    static func mailSubject(_ documentName: String) -> String { "Please sign “\(documentName)”" }
    static func reminderSubject(_ documentName: String) -> String { "Reminder: please sign “\(documentName)”" }

    // MARK: Cover page and audit page (features #84)

    static func coverTitle(_ documentName: String) -> String { "Please sign “\(documentName)”" }
    static let coverInstructions = "Open in any PDF app, sign in the highlighted spots, send it back."
    static let coverWho = "Who signs"
    static let coverOrder = "Please sign in this order."
    static func coverReference(_ id: UUID) -> String { "Reference: \(id.uuidString.lowercased())" }
    static let auditTitle = "Signature record"
    static func auditDocument(_ name: String) -> String { "Document: \(name)" }
    static func auditSent(_ date: Date) -> String { "Sent: " + date.formatted(date: .abbreviated, time: .shortened) }
    static func auditReturned(_ date: Date?) -> String {
        date.map { "Signed: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Signed: —"
    }
    static func auditFile(_ hash: String) -> String { "Their file (SHA-256): \(hash)" }
    static func auditPackage(_ hash: String) -> String { "Sent file (SHA-256): \(hash)" }
    static func auditSealed(_ date: Date, by name: String) -> String {
        "Sealed by \(name) on " + date.formatted(date: .abbreviated, time: .shortened) + "."
    }

    // MARK: Signatures I asked for (Window › Signature Requests)

    static let requestsWindowTitle = "Signatures I asked for"
    static func state(_ state: SignerState) -> String {
        switch state {
        case .waiting: "Waiting"
        case .returned: "Returned"
        case .done: "Done"
        }
    }
    static let remind = "Remind"
    static let signInPerson = "Sign in person"
    static let sealAndFinish = "Seal and finish"
    static let sealed = "Sealed"
    static let openSealed = "Open"
    static let dropReturned = "Drop a signed copy here to match it."
    static func created(_ date: Date) -> String { "Sent " + date.formatted(date: .abbreviated, time: .omitted) }
    static func cameBack(_ name: String, from people: [String]) -> String {
        "\(Strings.quoted(name)) came back from \(ListFormatter.localizedString(byJoining: people))."
    }
}
