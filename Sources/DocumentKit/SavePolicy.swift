import Foundation
import SuperPDFCore

/// What ⌘S does (ux §7.1): the first save of a file we did not create asks "Save a copy…" or "Replace original"
/// unless General › Default save behaviour picked one; files made here show the save panel; after the first choice it
/// saves to the document's file (the copy, or the original that was chosen for replacing), and autosave is on.
public enum SaveStep: Equatable, Sendable {
    /// No file yet (Combined, converted, scanned): the save panel.
    case savePanel
    /// The "Save changes to “Report.pdf”?" sheet.
    case ask
    /// The save panel proposing "Report (edited).pdf" next to the original; the document then lives in the copy.
    case saveCopy
    /// Write over the original (NSDocument keeps the old contents as a version).
    case replaceOriginal
    /// The choice was made: save to the document's file.
    case save
}

public enum SavePolicy {
    /// The step ⌘S takes for a document in this state, given the General setting.
    public static func step(origin: DocumentOrigin, hasFile: Bool, choice: SaveBehaviour?, wasRepaired: Bool,
                     setting: SaveBehaviour) -> SaveStep {
        guard hasFile else { return .savePanel }
        if origin == .createdHere || choice == .replaceOriginal || choice == .alwaysSaveCopy { return .save }
        switch setting {
        case .ask: return .ask
        case .alwaysSaveCopy: return .saveCopy
        // A repaired file is never written over without asking (ux §7.4: "Check that everything looks right, then save
        // a copy"), whatever the setting says.
        case .replaceOriginal: return wasRepaired ? .ask : .replaceOriginal
        }
    }

    /// Whether writing to the document's own file is allowed yet. Until it is, autosave keeps the changes elsewhere
    /// and the original stays exactly as it was (ux §1.1 "Nothing is lost").
    public static func mayWriteInPlace(origin: DocumentOrigin, hasFile: Bool, choice: SaveBehaviour?) -> Bool {
        hasFile && (origin == .createdHere || choice == .replaceOriginal || choice == .alwaysSaveCopy)
    }

    /// The sheet's answer: what to do now and, with "Always do this", the setting to remember.
    public static func resolve(_ answer: FirstSaveAnswer, always: Bool) -> (step: SaveStep, newSetting: SaveBehaviour?) {
        switch answer {
        case .saveCopy: (.saveCopy, always ? .alwaysSaveCopy : nil)
        case .replaceOriginal: (.replaceOriginal, always ? .replaceOriginal : nil)
        }
    }
}

/// The buttons of the "Save changes to “Report.pdf”?" sheet other than Cancel.
public enum FirstSaveAnswer: Equatable, Sendable {
    case saveCopy, replaceOriginal
}
