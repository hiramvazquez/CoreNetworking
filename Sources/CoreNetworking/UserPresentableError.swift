
import Foundation

/// Protocol for errors that can expose user‑friendly messages.
/// Replaces external dependency previously provided by other packages.
public protocol UserPresentableError: Error {
    var message: String { get }
}
