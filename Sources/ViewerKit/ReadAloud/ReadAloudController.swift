import AVFoundation
import NaturalLanguage
import PDFKit
import SuperPDFCore

/// Sentences of a page's text, for reading aloud one highlight at a time (features #3).
public enum SentenceSplitter {
    /// The sentences of `text` as UTF-16 ranges (what PDFKit selections and speech ranges use), blank ones dropped.
    public static func sentences(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if !text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ranges.append(NSRange(range, in: text)) }
            return true
        }
        return ranges
    }

    /// The sentence holding a spoken range.
    public static func sentence(containing range: NSRange, in sentences: [NSRange]) -> NSRange? {
        sentences.first { NSLocationInRange(range.location, $0) }
    }
}

/// Read aloud (features #3, ux §5.3): the system voice reads from a page on, a page at a time, and the sentence being
/// read is highlighted in Preview's yellow; speed and voice come from the panel. Also Edit › Speech.
@MainActor
final class ReadAloudController: NSObject, AVSpeechSynthesizerDelegate {
    private unowned let owner: DocumentWindowController
    private let synthesizer = AVSpeechSynthesizer()
    private var page = 0
    private var sentences: [NSRange] = []
    /// Reading only the selection: stop at its end.
    private var selectionOnly = false
    /// Speed relative to the system's default rate (0.5…2).
    var speed: Double = 1
    var voiceIdentifier: String?

    init(owner: DocumentWindowController) {
        self.owner = owner
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    /// Reads the selection when there is one, else from `fromPage` to the end. False when there is nothing to read.
    @discardableResult
    func start(fromPage index: Int, selection: PDFSelection? = nil) -> Bool {
        stop()
        if let selection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let first = selection.pages.first {
            selectionOnly = true
            page = owner.handle.pdf.index(for: first)
            sentences = SentenceSplitter.sentences(in: text)
            speak(text)
            return true
        }
        selectionOnly = false
        page = index
        return speakPage()
    }

    func togglePause() {
        if synthesizer.isPaused { synthesizer.continueSpeaking() } else { synthesizer.pauseSpeaking(at: .word) }
    }

    func stop() {
        selectionOnly = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        owner.pdfView.highlightedSelections = nil
    }

    /// Speaks the current page, skipping pages without text; false at the end.
    private func speakPage() -> Bool {
        let pdf = owner.handle.pdf
        while page < pdf.pageCount {
            if let text = pdf.page(at: page)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences = SentenceSplitter.sentences(in: text)
                if let page = pdf.page(at: page) { owner.pdfView.go(to: page) }
                speak(text)
                return true
            }
            page += 1
        }
        return false
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * speed, Double(AVSpeechUtteranceMinimumSpeechRate)),
                                   Double(AVSpeechUtteranceMaximumSpeechRate)))
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    /// Up to seven voices for the panel's popup (ux §5.1): the system voice, then this language's best voices.
    static func voiceOptions() -> [ToolOption] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
        return [ToolOption("", ViewerStrings.ReadAloud.systemVoice)] + voices.prefix(6).map { ToolOption($0.identifier, $0.name) }
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.highlight(characterRange) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.owner.pdfView.highlightedSelections = nil
                guard !self.selectionOnly else { self.selectionOnly = false; return }
                self.page += 1
                _ = self.speakPage()
            }
        }
    }

    private func highlight(_ spoken: NSRange) {
        guard !selectionOnly, let sentence = SentenceSplitter.sentence(containing: spoken, in: sentences),
              let page = owner.handle.pdf.page(at: page), let selection = page.selection(for: sentence) else { return }
        selection.color = SPColor.highlightYellow.color
        owner.pdfView.highlightedSelections = [selection]
    }
}
