import Foundation

// Manifest schema mirrors `server/webapp/models.py` and SPEC §10.3.
// Encoded as JSON and posted as one part of the multipart bundle.

public struct AudioCodec: Codable, Sendable {
    public var codec: String = "aac-lc"
    public var sample_rate: Int = 16_000
    public var channels: Int = 1
    public var bitrate: Int = 64_000

    public init(
        codec: String = "aac-lc",
        sample_rate: Int = 16_000,
        channels: Int = 1,
        bitrate: Int = 64_000
    ) {
        self.codec = codec
        self.sample_rate = sample_rate
        self.channels = channels
        self.bitrate = bitrate
    }
}

public struct CalendarRef: Codable, Sendable {
    public var graph_event_id: String
    public var title: String
    public var start: String
    public var end: String
    public var attendees: [String]
    public var rsvp_status: String

    public init(
        graph_event_id: String,
        title: String,
        start: String,
        end: String,
        attendees: [String] = [],
        rsvp_status: String = "accepted"
    ) {
        self.graph_event_id = graph_event_id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.rsvp_status = rsvp_status
    }
}

public struct Todo: Codable, Sendable {
    public var text: String
    public var type: String
    public var due: String?
    public var status: String
    public var source_segment_id: String?

    public init(
        text: String,
        type: String = "explicit",
        due: String? = nil,
        status: String = "Offen",
        source_segment_id: String? = nil
    ) {
        self.text = text
        self.type = type
        self.due = due
        self.status = status
        self.source_segment_id = source_segment_id
    }
}

public struct TodoRejected: Codable, Sendable {
    public var text: String
    public var type: String = "implicit"
    public var source_segment_id: String?

    public init(text: String, source_segment_id: String? = nil) {
        self.text = text
        self.source_segment_id = source_segment_id
    }
}

public struct AiPrompt: Codable, Sendable {
    public var at: String
    public var segment_id: String?
    public var role: String
    public var text: String?

    public init(at: String, role: String, segment_id: String? = nil, text: String? = nil) {
        self.at = at
        self.role = role
        self.segment_id = segment_id
        self.text = text
    }
}

public struct TimeRange: Codable, Sendable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public enum Segment: Codable, Sendable {
    case calendarEvent(CalendarEventSegment)
    case driveBy(DriveBySegment)
    case freeReflection(FreeReflectionSegment)
    case emptyBlock(EmptyBlockSegment)

    private enum CodingKeys: String, CodingKey { case segment_type }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .segment_type)
        let single = try decoder.singleValueContainer()
        switch kind {
        case "calendar_event": self = .calendarEvent(try single.decode(CalendarEventSegment.self))
        case "drive_by":       self = .driveBy(try single.decode(DriveBySegment.self))
        case "free_reflection": self = .freeReflection(try single.decode(FreeReflectionSegment.self))
        case "empty_block":    self = .emptyBlock(try single.decode(EmptyBlockSegment.self))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .segment_type,
                in: try decoder.container(keyedBy: CodingKeys.self),
                debugDescription: "unknown segment_type \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .calendarEvent(let v):  try single.encode(v)
        case .driveBy(let v):        try single.encode(v)
        case .freeReflection(let v): try single.encode(v)
        case .emptyBlock(let v):     try single.encode(v)
        }
    }

    public var audioFile: String {
        switch self {
        case .calendarEvent(let v): return v.audio_file
        case .driveBy(let v):       return v.audio_file
        case .freeReflection(let v): return v.audio_file
        case .emptyBlock(let v):    return v.audio_file
        }
    }
}

public struct CalendarEventSegment: Codable, Sendable {
    public let segment_type: String = "calendar_event"
    public var segment_id: String
    public var calendar_ref: CalendarRef
    public var audio_file: String
    public var transcript: String
    public var language: String
    public var todos_detected: [Todo]
    public var linked_seed_ids: [String]

    public init(
        segment_id: String,
        calendar_ref: CalendarRef,
        audio_file: String,
        transcript: String = "",
        language: String = "de-DE",
        todos_detected: [Todo] = [],
        linked_seed_ids: [String] = []
    ) {
        self.segment_id = segment_id
        self.calendar_ref = calendar_ref
        self.audio_file = audio_file
        self.transcript = transcript
        self.language = language
        self.todos_detected = todos_detected
        self.linked_seed_ids = linked_seed_ids
    }
}

