import AppKit
import SuperPDFCore

/// ViewerKit's two tiles (ARCHITECTURE contract notes: Contents and Read aloud live in the viewer). Both are archetype A
/// (ux §5.2): one or two controls and one button.
@MainActor
final class ViewerTools: ToolProviding {
    let tools: [ToolID] = ToolCatalog.tiles(ownedBy: .viewerKit).map(\.id)

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .readAloud:
            let reader = context.document.flatMap { Viewer.shared.controller(for: $0)?.readAloud }
            let pause = reader?.isPaused == true ? ViewerStrings.ReadAloud.resume : ViewerStrings.ReadAloud.pause
            var controls: [ToolControl] = [
                .slider(id: "speed", label: ViewerStrings.ReadAloud.speed, range: 0.5...2, step: 0.25, value: reader?.speed ?? 1, format: .plain),
                .popup(id: "voice", label: ViewerStrings.ReadAloud.voice, options: ReadAloudController.voiceOptions(),
                       selected: reader?.voiceIdentifier ?? ""),
            ]
            if reader?.isSpeaking == true {
                controls.insert(.action(id: "pause", title: pause, isDestructive: false, symbol: reader?.isPaused == true ? "play.fill" : "pause.fill"), at: 0)
            }
            return ToolPanel(.oneChoice, controls: controls, primary: ToolButton(ViewerStrings.ReadAloud.readFromThisPage),
                             secondary: ToolButton(reader?.isSpeaking == true ? ViewerStrings.ReadAloud.stop : Strings.Panel.cancel))
        default:
            return ToolPanel(.oneChoice, controls: [.note(ViewerStrings.Sidebar.tableOfContentsEmptyHint)],
                             primary: ToolButton(ViewerStrings.Contents.findHeadings), output: .inPlace)
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        guard let document = context.document, let reader = Viewer.shared.controller(for: document)?.readAloud else { return context.values }
        switch action {
        case "pause": reader.togglePause()
        case ToolPanel.secondaryAction: reader.stop()
        default: break
        }
        return context.values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let document = request.document, let controller = Viewer.shared.controller(for: document) else { return .none }
        switch request.tool {
        case .readAloud:
            let reader = controller.readAloud
            reader.speed = request.values.double("speed", default: 1)
            let voice = request.values.string("voice")
            reader.voiceIdentifier = voice.isEmpty ? nil : voice
            guard reader.start(fromPage: controller.currentPageIndex) else { throw ToolError(ViewerStrings.ReadAloud.nothingToRead) }
            return .none
        default:
            controller.showSidebar(.tableOfContents)
            let headings = await OutlineBuilder.headings(in: document)
            guard let group = OutlineBuilder.insert(headings, into: document) else { throw ToolError(ViewerStrings.Contents.noHeadings) }
            return .inPlace(undoable: group, banner: ResultBanner(ViewerStrings.Contents.found(headings.count)))
        }
    }
}
