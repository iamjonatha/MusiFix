import Foundation

/// Estrae gli artisti "featuring" da titolo e campo artista di un brano.
///
/// Volutamente conservativo: riconosce solo marcatori espliciti di collaborazione
/// (`feat.`, `ft.`, `featuring`, `con`, `vs`, `versus`) per non spezzare nomi
/// d'artista che contengono legittimamente `&` o `,` (es. "Simon & Garfunkel",
/// "Earth, Wind & Fire"). L'artista primario resta quello del campo `artist`
/// (o `albumArtist`), il conteggio "artisti presenti" li somma a parte.
public enum FeaturingParser {

    /// Marcatori che introducono uno o più artisti ospiti, in ordine di specificità.
    /// La ricerca è case-insensitive e delimitata da confini di parola dove sensato.
    private static let markers = [
        "featuring", "feat.", "feat ", "ft.", "ft ", " with ", " con ", " vs. ", " vs ", " versus "
    ]

    /// Restituisce i nomi degli artisti ospiti trovati in `title` e `artist`,
    /// normalizzati (trim, senza parentesi di chiusura), de-duplicati e non vuoti.
    public static func featuredArtists(title: String, artist: String) -> [String] {
        var found: [String] = []
        for source in [title, artist] {
            found.append(contentsOf: extract(from: source))
        }
        // De-dup case-insensitive preservando la prima grafia incontrata.
        var seen = Set<String>()
        var result: [String] = []
        for name in found {
            let key = name.lowercased()
            if !name.isEmpty, !seen.contains(key) {
                seen.insert(key)
                result.append(name)
            }
        }
        return result
    }

    /// Cerca il primo marcatore nella stringa e tratta tutto ciò che segue come
    /// elenco di ospiti, separati da `,`, `&`, `x`, `+`, `e`.
    private static func extract(from text: String) -> [String] {
        let lower = text.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            var tail = String(text[range.upperBound...])
            // Rimuovi eventuale parentesi/chiusura del blocco "(feat. …)".
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
            if let close = tail.firstIndex(where: { $0 == ")" || $0 == "]" }) {
                tail = String(tail[..<close])
            }
            return splitCollaborators(tail)
        }
        return []
    }

    /// Divide un elenco di ospiti su separatori comuni.
    private static func splitCollaborators(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",&+")
        return text
            .components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " x ") }
            .flatMap { $0.components(separatedBy: " e ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
