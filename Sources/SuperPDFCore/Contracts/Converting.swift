import Combine
import Foundation
import UniformTypeIdentifiers

// Conversions (ConvertKit: `Services.convert`, `Services.helpers`; features §1.3, §1.4, §3.2). The route table is data
// (`ConverterTable`); ConvertKit is its runtime.

/// The conversion registry runtime.
@MainActor
public protocol Converting: AnyObject {
    /// The ranked engines for a file type into a format, each with its availability on this Mac; empty when the type
    /// can't be converted.
    func converters(for input: UTType, to output: ConversionFormat) -> [ConverterOffer]
    /// Whether a dropped file can become a PDF (directly or through Quick Look).
    func canConvertToPDF(_ url: URL) -> Bool
    /// Runs a job off the main actor; app automation shows its "will open briefly" notice first.
    func convert(_ job: ConversionJob, progress: ToolProgress) async throws -> ConversionResult
}

/// The LibreOffice helper and the Office apps on this Mac (features §3.2; Settings › Converters). LibreOffice is never
/// bundled, downloaded or installed by Super PDF: an installed copy is detected and run headless; when there is none,
/// panels explain and offer "Get LibreOffice".
@MainActor
public protocol HelperManaging: AnyObject {
    var libreOffice: HelperStatus { get }
    /// Apps found for automation, with where they live.
    var officeApps: [OfficeApp: URL] { get }
    /// Looks again (launch, Settings, after the person installed LibreOffice or an app).
    func detect()
    /// Opens LibreOffice's download page in the browser ("Get LibreOffice"); nothing is downloaded by Super PDF.
    func getLibreOffice()
    var changes: AnyPublisher<Void, Never> { get }
}
