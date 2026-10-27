import Testing
@testable import VoiceDiary

// Attendee facts that feed the opener rules: how many attendees, which one
// the opener names, and whether anyone is outside the organizer's domain.
// These pin the current heuristics as-is; emails are compared verbatim, not
// validated or normalized.

private func person(_ name: String, _ email: String) -> ServerAttendee {
    ServerAttendee(name: name, email: email)
}

private func event(organizer: ServerAttendee, attendees: [ServerAttendee]) -> ServerCalendarEvent {
    ServerCalendarEvent(
        graph_event_id: "evt-1", subject: "Sync", start: "2026-10-15T10:00:00+02:00",
        end: "2026-10-15T10:30:00+02:00", is_all_day: false, show_as: "busy",
        rsvp_status: "accepted", organizer: organizer, attendees: attendees,
        body_preview: "", is_recurring: false, web_link: ""
    )
}

private let organizer = person("Olga", "olga@example.com")

@Suite("ServerCalendarEvent attendeeCount")
struct ServerCalendarEventAttendeeCountTests {
    @Test("no attendees counts zero")
    func empty() {
        #expect(event(organizer: organizer, attendees: []).attendeeCount == 0)
    }

    @Test("counts every listed attendee, including the organizer's own entry")
    func countsAll() {
        let attendees = [person("Olga", "olga@example.com"), person("Ben", "ben@example.com"), person("Ben", "ben@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).attendeeCount == 3)
    }
}

@Suite("ServerCalendarEvent primaryAttendeeName")
struct ServerCalendarEventPrimaryAttendeeNameTests {
    @Test("the first attendee with a different email from the organizer wins")
    func firstNonOrganizer() {
        let attendees = [person("Ben", "ben@example.com"), person("Cara", "cara@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "Ben")
    }

    @Test("the organizer's own entry is skipped even when listed first")
    func skipsOrganizerEntry() {
        let attendees = [person("Olga", "olga@example.com"), person("Ben", "ben@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "Ben")
    }

    @Test("reordering the attendees changes the selection")
    func orderMatters() {
        let ben = person("Ben", "ben@example.com")
        let cara = person("Cara", "cara@example.com")
        #expect(event(organizer: organizer, attendees: [ben, cara]).primaryAttendeeName == "Ben")
        #expect(event(organizer: organizer, attendees: [cara, ben]).primaryAttendeeName == "Cara")
    }

    @Test("when every attendee shares the organizer's email the first attendee's name is used")
    func fallsBackToFirstAttendee() {
        let attendees = [person("Olga (work)", "olga@example.com"), person("Olga (home)", "olga@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "Olga (work)")
    }

    @Test("with no attendees the organizer's name is used")
    func fallsBackToOrganizer() {
        #expect(event(organizer: organizer, attendees: []).primaryAttendeeName == "Olga")
    }

    @Test("an empty selected name is preserved rather than skipped")
    func emptyNamePreserved() {
        let attendees = [person("", "ben@example.com"), person("Cara", "cara@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "")
    }

    @Test("an empty first-attendee fallback name is preserved over the organizer's name")
    func emptyFallbackNamePreserved() {
        let attendees = [person("", "olga@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "")
    }

    @Test("an empty organizer name is returned when there are no attendees")
    func emptyOrganizerName() {
        let nameless = person("", "olga@example.com")
        #expect(event(organizer: nameless, attendees: []).primaryAttendeeName == "")
    }

    @Test("emails are compared case-sensitively, so a differently cased organizer email is selected")
    func caseSensitiveEmail() {
        let attendees = [person("Olga (alias)", "Olga@Example.com"), person("Ben", "ben@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).primaryAttendeeName == "Olga (alias)")
    }
}

@Suite("ServerCalendarEvent hasExternalAttendee")
struct ServerCalendarEventHasExternalAttendeeTests {
    @Test("no attendees is not external")
    func noAttendees() {
        #expect(event(organizer: organizer, attendees: []).hasExternalAttendee == false)
    }

    @Test("attendees on the organizer's domain are not external")
    func sameDomain() {
        let attendees = [person("Ben", "ben@example.com"), person("Cara", "cara@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == false)
    }

    @Test("an attendee on a different domain is external")
    func differentDomain() {
        let attendees = [person("Dan", "dan@other.org")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == true)
    }

    @Test("one external attendee among internal ones, in any position, is enough")
    func mixedDomains() {
        let internalA = person("Ben", "ben@example.com")
        let internalB = person("Cara", "cara@example.com")
        let external = person("Dan", "dan@other.org")
        #expect(event(organizer: organizer, attendees: [internalA, internalB, external]).hasExternalAttendee == true)
        #expect(event(organizer: organizer, attendees: [external, internalA, internalB]).hasExternalAttendee == true)
    }

    @Test("a subdomain is a different domain")
    func subdomainIsExternal() {
        let attendees = [person("Eve", "eve@mail.example.com")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == true)
    }

    @Test("an empty organizer email is never external, whoever attends")
    func emptyOrganizerDomain() {
        let nameless = person("Olga", "")
        let attendees = [person("Dan", "dan@other.org")]
        #expect(event(organizer: nameless, attendees: attendees).hasExternalAttendee == false)
    }

    @Test("attendees without an email are ignored")
    func emptyAttendeeEmail() {
        let attendees = [person("Ghost", ""), person("Ben", "ben@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == false)
    }

    @Test("domains are compared case-sensitively")
    func caseSensitiveDomain() {
        let attendees = [person("Ben", "ben@EXAMPLE.com")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == true)
        let upperOrganizer = person("Olga", "olga@EXAMPLE.com")
        #expect(event(organizer: upperOrganizer, attendees: [person("Ben", "ben@example.com")]).hasExternalAttendee == true)
    }

    @Test("the local part never counts, only what follows the last @")
    func localPartIgnored() {
        let attendees = [person("Ben", "someone-else@example.com")]
        #expect(event(organizer: organizer, attendees: attendees).hasExternalAttendee == false)
    }
}
