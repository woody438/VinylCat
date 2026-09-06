import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

/// What Apple Vision found on a still: barcodes + OCR lines. Free and on-device.
struct LocalReading: Sendable {
    var barcodes: [String] = []
    var lines: [String] = []
    /// Catalogue-number-looking tokens pulled from the OCR text, best first.
    var catalogueCandidates: [String] = []
    /// Magnified crops of the smallest print (2–4×), the ones most likely to hold the catalogue and
    /// matrix numbers. Handed to the vision model, which otherwise sees that print at ~6px.
    var closeUps: [CGImage] = []
    /// How many crops the zoom pass read; diagnostics for `--ocr-eval`.
    var zoomCrops = 0
    var text: String { lines.joined(separator: "\n") }
}

enum LocalReader {
    /// Text on a round label runs around the spindle, so a good third of it is sideways to the camera.
    /// Vision reads upright text only; asking for the same frame at 90° each way picks up the rest.
    /// Upside-down (a record put down the wrong way round) is tried only when the first three
    /// passes found nothing catalogue-shaped, as it doubles the time for a rare case.
    static let orientations: [CGImagePropertyOrientation] = [.up, .right, .left]
    static let fallbackOrientations: [CGImagePropertyOrientation] = [.down]
    /// Catalogue numbers are the smallest print on a label: ~1% of frame height on a 7" held at
    /// arm's length. Vision's default (1/32 ≈ 3%) skips them.
    static let minimumTextHeight: Float = 0.008

    /// Zoom pass: print shorter than this (pixels, in the still) is cropped, magnified and read again.
    /// On a 1080p still the catalogue number is 9–18px tall and Vision misreads a digit in a third of
    /// them ("OS 13001" for "OS 13061"); at 2–4× it reads the same print cleanly.
    static let zoomBelowPixels = 26.0
    /// Low-confidence lines get a second look too, up to this size.
    static let zoomLowConfidenceBelowPixels = 44.0
    static let zoomTargetPixels = 34.0
    static let zoomCropsPerOrientation = 6
    static let maxCloseUps = 4

    static func read(_ image: CGImage) async throws -> LocalReading {
        var r = LocalReading()
        var seen = Set<String>()
        var mainLines: [String] = [], zoomLines: [String] = []
        var mainAlternates: [String] = [], zoomAlternates: [String] = []
        var passes: [Pass] = []
        func merge(_ pass: Pass, zoomed: Bool) {
            for b in pass.barcodes where !r.barcodes.contains(b) { r.barcodes.append(b) }
            for l in pass.lines where seen.insert(key(l)).inserted {
                if zoomed { zoomLines.append(l) } else { mainLines.append(l) }
            }
            if zoomed { zoomAlternates += pass.alternates } else { mainAlternates += pass.alternates }
        }
        func rank() {
            r.lines = mainLines + zoomLines
            // Zoom-pass tokens come in as alternates: magnified noise reads as "133H5" and "670C.0" often
            // enough that a new token from the zoom must not outrank the full-frame reading. The one
            // case where it should is a re-reading of the same number — "OS 13061" at 3× against the
            // full frame's "OS 13001" — so a zoom token one confusable character from a full-frame
            // token moves in ahead of it.
            let mainOnly = Set(CatalogueNumber.candidates(in: mainLines, alternates: mainAlternates).map(CatalogueNumber.normalize))
            var cands = CatalogueNumber.candidates(in: mainLines, alternates: zoomLines + mainAlternates + zoomAlternates)
            for t in cands where !mainOnly.contains(CatalogueNumber.normalize(t)) {
                guard let at = cands.firstIndex(of: t),
                      let partner = cands[..<at].firstIndex(where: { mainOnly.contains(CatalogueNumber.normalize($0)) && CatalogueNumber.compare(t, $0) == .near }) else { continue }
                cands.remove(at: at)
                cands.insert(t, at: partner)
            }
            r.catalogueCandidates = cands
        }
        for o in orientations {
            let p = try await pass(image, orientation: o, barcodes: o == .up)
            passes.append(p); merge(p, zoomed: false)
        }
        rank()
        if !r.catalogueCandidates.contains(where: { $0.contains(where: \.isLetter) }) {
            for o in fallbackOrientations {
                let p = try await pass(image, orientation: o, barcodes: false)
                passes.append(p); merge(p, zoomed: false)
            }
        }
        // Second pass: crop and magnify the smallest print, read it again.
        var crops: [Crop] = []
        for p in passes { crops += Zoom.crops(for: p, in: image) }
        for c in crops {
            guard let zoomed = Zoom.magnify(image, crop: c) else { continue }
            var z = try await pass(zoomed, orientation: c.orientation, barcodes: false)
            z.lines = z.boxes.filter { $0.confidence >= 0.3 && $0.text.count >= 2 }.map(\.text)
            crops[crops.firstIndex(where: { $0.id == c.id })!].read = z.lines
            crops[crops.firstIndex(where: { $0.id == c.id })!].image = zoomed
            merge(z, zoomed: true)
        }
        r.zoomCrops = crops.count
        rank()
        r.closeUps = Zoom.closeUps(from: crops)
        return r
    }

