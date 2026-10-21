import AppKit
import SuperPDFCore
import SwiftUI
import UniformTypeIdentifiers

// Window › Signature Requests: "Signatures I asked for" (ux §5.3). Each request with its people and where they are
// (Waiting · Returned · Done), Remind and Sign in person for those still to sign, and Seal and finish once everyone
// has. Dropping a returned copy on the window matches it.

@MainActor
final class RequestsWindowController: NSWindowController {
    init(service: RequestService) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = SignStrings.requestsWindowTitle
        window.minSize = NSSize(width: 460, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SignatureRequests")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: RequestsList(service: service, window: { [weak window] in window }))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

private struct RequestsList: View {
    @ObservedObject var service: RequestService
    var window: () -> NSWindow?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if service.requests.isEmpty {
                Text(Strings.Empty.signatureRequests)
                    .font(.system(size: 13)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            } else {
                List(service.requests) { request in RequestCard(request: request, service: service, window: window) }
                    .listStyle(.inset)
            }
            Divider()
            Text(SignStrings.dropReturned).font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
        }
        .overlay { if isTargeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(4) } }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        do { _ = try await service.receive(url) } catch { Prompts.show(error, in: window()) }
                    }
                }
            }
            return true
        }
    }
}

private struct RequestCard: View {
    var request: SignatureRequest
    @ObservedObject var service: RequestService
    var window: () -> NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.documentName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(SignStrings.created(request.created)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(request.signers.sorted { $0.order < $1.order }) { signer in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: NSColor(hex: signer.color))).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(signer.name).font(.system(size: 13))
                        Text(signer.email).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(SignStrings.state(signer.state)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(signer.state == .done ? Color.green : signer.state == .returned ? Color.orange : Color.secondary)
                    if signer.state != .done, request.sealedAt == nil {
                        Button(SignStrings.remind) { attempt { try service.remind(request, signer: signer) } }.controlSize(.small)
                        Button(SignStrings.signInPerson) { attemptAsync { try await service.signInPerson(request) } }.controlSize(.small)
                    }
                }
            }
            if request.sealedAt != nil {
                HStack {
                    Label(SignStrings.sealed, systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
                    Spacer()
                    Button(SignStrings.openSealed) { attemptAsync { _ = try await Services.documents.open(service.sealedURL(request)) } }
                        .controlSize(.small)
                }
            } else if request.isComplete {
                HStack {
                    Spacer()
                    Button(SignStrings.sealAndFinish) { attemptAsync { try await seal() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// The sender's certificate (made on the spot when there is none), then the sealed copy opens.
    private func seal() async throws {
        var identity = service.sign.preferredIdentity
        if identity == nil {
            guard let details = await Prompts.newCertificate(in: window()) else { return }
            identity = try await service.sign.createIdentity(name: details.name, email: details.email)
        }
        guard let identity else { return }
        let url = try await service.seal(request, identityID: identity.id)
        _ = try await Services.documents.open(url)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { Prompts.show(error, in: window()) }
    }

    private func attemptAsync(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { Prompts.show(error, in: window()) }
        }
    }
}
