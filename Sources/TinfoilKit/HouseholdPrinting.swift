import CoreGraphics
import CoreLocation
import CoreText
import Foundation
import PDFKit
import ZIMArchive

enum HouseholdPrinting {
    struct Reference: Identifiable, Sendable {
        struct Source: Sendable {
            let archive: String
            let path: String
        }

        let id: String
        let title: String
        let document: String
        let pages: ClosedRange<Int>
        let sources: [Source]
    }

    struct InstalledSource: Sendable {
        let archive: String
        let file: URL
        let attribution: String
    }

    struct AvailableReference: Identifiable, Sendable {
        let reference: Reference
        let file: URL
        let path: String
        let attribution: String

        var id: String { reference.id }

        func printablePDF() throws -> Data {
            let original = try Self.openPDF(file: file, path: path, pages: reference.pages)
            let excerpt = PDFDocument()
            excerpt.documentAttributes = original.documentAttributes
            for pageNumber in reference.pages {
                try Task.checkCancellation()
                guard let copy = original.page(at: pageNumber - 1)?.copy() as? PDFPage else {
                    throw PrintError.unreadableReference
                }
                excerpt.insert(copy, at: excerpt.pageCount)
            }
            guard let data = excerpt.dataRepresentation() else { throw PrintError.unreadableReference }
            return data
        }

        static func openPDF(file: URL, path: String, pages: ClosedRange<Int>) throws -> PDFDocument {
            let archive = try ZIMArchive(fileURL: file)
            let resource = try archive.resource(at: path)
            guard resource.mimeType == "application/pdf",
                  let pdf = PDFDocument(data: resource.data), !pdf.isLocked, pdf.allowsPrinting,
                  pages.lowerBound > 0, pdf.pageCount >= pages.upperBound else {
                throw PrintError.unreadableReference
            }
            return pdf
        }
    }

    // Page numbers match the editions checked in the desktop kit's printable reference list.
    // Each ZIM filename identifies an edition. New editions need their page numbers checked.
    private static let noDoctor = [
        Reference.Source(archive: "zimgit-medicine_en_2024-08.zim", path: "files/First Aid and Medicine (11).pdf"),
        Reference.Source(archive: "zimgit-post-disaster_en_2024-05.zim", path: "files/First Aid and Medicine (11).pdf")
    ]

    private static let references = [
        Reference(id: "water", title: "Safe drinking water",
                  document: "Purifying Water During an Emergency · Washington State Department of Health", pages: 1...2,
                  sources: [
                    .init(archive: "zimgit-water_en_2024-08.zim", path: "files/Water (2).pdf"),
                    .init(archive: "zimgit-post-disaster_en_2024-05.zim", path: "files/Water (2).pdf")
                  ]),
        Reference(id: "first-aid", title: "Emergency first aid", document: "Where There Is No Doctor",
                  pages: 124...129, sources: noDoctor),
        Reference(id: "rehydration", title: "Diarrhea and dehydration", document: "Where There Is No Doctor",
                  pages: 198...199, sources: noDoctor),
        Reference(id: "power", title: "Power outages", document: "Be Prepared for a Power Outage · Ready.gov", pages: 1...2,
                  sources: [
                    .init(archive: "ready.gov_en_all_2026-10.zim",
                          path: "www.ready.gov/sites/default/files/2024-08/ready.gov_power-outage_info-sheet.pdf"),
                    .init(archive: "ready.gov_en_all_2026-10.zim",
                          path: "www.ready.gov/sites/default/files/2024-03/ready.gov_power-outage_hazard-info-sheet.pdf")
                  ]),
        Reference(id: "injuries", title: "Burns and broken bones", document: "Where There Is No Doctor",
                  pages: 143...147, sources: noDoctor),
        Reference(id: "bleeding", title: "Tourniquets for severe bleeding", document: "First Aid · U.S. Army FM 4-25.11",
                  pages: 45...49, sources: [
                    .init(archive: "zimgit-medicine_en_2024-08.zim", path: "files/First Aid and Medicine (3).pdf"),
                    .init(archive: "irp.fas.org_en_military-medicine_2026-10.zim",
                          path: "irp.fas.org/doddir/milmed/first.pdf"),
                    .init(archive: "zimgit-post-disaster_en_2024-05.zim", path: "files/First Aid and Medicine (3).pdf")
                  ])
    ]