    private static func key(_ line: String) -> String { line.uppercased().filter { $0.isLetter || $0.isNumber } }

    struct Box: Sendable {
        var text: String
        /// Vision's box: normalised, origin bottom-left, in the frame *as oriented* (upright text).
        var box: CGRect
        var confidence: Float
    }

    struct Pass: Sendable {
        var orientation: CGImagePropertyOrientation = .up
        var barcodes: [String] = []
        var lines: [String] = []
        var boxes: [Box] = []
        /// Vision's second and third readings of catalogue-shaped lines: where it saw "OS 13061"
        /// as "OS 13001", the right one is usually its runner-up.
        var alternates: [String] = []
    }

    private static func pass(_ image: CGImage, orientation: CGImagePropertyOrientation, barcodes: Bool) async throws -> Pass {
        try await withCheckedThrowingContinuation { cont in
            var requests: [VNRequest] = []
            let barcode = VNDetectBarcodesRequest()
            barcode.symbologies = [.ean13, .ean8, .upce, .code128, .code39]
            if barcodes { requests.append(barcode) }
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.recognitionLanguages = ["en-GB", "en-US", "fr-FR", "de-DE"]
            text.minimumTextHeight = minimumTextHeight
            text.revision = VNRecognizeTextRequestRevision3
            requests.append(text)
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform(requests)
                    var p = Pass(orientation: orientation)
                    if barcodes { p.barcodes = (barcode.results ?? []).compactMap { $0.payloadStringValue } }
                    for obs in text.results ?? [] {
                        let cands = obs.topCandidates(3)
                        guard let top = cands.first else { continue }
                        p.lines.append(top.string)
                        p.boxes.append(Box(text: top.string, box: obs.boundingBox, confidence: top.confidence))
                        if top.string.contains(where: \.isNumber), top.string.count <= 24 {
                            p.alternates += cands.dropFirst().map(\.string).filter { $0 != top.string }
                        }
                    }
                    cont.resume(returning: p)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// One region of small print to magnify: pixel rect in the still, plus the orientation whose
    /// pass found it (the crop is read with the same orientation).
    struct Crop: Sendable {
        var id = UUID()
        var rect: CGRect
        var orientation: CGImagePropertyOrientation
        var textHeight: Double
        var hasDigits: Bool
        var read: [String] = []
        var image: CGImage?
    }

    enum Zoom {
        /// Pixel rect in the still for a Vision box found with `orientation`. Vision reports boxes in
        /// the frame as rotated upright, so the rect has to be turned back: for `.right` the still is
        /// rotated 90° clockwise to read, so a box's vertical position becomes the still's x.
        static func pixelRect(_ box: CGRect, orientation: CGImagePropertyOrientation, width: Int, height: Int) -> CGRect {
            // Top-left-origin, normalised, in the oriented frame.
            let tx = box.minX, ty = 1 - box.minY - box.height, w = box.width, h = box.height
            let n: CGRect
            switch orientation {
            case .right: n = CGRect(x: ty, y: 1 - tx - w, width: h, height: w)
            case .left: n = CGRect(x: 1 - ty - h, y: tx, width: h, height: w)
            case .down: n = CGRect(x: 1 - tx - w, y: 1 - ty - h, width: w, height: h)
            default: n = CGRect(x: tx, y: ty, width: w, height: h)
            }
            let W = Double(width), H = Double(height)
            // CGImage.cropping uses a top-left origin, like the rect here.
            return CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)
        }

        /// The small-print regions worth a second look in one pass, padded and merged where they touch.
        static func crops(for pass: Pass, in image: CGImage) -> [Crop] {
            let W = image.width, H = image.height
            var pending: [Crop] = []
            for b in pass.boxes {
                let px = pixelRect(b.box, orientation: pass.orientation, width: W, height: H)
                let textHeight = min(px.width, px.height)
                // Small print with a digit in it, or small print Vision was unsure of (a digit misread
                // as a letter reads as "S3NV"). Confident all-letter lines — credits, publishers — are skipped.
                let small = textHeight < zoomBelowPixels && (b.text.contains(where: \.isNumber) || b.confidence < 0.8)
                let shaky = b.confidence < 0.6 && textHeight < zoomLowConfidenceBelowPixels
                guard small || shaky, textHeight >= 4 else { continue }
                let pad = min(40, max(8, textHeight * 0.8))
                let rect = px.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: W, height: H))
                guard !rect.isNull, rect.width >= 12, rect.height >= 8 else { continue }
                pending.append(Crop(rect: rect, orientation: pass.orientation, textHeight: textHeight, hasDigits: b.text.contains(where: \.isNumber)))
            }
            // Merge overlapping crops so neighbouring lines are read together (context helps Vision too).
            var merged = true
            while merged {
                merged = false
                outer: for i in pending.indices {
                    for j in pending.indices where j > i {
                        if pending[i].rect.intersects(pending[j].rect) {
                            pending[i].rect = pending[i].rect.union(pending[j].rect)
                            pending[i].textHeight = min(pending[i].textHeight, pending[j].textHeight)
                            pending[i].hasDigits = pending[i].hasDigits || pending[j].hasDigits
                            pending.remove(at: j)
                            merged = true
                            break outer
                        }
                    }
                }
            }
            // Digits first, then the smallest print: that is where the catalogue number is.
            pending.sort { a, b in
                if a.hasDigits != b.hasDigits { return a.hasDigits }
                return a.textHeight < b.textHeight
            }
            return Array(pending.prefix(zoomCropsPerOrientation))
        }

