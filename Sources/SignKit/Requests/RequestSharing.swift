import AppKit
import SuperPDFCore

// How a signing package leaves the Mac (features #84 step 2, ux §5.3 Send): Mail, Messages or AirDrop through the
// system's share services, with the people, a subject and the message filled in. Nothing is uploaded by Super PDF.

public enum SharingChannel: String, Sendable {
    case mail, messages, airDrop
}

@MainActor
public protocol RequestSharing: AnyObject {
    /// Hands `file` to the channel's composer, addressed to `recipients`.
    func share(_ file: URL, to recipients: [String], subject: String, message: String, via channel: SharingChannel) throws
}

/// NSSharingService: Mail's and Messages' compose windows, the AirDrop sheet.
@MainActor
public final class SystemSharing: RequestSharing {
    public init() {}

    public func share(_ file: URL, to recipients: [String], subject: String, message: String, via channel: SharingChannel) throws {
        let name: NSSharingService.Name = switch channel {
        case .mail: .composeEmail
        case .messages: .composeMessage
        case .airDrop: .sendViaAirDrop
        }
        let items: [Any] = channel == .airDrop ? [file] : [message, file]
        guard let service = NSSharingService(named: name), service.canPerform(withItems: items) else {
            throw ToolError(SignStrings.cantShare(channel))
        }
        service.recipients = recipients
        service.subject = subject
        service.perform(withItems: items)
    }
}
