import Foundation

/// One decoded slot value or array element. Strings stay as byte ranges until a record maps them.
enum SLFValue: Sendable {
    case int(UInt64)
    case double(Double)
    case string(Range<Int>)
    case json(Range<Int>)
    case null
    case array([SLFValue])
    case object(SLFObject)
}

/// A decoded instance, already mapped to the reader-neutral types.
enum SLFObject: Sendable {
    case section(RawSection)
    case message(RawMessage)
    case location(RawLocation)
    case attachment(RawAttachment)
    case opaque
}

/// Slot values of one instance, indexed by `SLFSlotName`.
struct SLFRecord {
    private var values = [SLFValue?](repeating: nil, count: SLFSlotName.allCases.count)

    subscript(name: SLFSlotName) -> SLFValue? {
        get { values[name.rawValue] }
        set { values[name.rawValue] = newValue }
    }
}

extension SLFDecoder {
    /// Seconds from 1970-01-01 to 2001-01-01; SLF doubles are on the 2001 epoch, `RawSection` uses Unix seconds.
    static let appleEpochOffset = 978_307_200.0

    func makeObject(family: SLFSchemaFamily, record: SLFRecord) -> SLFObject {
        switch family {
        case .section: return .section(makeSection(record))
        case .message: return .message(makeMessage(record))
        case .location, .textLocation: return .location(makeLocation(record))
        case .attachment: return .attachment(makeAttachment(record))
        case .consoleItem: return .opaque
        }
    }

    func makeSection(_ r: SLFRecord) -> RawSection {
        let slf = RawSection.SLFOnly(
            wasCancelled: flag(r[.wasCancelled]), isQuiet: flag(r[.isQuiet]),
            wasFetchedFromCache: flag(r[.wasFetchedFromCache]), uniqueIdentifier: string(r[.uniqueIdentifier]),
            xcbuildSignatureHex: string(r[.xcbuildSignature]))
        let start = time(r[.start])
        let end = time(r[.end])
        return RawSection(
            title: string(r[.title]) ?? "", domainType: string(r[.domainType]), sectionType: int(r[.sectionType]),
            signature: string(r[.signature]), commandDetails: string(r[.commandDetails]),
            start: start ?? 0, end: end ?? 0, resultCode: int(r[.resultCode]),
            emittedOutput: string(r[.text]),
            messages: objects(r[.messages]) { if case let .message(m) = $0 { m } else { nil } },
            attachments: objects(r[.attachments]) { if case let .attachment(a) = $0 { a } else { nil } },
            subsections: objects(r[.subsections]) { if case let .section(s) = $0 { s } else { nil } },
            slfOnly: slf, location: location(r[.location]), timingMissing: start == nil || end == nil)
    }

    func makeMessage(_ r: SLFRecord) -> RawMessage {
        RawMessage(
            title: string(r[.title]) ?? "", severity: int(r[.severity]), categoryIdent: string(r[.categoryIdent]),
            location: location(r[.location]),
            submessages: objects(r[.submessages]) { if case let .message(m) = $0 { m } else { nil } })
    }

    /// Line and column numbers are 0-based in SLF; negative values (`UInt64.max`) mean "none".
    func makeLocation(_ r: SLFRecord) -> RawLocation {
        func number(_ value: SLFValue?) -> Int? { int(value).flatMap { $0 >= 0 ? $0 : nil } }
        return RawLocation(file: string(r[.documentURL]), startLine: number(r[.startLine]),
                           startColumn: number(r[.startColumn]), endLine: number(r[.endLine]),
                           endColumn: number(r[.endColumn]), numberBase: 0)
    }

    func makeAttachment(_ r: SLFRecord) -> RawAttachment {
        var data = Data()
        switch r[.data] {
        case let .json(range)?, let .string(range)?: data = cursor.tokenizer.data(range)
        default: break
        }
        return RawAttachment(identifier: string(r[.identifier]) ?? "", majorVersion: int(r[.majorVersion]),
                             minorVersion: int(r[.minorVersion]), data: data)
    }

    // MARK: - Slot accessors

    func string(_ value: SLFValue?) -> String? {
        switch value {
        case let .string(range)?, let .json(range)?: return cursor.tokenizer.string(range)
        default: return nil
        }
    }

    func int(_ value: SLFValue?) -> Int? {
        if case let .int(raw)? = value { return Int(truncatingIfNeeded: raw) }
        return nil
    }

    func flag(_ value: SLFValue?) -> Bool? {
        if case let .int(raw)? = value { return raw != 0 }
        return nil
    }

    /// 2001-epoch seconds -> Unix seconds; nil (never 0) when missing, non-finite or a negative int sentinel.
    func time(_ value: SLFValue?) -> Double? {
        switch value {
        case let .double(seconds)? where seconds.isFinite: return seconds + Self.appleEpochOffset
        case let .int(raw)?:
            let seconds = Int(truncatingIfNeeded: raw)
            return seconds >= 0 ? Double(seconds) + Self.appleEpochOffset : nil
        default: return nil
        }
    }

    func location(_ value: SLFValue?) -> RawLocation? {
        if case let .object(.location(location))? = value { return location }
        return nil
    }

    func objects<T>(_ value: SLFValue?, _ pick: (SLFObject) -> T?) -> [T] {
        guard case let .array(elements)? = value else { return [] }
        return elements.compactMap { element in
            if case let .object(object) = element { return pick(object) }
            return nil
        }
    }
}
