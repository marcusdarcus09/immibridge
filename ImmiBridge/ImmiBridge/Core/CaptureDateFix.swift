import Foundation
import ImageIO

/// When the date inside an exported photo disagrees with the date Apple Photos has
/// for it, write Photos' date into the exported copy.
///
/// Photos keeps a date you correct ("Adjust Date and Time") in its own library, not
/// in the original file, so an original exported untouched still carries the old
/// date. Media servers such as Emby date photos by what is inside the file, which
/// is how a camera with its clock set to 2052 ends up at the front of "Latest"
/// for good. The export's file name already uses Photos' date; this makes the
/// contents agree.
///
/// Only a date that is present and more than ~a day off is rewritten. A photo with
/// no date at all is left alone (a full re-run would otherwise see thousands of
/// "changed" files next to their earlier exports), and the day of slack covers
/// time-zone differences between EXIF wall time and Photos' absolute time.
///
/// The rewrite swaps the old date text for the new one, byte for byte, in the
/// file's metadata area (the first 512 KB): both the EXIF form "2052:02:15 11:22:56"
/// and the XMP form "2052-02-15T11:22:56". Same length, so nothing moves and the
/// image data is never touched. (ImageIO's metadata merge only adds an XMP copy and
/// leaves the EXIF dates that Emby reads unchanged.) Videos are not touched.
func applyPhotosCaptureDate(to fileURL: URL, captureDate: Date?) {
    guard let captureDate,
          let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let embeddedString = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    else { return }

    let exifFormat = DateFormatter()
    exifFormat.locale = Locale(identifier: "en_US_POSIX")
    exifFormat.timeZone = TimeZone.current
    exifFormat.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard let embedded = exifFormat.date(from: embeddedString),
          abs(embedded.timeIntervalSince(captureDate)) > 26 * 3600
    else { return }
    let isoFormat = DateFormatter()
    isoFormat.locale = exifFormat.locale
    isoFormat.timeZone = exifFormat.timeZone
    isoFormat.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

    let swaps: [(Data, Data)] = [
        (embeddedString, exifFormat.string(from: captureDate)),
        (isoFormat.string(from: embedded), isoFormat.string(from: captureDate)),
    ].map { (Data($0.0.utf8), Data($0.1.utf8)) }

    guard var data = try? Data(contentsOf: fileURL) else { return }
    let limit = min(data.count, 512 * 1024)
    var changed = 0
    for (old, new) in swaps where old.count == new.count {
        var from = data.startIndex
        while let r = data.range(of: old, in: from..<(data.startIndex + limit)) {
            data.replaceSubrange(r, with: new)
            from = r.upperBound
            changed += 1
        }
    }
    guard changed > 0 else { return }
    try? data.write(to: fileURL, options: .atomic)
}