        /// The crop magnified so its smallest print is ~`zoomTargetPixels` tall (2–4×).
        static func magnify(_ image: CGImage, crop: Crop) -> CGImage? {
            guard let cropped = image.cropping(to: crop.rect.integral) else { return nil }
            var scale = min(4, max(2, zoomTargetPixels / max(4, crop.textHeight)))
            // Big merged regions do not need 4×; keep the magnified crop under ~2000px.
            scale = min(scale, 2000 / Double(max(cropped.width, cropped.height)))
            guard scale > 1.2 else { return cropped }
            let w = Int(Double(cropped.width) * scale), h = Int(Double(cropped.height) * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }

        /// The crops worth showing the model: ones that read as numbers, smallest print first,
        /// no more than `maxCloseUps`, and never the same region twice.
        static func closeUps(from crops: [Crop]) -> [CGImage] {
            let numeric = crops.filter { c in c.image != nil && (c.hasDigits || c.read.contains { $0.contains(where: \.isNumber) }) }
            let ordered = (numeric.isEmpty ? crops.filter { $0.image != nil } : numeric).sorted { $0.textHeight < $1.textHeight }
            var taken: [CGRect] = []
            var out: [CGImage] = []
            for c in ordered where out.count < maxCloseUps {
                // A region already sent from another orientation's pass shows the model nothing new.
                if taken.contains(where: { $0.intersection(c.rect).area > 0.6 * min($0.area, c.rect.area) }) { continue }
                taken.append(c.rect)
                out.append(c.image!)
            }
            return out
        }
    }
}

private extension CGRect {
    var area: Double { isNull ? 0 : width * height }
}