    static func installedReferences(library: InstalledLibrary = .standard) async throws -> [AvailableReference] {
        var installed: [InstalledSource] = []
        for entry in try await library.archives() {
            guard let pack = entry.pack else { continue }
            let file = await library.fileURL(for: entry.id)
            installed.append(InstalledSource(
                archive: pack.source.lastPathComponent, file: file, attribution: pack.attribution
            ))
        }
        let task = Task.detached(priority: .userInitiated) { try availableReferences(in: installed) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func availableReferences(in installed: [InstalledSource]) throws -> [AvailableReference] {
        struct Candidate: Hashable {
            let file: URL
            let path: String
        }

        // Multiple references can be excerpts of the same PDF.
        var pageCounts: [Candidate: Int] = [:]
        return try references.compactMap { reference in
            try Task.checkCancellation()
            for source in reference.sources {
                for edition in installed where edition.archive == source.archive {
                    let candidate = Candidate(file: edition.file, path: source.path)
                    if pageCounts[candidate] == nil {
                        pageCounts[candidate] = (try? AvailableReference.openPDF(
                            file: edition.file, path: source.path, pages: 1...1
                        ).pageCount) ?? 0
                    }
                    if let count = pageCounts[candidate], count >= reference.pages.upperBound {
                        return AvailableReference(
                            reference: reference, file: edition.file, path: source.path, attribution: edition.attribution
                        )
                    }
                }
            }
            return nil
        }
    }

    static func householdPDF(for snapshot: HouseholdSnapshot) async throws -> Data {
        let region = try? await RegionalPlaceStorage().current()
        let task = Task.detached(priority: .userInitiated) { try householdPDF(for: snapshot, region: region) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func householdPDF(for snapshot: HouseholdSnapshot, region: RegionalPlaceStorage.Installed?,
                             date: Date = .now) throws -> Data {
        let body = NSMutableAttributedString(string: "")
        appendHeading("Home", to: body)
        if let home = snapshot.home {
            append(home.name, to: body)
            append(details(for: home), to: body)
            if !home.note.isEmpty { append(home.note, to: body) }
        } else {
            append("Name and coordinates  _________________________________________________", to: body)
        }

        if !snapshot.pins.isEmpty {
            appendHeading("Map pins", to: body)
            for pin in snapshot.pins {
                try Task.checkCancellation()
                append(pin.name, to: body, font: "Helvetica-Bold")
                if !pin.note.isEmpty { append(pin.note, to: body) }
                var location = details(for: pin)
                if let home = snapshot.home {
                    location += " · \(distance(from: home.coordinate, to: pin.coordinate)) from home"
                }
                append(location, to: body)
            }
        }

        if let home = snapshot.home, let region, region.metadata.bounds?.contains(home.coordinate) != false {
            try appendServices(near: home.coordinate, region: region, to: body)
        }

        appendHeading("Notes", to: body)
        let notes = snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            for prompt in ["Household members", "Allergies and medications", "Doctor and pharmacy", "Meeting place",
                           "Out-of-area contact", "Water, gas and power shutoffs"] {
                append(prompt, to: body)
                append("______________________________________________________________________\n", to: body)
            }
        } else {
            append(notes, to: body)
        }
        return try render(body: body, date: date)
    }

    private static func appendServices(near home: CLLocationCoordinate2D, region: RegionalPlaceStorage.Installed,
                                       to body: NSMutableAttributedString) throws {
        let categories: [(RegionalPlaceIndex.Category, String)] = [
            (.hospital, "Hospitals"), (.urgentCare, "Urgent care"), (.pharmacy, "Pharmacies"),
            (.fireStation, "Fire stations"), (.police, "Police stations")
        ]
        var addedHeading = false
        for (category, title) in categories {
            try Task.checkCancellation()
            guard let nearby = try? region.index.nearest(category, to: home, limit: 2), !nearby.isEmpty else { continue }
            if !addedHeading {
                appendHeading("Nearby services · straight-line distance", to: body)
                addedHeading = true
            }
            append(title, to: body, font: "Helvetica-Bold")
            for result in nearby {
                let place = result.place
                let address = place.address.isEmpty ? "" : ", \(place.address)"
                let distance = formatDistance(result.distanceMeters)
                let direction = direction(from: home, to: place.coordinate)
                append("\(place.name)\(address) · \(distance) \(direction)", to: body)
            }
        }
        if addedHeading {
            append("\(region.metadata.attribution) · \(region.metadata.license)", to: body, size: 9)
        }
        try Task.checkCancellation()
    }

    private static func details(for place: HouseholdPlace) -> String {
        "\(place.coordinateText) · \(MapCoordinateText.degreesMinutesSeconds(place.coordinate))"
    }

    private static func distance(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> String {
        formatDistance(CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)))
    }

    private static func formatDistance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func direction(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> String {
        let radians = Double.pi / 180
        let start = origin.latitude * radians
        let end = target.latitude * radians
        let delta = (target.longitude - origin.longitude) * radians
        let angle = atan2(sin(delta) * cos(end), cos(start) * sin(end) - sin(start) * cos(end) * cos(delta))
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return directions[(Int((angle / (.pi / 4)).rounded()) + 8) % 8]
    }

    private static func appendHeading(_ text: String, to body: NSMutableAttributedString) {
        if body.length > 0 { append("", to: body, size: 7) }
        append(text, to: body, font: "Helvetica-Bold", size: 13)
    }

    private static func append(_ text: String, to body: NSMutableAttributedString,
                               font: String = "Helvetica", size: CGFloat = 11) {
        body.append(attributed(text + "\n", font: font, size: size))
    }

    private static func attributed(_ text: String, font: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
    }

    private static func render(body: NSAttributedString, date: Date) throws -> Data {
        let data = NSMutableData()
        var letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &letter, [
                kCGPDFContextTitle as String: "Tinfoil Kit household essentials"
              ] as CFDictionary) else { throw PrintError.renderingFailed }

        let setter = CTFramesetterCreateWithAttributedString(body)
        let path = CGPath(rect: CGRect(x: 44, y: 48, width: 524, height: 655), transform: nil)
        let header = CTLineCreateWithAttributedString(attributed(
            "Household essentials", font: "Helvetica-Bold", size: 24
        ))
        let subtitle = CTLineCreateWithAttributedString(attributed(
            "Tinfoil Kit · \(date.formatted(date: .long, time: .omitted))", font: "Helvetica", size: 10
        ))

        var index = 0
        var page = 1
        while index < body.length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: index, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw PrintError.renderingFailed }

            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 44, y: 741)
            CTLineDraw(header, context)
            context.textPosition = CGPoint(x: 44, y: 722)
            CTLineDraw(subtitle, context)
            CTFrameDraw(frame, context)
            let footer = CTLineCreateWithAttributedString(attributed(
                "Tinfoil Kit · Household essentials · \(page)", font: "Helvetica", size: 9
            ))
            context.textPosition = CGPoint(x: 44, y: 33)
            CTLineDraw(footer, context)
            context.endPDFPage()

            index = visible.location + visible.length
            page += 1
        }
        context.closePDF()
        return data as Data
    }

    private enum PrintError: LocalizedError {
        case unreadableReference
        case renderingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableReference: "This reference could not be opened from the installed pack."
            case .renderingFailed: "The household PDF could not be created."
            }
        }
    }
}
