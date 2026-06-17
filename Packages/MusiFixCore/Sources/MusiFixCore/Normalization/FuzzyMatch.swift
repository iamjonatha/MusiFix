import Foundation

/// Metriche di similarità stringa per dedup e normalizzazione.
public enum FuzzyMatch {

    // ── Jaro-Winkler ─────────────────────────────────────────────────────────

    /// Similarità Jaro-Winkler tra due stringhe (0…1).
    /// Ottima per titoli brevi, sensibile all'ordine dei caratteri.
    public static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1), b = Array(s2)
        let la = a.count, lb = b.count
        guard la > 0, lb > 0 else { return la == lb ? 1.0 : 0.0 }
        if a == b { return 1.0 }

        let matchWindow = max(0, max(la, lb) / 2 - 1)
        var matchedA = [Bool](repeating: false, count: la)
        var matchedB = [Bool](repeating: false, count: lb)
        var matches = 0

        for i in 0..<la {
            let lo = max(0, i - matchWindow)
            let hi = min(i + matchWindow + 1, lb)
            guard lo < hi else { continue }
            for j in lo..<hi where !matchedB[j] && a[i] == b[j] {
                matchedA[i] = true; matchedB[j] = true; matches += 1; break
            }
        }
        guard matches > 0 else { return 0.0 }

        var transpositions = 0
        var k = 0
        for i in 0..<la where matchedA[i] {
            while !matchedB[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let jaro = (m / Double(la) + m / Double(lb) + (m - Double(transpositions) / 2) / m) / 3

        // Winkler prefix bonus (p = 0.1, max 4 chars)
        var prefix = 0
        for i in 0..<min(4, min(la, lb)) where a[i] == b[i] { prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    // ── Token-set ratio ───────────────────────────────────────────────────────

    /// Token-set similarity: invariante all'ordine delle parole (0…1).
    /// Buona per titoli con parole extra ("Remastered", feat., etc.).
    public static func tokenSetRatio(_ s1: String, _ s2: String) -> Double {
        let t1 = tokens(s1), t2 = tokens(s2)
        guard !t1.isEmpty, !t2.isEmpty else { return t1 == t2 ? 1.0 : 0.0 }

        let intersection = t1.intersection(t2)
        let sorted1 = intersection.sorted().joined(separator: " ")
        let rest1    = t1.subtracting(t2).sorted().joined(separator: " ")
        let rest2    = t2.subtracting(t1).sorted().joined(separator: " ")

        let s12  = [sorted1, rest1].filter { !$0.isEmpty }.joined(separator: " ")
        let s22  = [sorted1, rest2].filter { !$0.isEmpty }.joined(separator: " ")

        let scores = [
            jaroWinkler(sorted1, s12),
            jaroWinkler(sorted1, s22),
            jaroWinkler(s12, s22),
        ]
        return scores.max() ?? 0
    }

    /// Combined: massimo tra Jaro-Winkler e token-set ratio.
    public static func similarity(_ s1: String, _ s2: String) -> Double {
        max(jaroWinkler(s1, s2), tokenSetRatio(s1, s2))
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { $0.count > 1 })
    }
}