/// Heuristics for record catalogue numbers: "POSP 113", "CHS TT 17", "FAC 73", "2059 227", "7N 17241", "SRK 6095",
/// and the side-suffixed forms Discogs sometimes catalogues under: "COL 3422-A", "1770 GF", "T 54278 F".
enum CatalogueNumber {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:[A-Z0-9]{1,6}[ .\-]?){0,2}\d{1,7}(?:[ .\-]\d{2,5})?(?:[ \-]?[A-Z]{1,2})?\b"#)
    /// Words that look like catalogue numbers but are printed on every label.
    private static let noise = ["SIDE", "TIME", "STEREO", "MONO", "RPM", "BPM", "VOL", "TRACK", "DISC", "PAGE", "TEL", "BOX"]
    /// Matrix (stamper) prefixes CBS/Columbia/Epic print next to the catalogue number, in the same size type:
    /// "ZSS 175774" sits right under "38-06611" and looks more like a catalogue number than it does.
    private static let matrixPrefixes = ["ZSS", "ZSP", "ZSM", "XSS", "XSM", "XSV", "XSB", "XSP", "ZAL", "ZLP", "XLP"]
    /// A single's label often quotes the album it comes from ("from the LP AFL1-3962"); that number is
    /// catalogue-shaped, findable on Discogs, and wrong.
    private static let albumContext = ["ALBUM", "FROM THE", " LP ", " LP\"", "(LP", "L.P."]
    /// The label's address: "51 W. 52 Street, New York" is a catalogue-shaped "51 W".
    private static let addressContext = ["STREET", " ST.", "AVENUE", " AVE", "BLVD", "N.Y.", "ROAD", "LONDON W", "CALIF"]
    /// Codes printed on every label of a family that are not catalogue numbers: "B-216" is the
    /// Warner Bros. plant/sleeve code and sits next to the real number in the same type.
    private static let knownNoise: Set<String> = ["B216"]
    /// Numeric house styles worth trusting even without a letter prefix: CBS singles "38-06611" / "3-10939",
    /// PolyGram "885 518-7", Polydor/Philips "2059 227" / "6073 039".
    private static let cbsSingle = try! NSRegularExpression(pattern: #"^\d{1,2}[ .\-]\d{5}$"#)
    private static let polygram = try! NSRegularExpression(pattern: #"^\d{3}[ .]\d{3}[ .\-]\d$"#)
    private static let polydor = try! NSRegularExpression(pattern: #"^\d{4}[ .]\d{3}$"#)

    /// `alternates` are Vision's runner-up readings: tried, but after everything it read first time.
    static func candidates(in lines: [String], alternates: [String] = []) -> [String] {
        var seen = Set<String>()
        var out: [(token: String, score: Double)] = []
        for (line, alt) in lines.map({ ($0, false) }) + alternates.map({ ($0, true) }) {
            let u = line.uppercased()
            let ns = u as NSString
            let quotesAlbum = albumContext.contains { (" " + u + " ").contains($0) }
            let isAddress = addressContext.contains { (" " + u + " ").contains($0) }
            for m in pattern.matches(in: u, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                let digits = s.filter(\.isNumber).count
                let letters = s.filter(\.isLetter).count
                // Skip years, RPMs and bare short numbers; prefer letter+digit combos. A bare four-digit
                // number that cannot be a year ("8071", "1004", "4565") is kept, at the bottom of the list.
                if letters == 0 && digits == 4 && (isYear(s) || s.contains(where: { !$0.isNumber })) { continue }
                if letters == 0 && digits < 4 { continue }
                if letters == 0 && digits == 5 && !s.contains("-") { continue }   // "10019": zip codes, not catalogue numbers
                if letters > 0 && digits == 1 && letters < 3 { continue }   // "A1", "B2" side markers
                if noise.contains(where: { s.hasPrefix($0 + " ") || s.hasPrefix($0 + "-") }) { continue }
                if digits > 9 { continue }                                   // barcodes and matrix strings, not catalogue numbers
                if knownNoise.contains(normalize(s)) { continue }
                let penalty = (alt ? 1.5 : 0) + (quotesAlbum ? 2.5 : 0) + (isAddress ? 2.5 : 0)
                if seen.insert(normalize(s)).inserted { out.append((s, shapeScore(s) - penalty)) }
                // "COL 3422-A" is also worth trying as "COL 3422": labels add the side, Discogs often doesn't.
                if let stripped = withoutSideSuffix(s), seen.insert(normalize(stripped)).inserted { out.append((stripped, shapeScore(stripped) - penalty - 0.25)) }
            }
        }
        return ranked(out)
    }

    private static func isYear(_ s: String) -> Bool {
        guard let n = Int(s.filter(\.isNumber)) else { return false }
        return (1900...2035).contains(n)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// How much a token looks like a catalogue number rather than an address, a matrix number or a
    /// mis-read word. Catalogue numbers are a short letter prefix (POSP, CHS TT, 7N, K) and 2–7 digits.
    static func shapeScore(_ s: String) -> Double {
        let letters = s.filter(\.isLetter).count, digits = s.filter(\.isNumber).count
        let groups = s.components(separatedBy: CharacterSet(charactersIn: " .-")).filter { !$0.isEmpty }
        let wordGroups = groups.filter { $0.allSatisfy(\.isLetter) }
        var score = 0.0
        if letters > 0 && digits > 0 { score += 3 }
        if (1...4).contains(letters) { score += 1 }
        if letters >= 6 { score -= 2 }
        if wordGroups.contains(where: { $0.count >= 5 }) { score -= 2 }      // CALIFORNIA, RECORDS, PRODUCED
        if wordGroups.count >= 2 { score -= 2 }                                 // LAND OF 1000, FROM THE 20TH
        if (2...7).contains(digits) { score += 1 }
        if digits >= 8 { score -= 1 }
        if groups.count >= 4 { score -= 1 }                                     // 151-9199-SA-1 matrix strings
        if letters > 0, groups.contains(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) && ($0.hasPrefix("19") || $0.hasPrefix("20")) }) {
            score -= digits == 4 ? 3 : 1                                        // "P1974 T", "1974 20TH": ℗ 1974, nothing else
            if digits == 4 && letters <= 2 { score = min(score, -1) }          // a ℗/© year and nothing else: below even a bare number
        }
        if s.hasPrefix("45 ") || s.hasPrefix("45R") || s.hasPrefix("33 ") { score -= 4 }
        if let first = groups.first, matrixPrefixes.contains(first) { score -= 3 }
        if letters == 0 {
            if matches(cbsSingle, s) || matches(polygram, s) { score += 3 }
            else if matches(polydor, s) { score += 2 }
            else if digits == 6 { score += 1 }                                  // "452348": too long for a year or a zip code
            else if digits == 4 { score -= 1 }                                  // bare "8071": last resort
        }
        return score
    }

    private static func ranked(_ scored: [(token: String, score: Double)]) -> [String] {
        scored.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element.token)
    }

    /// "COL 3422-A" → "COL 3422", "1770 GF" → "1770", "T 54278 F" → "T 54278"; nil when there is no suffix.
    static func withoutSideSuffix(_ s: String) -> String? {
        guard let m = s.range(of: #"[ \-][A-Z]{1,2}$"#, options: .regularExpression) else { return nil }
        let base = String(s[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
        return base.contains(where: \.isNumber) && base.count >= 3 ? base : nil
    }

    /// Normalise for comparison: uppercase, letters and digits only.
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// How two catalogue numbers relate after normalisation.
    enum Match { case exact, near, partial, none }

    /// OCR swaps these for each other on worn print: 0/O/Q/D, 1/I/L, 5/S, 8/B, 2/Z, 7/T, 6/G, and 0/6/8 in small type.
    private static let confusable: [Set<Character>] = [["0", "O", "Q", "D"], ["1", "I", "L"], ["5", "S"], ["8", "B"], ["2", "Z"], ["7", "T"], ["6", "G"], ["0", "6", "8"]]

    /// `exact`: same after normalising. `near`: same length, one confusable character apart (OS 13001 ≈ OS 13061).
    /// `partial`: one is a suffix/prefix/substring of the other with at least 4 characters in common.
    static func compare(_ x: String, _ y: String) -> Match {
        let a = normalize(x), b = normalize(y)
        if a.isEmpty || b.isEmpty { return .none }
        if a == b { return .exact }
        if a.count == b.count, a.count >= 4 {
            let diff = zip(a, b).filter { $0 != $1 }
            if diff.count == 1, let d = diff.first, confusable.contains(where: { $0.contains(d.0) && $0.contains(d.1) }) { return .near }
        }
        if min(a.count, b.count) >= 4 && (a.hasSuffix(b) || b.hasSuffix(a) || a.contains(b) || b.contains(a)) { return .partial }
        return .none
    }
}
