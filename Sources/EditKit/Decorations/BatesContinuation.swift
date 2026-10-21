import Foundation
import SuperPDFCore

/// Bates numbers that run on from one file to the next (features #65 "per-file continuation"): after a file of
/// `pages` pages numbered from `bates.start`, the next file starts right after its last number. The panel remembers
/// the last number used so "Do this to many files" and a second run continue the sequence.
public enum BatesContinuation {
    public static func next(after bates: BatesNumbering, pages: Int) -> BatesNumbering {
        var next = bates
        next.start = bates.start + max(pages, 0)
        return next
    }

    /// The number the next file would start at, remembered per prefix/suffix.
    static func nextKey(_ bates: BatesNumbering) -> Defaults.Key<Int> {
        Defaults.Key<Int>("editKit.bates.next.\(bates.prefix)|\(bates.suffix)", default: 1)
    }

    public static func remember(_ bates: BatesNumbering, pages: Int) { Defaults[nextKey(bates)] = next(after: bates, pages: pages).start }
    public static func remembered(for bates: BatesNumbering) -> Int { Defaults[nextKey(bates)] }
}
