import AppKit
import SwiftUI
import SuperPDFCore

// The six panes of ux §6.6 as grouped forms, the system's settings look. Every control reads and writes its `Defaults`
// key directly (Settings.swift), so a change applies at once everywhere that key is read.

struct SettingsPaneView: View {
    let pane: SettingsPane
    @StateObject private var state = SettingsState()

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane()
            case .tools: ToolsPane()
            case .converters: ConvertersPane(state: state)
            case .signatures: SignaturesPane(state: state)
            case .scanning: ScanningPane()
            case .privacy: PrivacyPane(state: state)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowController.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { state.reload() }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Default(.openFilesInTabs) private var openInTabs
    @Default(.saveBehaviour) private var saveBehaviour
    @Default(.authorName) private var authorName
    @Default(.defaultZoom) private var defaultZoom
    @Default(.textSize) private var textSize

    var body: some View {
        Form {
            Section {
                Toggle(SettingsText.openInTabs, isOn: $openInTabs)
                Picker(SettingsText.saveBehaviour, selection: $saveBehaviour) {
                    ForEach(SaveBehaviour.allCases, id: \.self) { Text(SettingsText.saveBehaviour($0)).tag($0) }
                }
            }
            Section {
                TextField(SettingsText.authorName, text: $authorName, prompt: Text(SettingsText.authorNamePlaceholder))
            } footer: {
                Text(SettingsText.authorNameNote).foregroundStyle(.secondary)
            }
            Section {
                Picker(SettingsText.defaultZoom, selection: $defaultZoom) {
                    ForEach(DefaultZoom.allCases, id: \.self) { Text(SettingsText.defaultZoom($0)).tag($0) }
                }
                Picker(SettingsText.textSize, selection: $textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text(SettingsText.textSize($0)).tag($0) }
                }
            }
        }
    }
}

// MARK: - Tools

private struct ToolsPane: View {
    @Default(.showRecentlyUsed) private var showRecentlyUsed
    @Default(.showJargonInHints) private var showJargon
    @Default(.toolbarTools) private var toolbarTools
    @Default(.dockMenuTools) private var dockMenuTools

    var body: some View {
        Form {
            Section {
                Toggle(SettingsText.showRecentlyUsed, isOn: $showRecentlyUsed)
                Toggle(SettingsText.showJargon, isOn: $showJargon)
            }
            Section(SettingsText.toolbarTools) { FavouriteList(tools: $toolbarTools) }
            Section(SettingsText.dockMenuTools) { FavouriteList(tools: $dockMenuTools) }
        }
    }
}

/// The tools added with "Add to Toolbar" / "Add to Dock Menu", each with Remove.
private struct FavouriteList: View {
    @Binding var tools: [ToolID]

    var body: some View {
        if tools.isEmpty {
            Text(SettingsText.noFavourites).foregroundStyle(.secondary)
        } else {
            ForEach(tools, id: \.self) { tool in
                let tile = ToolCatalog.tile(tool)
                HStack {
                    Label(tile.name, systemImage: tile.symbol)
                    Spacer()
                    Button(SettingsText.remove) { tools.removeAll { $0 == tool } }
                }
            }
        }
    }
}

// MARK: - Converters

private struct ConvertersPane: View {
    @ObservedObject var state: SettingsState
    @Default(.libreOfficePath) private var libreOfficePath

    var body: some View {
        Form {
            Section(SettingsText.libreOffice) {
                Text(SettingsText.libreOffice(state.libreOffice))
                HStack {
                    if case .notInstalled = state.libreOffice {
                        Button(SettingsText.getLibreOffice) { Services.helpers?.getLibreOffice() }
                    }
                    Button(SettingsText.chooseLibreOffice) { chooseLibreOffice() }
                    if libreOfficePath != nil {
                        Button(SettingsText.useFoundCopy) { libreOfficePath = nil; detect() }
                    }
                    Spacer()
                    Button(SettingsText.lookAgain) { detect() }
                }
                Text(SettingsText.libreOfficeNotice).font(.callout).foregroundStyle(.secondary)
            }
            Section(SettingsText.officeApps) {
                Text(state.officeApps.isEmpty ? SettingsText.noOfficeApps : SettingsText.officeApps(state.officeApps))
            }
        }
    }