public struct DriveBySegment: Codable, Sendable {
    public let segment_type: String = "drive_by"
    public var segment_id: String
    public var captured_at: String
    public var audio_file: String
    public var transcript: String
    public var language: String
    public var linked_calendar_event_id: String?
    public var seed_id: String?

    public init(
        segment_id: String,
        captured_at: String,
        audio_file: String,
        transcript: String = "",
        language: String = "de-DE",
        linked_calendar_event_id: String? = nil,
        seed_id: String? = nil
    ) {
        self.segment_id = segment_id
        self.captured_at = captured_at
        self.audio_file = audio_file
        self.transcript = transcript
        self.language = language
        self.linked_calendar_event_id = linked_calendar_event_id
        self.seed_id = seed_id
    }
}

public struct FreeReflectionSegment: Codable, Sendable {
    public let segment_type: String = "free_reflection"
    public var segment_id: String
    public var captured_at: String?
    public var audio_file: String
    public var transcript: String
    public var language: String

    public init(
        segment_id: String,
        audio_file: String,
        transcript: String = "",
        language: String = "de-DE",
        captured_at: String? = nil
    ) {
        self.segment_id = segment_id
        self.captured_at = captured_at
        self.audio_file = audio_file
        self.transcript = transcript
        self.language = language
    }
}

public struct EmptyBlockSegment: Codable, Sendable {
    public let segment_type: String = "empty_block"
    public var segment_id: String
    public var time_range: TimeRange
    public var audio_file: String
    public var transcript: String
    public var language: String

    public init(
        segment_id: String,
        time_range: TimeRange,
        audio_file: String,
        transcript: String = "",
        language: String = "de-DE"
    ) {
        self.segment_id = segment_id
        self.time_range = time_range
        self.audio_file = audio_file
        self.transcript = transcript
        self.language = language
    }
}

public struct Manifest: Codable, Sendable {
    public var session_id: String
    public var date: String  // YYYY-MM-DD
    public var device: String
    public var app_version: String
    public var locale_primary: String
    public var audio_codec: AudioCodec
    public var segments: [Segment]
    public var todos_implicit_confirmed: [Todo]
    public var todos_implicit_rejected: [TodoRejected]
    public var drive_by_seeds_unsurfaced: [String]  // placeholder; refine in M10
    public var raw_session_audio: String?
    public var ai_prompts: [AiPrompt]
    public var response_language_setting: String  // "match_input" | "de" | "en"

    public init(
        session_id: String,
        date: String,
        device: String = "iphone-17-pro",
        app_version: String = "0.1.0",
        locale_primary: String = "de-DE",
        audio_codec: AudioCodec = .init(),
        segments: [Segment] = [],
        todos_implicit_confirmed: [Todo] = [],
        todos_implicit_rejected: [TodoRejected] = [],
        drive_by_seeds_unsurfaced: [String] = [],
        raw_session_audio: String? = nil,
        ai_prompts: [AiPrompt] = [],
        response_language_setting: String = "match_input"
    ) {
        self.session_id = session_id
        self.date = date
        self.device = device
        self.app_version = app_version
        self.locale_primary = locale_primary
        self.audio_codec = audio_codec
        self.segments = segments
        self.todos_implicit_confirmed = todos_implicit_confirmed
        self.todos_implicit_rejected = todos_implicit_rejected
        self.drive_by_seeds_unsurfaced = drive_by_seeds_unsurfaced
        self.raw_session_audio = raw_session_audio
        self.ai_prompts = ai_prompts
        self.response_language_setting = response_language_setting
    }
}

public struct SegmentUploadResult: Codable, Sendable {
    public let segment_id: String
    public let status: String
    public let transcript_id: Int?
    public let error: String?
}

public struct SessionAccepted: Codable, Sendable {
    public let status: String
    public let session_id: String
    public let received_at: String
    public let processing_status_url: String
    public let segments: [SegmentUploadResult]
}
