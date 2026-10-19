import XCTest

/// Covers the filename rules that decide whether a new file in the capture folder is
/// a real capture. Found the hard way: on a live machine every screenshot produced a
/// spurious candidate and a false "never stopped changing" warning.
final class CaptureWatcherTests: XCTestCase {
    // MARK: - Transient files

    /// macOS writes to a hidden ".Screenshot …" file and renames it into place. The
    /// dotfile must never be treated as a capture: it vanishes mid-settle.
    func testHiddenInProgressScreenshotIsIgnored() {
        XCTAssertTrue(CaptureWatcher.isTransient(filename: ".Screenshot 2026-10-17 at 2.32.33 AM.png"))
    }

    func testOtherDotFilesAreIgnored() {
        XCTAssertTrue(CaptureWatcher.isTransient(filename: ".DS_Store"))
        XCTAssertTrue(CaptureWatcher.isTransient(filename: ".hidden.png"))
    }

    func testTheRealScreenshotIsNotIgnored() {
        XCTAssertFalse(CaptureWatcher.isTransient(filename: "Screenshot 2026-10-17 at 2.32.33 AM.png"))
        XCTAssertFalse(CaptureWatcher.isTransient(filename: "Screen Recording 2026-10-06 at 2.57.18 PM.mov"))
    }

    /// The real filename contains a narrow no-break space (U+202F) before AM/PM and is
    /// localised, which is exactly why detection keys on the folder and extension
    /// rather than parsing the name.
    func testNarrowNoBreakSpaceInRealFilenamesIsNoObstacle() {
        let actual = "Screenshot 2026-10-17 at 12.33.22\u{202F}AM.png"
        XCTAssertFalse(CaptureWatcher.isTransient(filename: actual))
        XCTAssertEqual(CaptureWatcher.mediaType(forExtension: (actual as NSString).pathExtension), .image)
    }

    // MARK: - Media types

    func testImageExtensionsAreRecognised() {
        for ext in ["png", "PNG", "jpg", "jpeg"] {
            XCTAssertEqual(CaptureWatcher.mediaType(forExtension: ext), .image, ext)
        }
    }

    func testVideoExtensionsAreRecognised() {
        for ext in ["mov", "MOV", "mp4"] {
            XCTAssertEqual(CaptureWatcher.mediaType(forExtension: ext), .video, ext)
        }
    }

    /// Recordings are kept and attachable, but not sent to the model in v0.
    func testOnlyImagesSupportDrafting() {
        XCTAssertTrue(SnagRecord.MediaType.image.supportsDrafting)
        XCTAssertFalse(SnagRecord.MediaType.video.supportsDrafting)
    }

    func testUnrelatedFilesAreNotCaptures() {
        for ext in ["txt", "pdf", "sketch", ""] {
            XCTAssertNil(CaptureWatcher.mediaType(forExtension: ext), ext)
        }
    }
}
