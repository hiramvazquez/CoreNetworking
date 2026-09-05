import Foundation

/// Policy `URLSessionTransport` applies to HTTP redirects (a 3xx response
/// carrying a `Location`), enforced per-task by
/// `TaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`.
///
/// ## Why this exists
///
/// `URLSession` follows redirects AUTOMATICALLY: a 3xx is not an error, so no
/// `catch` anywhere in this package's pipeline (retry, interceptors,
/// `APIService`) ever sees one happen unless something explicitly asks to be
/// told. Left unhandled, that raises a question an enterprise consumer of
/// this package cannot leave unanswered: when the destination changes,
/// does the credential travel with it?
///
/// Measured empirically (`RedirectSecurityTests`, real loopback sockets, no
/// mock `URLProtocol` — a mock never reaches the code path where redirects
/// happen) on the toolchain this package targets:
///
/// - Foundation/CFNetwork silently strips exactly two header names —
///   `Authorization` and `Proxy-Authorization` — from EVERY redirect, same
///   origin included. This is undocumented behavior of the platform's URL
///   loading system, not a contract of the `URLSession` API, and it is why a
///   same-origin redirect that a caller expects to stay authenticated
///   (a load balancer moving a request to a different path on the same API
///   host, the single most common redirect an authenticated API produces)
///   SILENTLY LOSES its credential without this type's intervention — a
///   functional break, not just a security one.
/// - Nothing else is touched. `Cookie`, `X-Api-Key`, `X-Auth-Token`, a
///   custom `Authentication` header — any credential that is not spelled
///   exactly `Authorization`/`Proxy-Authorization` — is forwarded UNCHANGED
///   to the redirect target, cross-origin included. That is the confirmed
///   leak: a backend that authenticates through any header name other than
///   the two Foundation special-cases (extremely common — API keys, bearer
///   tokens under a custom name, a session id sent as a raw header because
///   this package's default session configuration disables the cookie jar,
///   see `NetworkingConfiguration.defaultSessionConfiguration()`) travels to
///   ANY redirect target with zero filtering.
/// - This is Darwin/CFNetwork-specific, undocumented, unversioned behavior.
///   This package also targets Linux (`#if canImport(Glibc)` throughout
///   `Tests/`) where `swift-corelibs-foundation`'s URL loading system is a
///   different implementation that offers no guarantee of matching it. The
///   package cannot depend on an implementation detail of one platform to
///   keep credentials from leaking on another.
///
/// ## The default
///
/// ``followSanitizingCrossOrigin`` — follow the redirect (matches what every
/// existing caller of this package already assumed `URLSession` does), but:
/// - when the destination's origin (scheme, host, or port) differs from the
///   request that started the chain, strip every header this package
///   considers credential-shaped (``sensitiveHeaderNames``) from the request
///   Foundation is about to send — independent of whatever Foundation
///   already did or did not strip itself, so the guarantee holds on any
///   platform.
/// - when the destination is the SAME origin, restore any of those same
///   header names that were present on the original request but are now
///   missing from the redirected one — undoing exactly the platform quirk
///   above, so an authenticated same-origin redirect keeps working.
public enum RedirectPolicy: Sendable, Equatable {
    /// Follow redirects; sanitize headers when the destination's origin
    /// differs from the request that started the chain, restore them when it
    /// does not. THE DEFAULT — see the type's doc comment for the measured
    /// behavior this exists to correct.
    case followSanitizingCrossOrigin

    /// Never follow a redirect: the 3xx response itself (status, headers,
    /// body) is delivered to the caller as the task's final response, as if
    /// it were any other status code. For a caller talking to an endpoint
    /// that must never redirect — surfacing that as an explicit, inspectable
    /// response is preferable to silently following somewhere unplanned.
    case never

    /// Follow every redirect and forward every header unchanged, regardless
    /// of origin — including undoing NOTHING Foundation itself strips. An
    /// explicit opt-out of the sanitizing default, for a caller who has
    /// verified every possible redirect target for a given request is
    /// trusted with its credentials (e.g. a fleet of internal hosts that
    /// share one logical identity). Not the default: a caller must name this
    /// case to get it.
    case followPreservingAllHeaders

    /// Header names this policy treats as credential-shaped, matched
    /// case-insensitively and by EXACT name only.
    ///
    /// Deliberately narrower than `HeaderRedactor`'s list (`Logging.swift`):
    /// that one also matches by substring ("token", "secret", "apikey",
    /// "password" anywhere in the header name) because over-redacting a LOG
    /// is free — a false positive there just prints `<redacted>` for a
    /// harmless header. Over-stripping a REQUEST header is not free: a false
    /// positive here silently drops a header the destination needed for
    /// something other than authentication (e.g. a custom `X-Idempotency-Token`
    /// that identifies a retried write, not a credential) and breaks the
    /// redirected call instead of just a log line. So this list sticks to
    /// header names that are auth-related by convention, unambiguously,
    /// across HTTP/web practice — the same names `HeaderRedactor` matches
    /// exactly, minus the ones that only ever appear on a RESPONSE
    /// (`set-cookie`) and are meaningless on the outgoing request this list
    /// filters.
    ///
    /// This is a second copy of that name set rather than a shared one:
    /// `HeaderRedactor` lives in `Logging.swift`, outside this change's
    /// scope (`Sources/CoreNetworking/Transport/`). A follow-up that extracts
    /// both to one internal type would remove the duplication; until then,
    /// keeping the exact-name subset in sync by inspection is the accepted
    /// cost of not touching a file outside this task's boundary.
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "authentication",
        "cookie",
        "x-api-key",
        "api-key",
        "x-auth-token"
    ]
}