    private func detect() {
        Services.helpers?.detect()
        state.reload()
    }

    private func chooseLibreOffice() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libreOfficePath = url
        detect()
    }
}

// MARK: - Signatures

private struct SignaturesPane: View {
    @ObservedObject var state: SettingsState
    @Default(.defaultCertificateID) private var certificateID
    @Default(.addTrustedTimestamp) private var addTimestamp
    @Default(.timestampServer) private var timestampServer

    var body: some View {
        Form {
            Section {
                if state.identities.isEmpty {
                    LabeledContent(SettingsText.myCertificate, value: SettingsText.noCertificate)
                } else {
                    Picker(SettingsText.myCertificate, selection: Binding(get: { certificateID ?? state.identities.first?.id }, set: { certificateID = $0 })) {
                        ForEach(state.identities) { identity in Text(identity.commonName).tag(Optional(identity.id)) }
                    }
                }
            } footer: {
                Text(SettingsText.certificatesNote).foregroundStyle(.secondary)
            }
            Section(SettingsText.trustedPeople) {
                if state.trusted.isEmpty {
                    Text(SettingsText.nobodyTrusted).foregroundStyle(.secondary)
                } else {
                    ForEach(state.trusted) { person in
                        HStack {
                            Text(person.commonName + (person.email.map { " · \($0)" } ?? ""))
                            Spacer()
                            Button(SettingsText.remove) { try? Services.sign?.untrust(person.id); state.reload() }
                        }
                    }
                }
            }
            Section {
                Toggle(SettingsText.addTimestamp, isOn: $addTimestamp)
                TextField(SettingsText.timestampServer, text: Binding(get: { timestampServer?.absoluteString ?? "" },
                                                                     set: { timestampServer = URL(string: $0.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 } }),
                          prompt: Text(SettingsText.timestampPlaceholder))
                    .disabled(!addTimestamp)
            } footer: {
                Text(SettingsText.timestampNote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Scanning

private struct ScanningPane: View {
    @Default(.scanResolution) private var resolution
    @Default(.scanColorMode) private var colorMode
    @Default(.cleanUpScans) private var cleanUp

    var body: some View {
        Form {
            Section {
                Picker(SettingsText.resolution, selection: $resolution) {
                    ForEach(SettingsText.resolutions, id: \.self) { Text(SettingsText.resolution($0)).tag($0) }
                }
                Picker(SettingsText.colorMode, selection: $colorMode) {
                    ForEach(ScanColorMode.allCases, id: \.self) { Text(SettingsText.colorMode($0)).tag($0) }
                }
                Toggle(SettingsText.cleanUp, isOn: $cleanUp)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var state: SettingsState
    @Default(.checkForUpdates) private var checkForUpdates

    var body: some View {
        Form {
            Section {
                Text(SettingsText.privacyIntro)
                ForEach(SettingsText.networkUses, id: \.self) { use in
                    Label(use, systemImage: "network").labelStyle(.titleAndIcon)
                }
                Text(SettingsText.privacyOutro).foregroundStyle(.secondary)
            }
            Section {
                Toggle(SettingsText.checkAutomatically, isOn: $checkForUpdates)
                HStack {
                    Text(SettingsText.update(state.update)).foregroundStyle(.secondary)
                    Spacer()
                    if SettingsText.canInstall(state.update) {
                        Button(SettingsText.installNow) { Services.updates?.installNow() }
                    }
                    Button(SettingsText.checkNow) { Services.updates?.checkNow() }
                        .disabled(state.update == .checking)
                }
            }
        }
    }
}
