import Foundation

public enum MusiFixError: Error, Sendable {
    case bridgeUnavailable
    case trackNotFound(persistentID: String)
    case writeFailure(persistentID: String, field: String, underlying: String)
    case readBackMismatch(persistentID: String, field: String, expected: String, actual: String)
    case artworkWriteFailure(persistentID: String, underlying: String)
    case appleScriptError(String)
    case unexpectedNilValue(context: String)
}

extension MusiFixError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "AppleMusicBridge non disponibile"
        case .trackNotFound(let id):
            return "Track non trovato: \(id)"
        case .writeFailure(let id, let field, let err):
            return "Scrittura fallita su \(field) per track \(id): \(err)"
        case .readBackMismatch(let id, let field, let expected, let actual):
            return "Read-back mismatch su \(field) per \(id): atteso «\(expected)», trovato «\(actual)»"
        case .artworkWriteFailure(let id, let err):
            return "Scrittura artwork fallita per \(id): \(err)"
        case .appleScriptError(let msg):
            return "Errore AppleScript: \(msg)"
        case .unexpectedNilValue(let ctx):
            return "Valore nil inatteso: \(ctx)"
        }
    }
}
