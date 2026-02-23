import Foundation

/// Result of a successful fuzzy match, containing the score and the indices
/// of matched characters in the candidate string.
struct FuzzyMatchResult {
    let score: Int
    let matchedIndices: [Int]
}

/// Fuzzy-match a query against a candidate string.
///
/// Every character in `query` must appear (case-insensitively) in `candidate`
/// in order. Returns `nil` when there is no match, or a `FuzzyMatchResult`
/// with a score and the character indices that matched.
///
/// Scoring heuristics (higher is better):
/// 1. **Consecutive bonus** — adjacent matched characters score higher.
/// 2. **Word-boundary bonus** — matching at the start of a word scores higher.
/// 3. **Prefix bonus** — matching from the very start of the string scores higher.
func fuzzyMatch(query: String, candidate: String) -> FuzzyMatchResult? {
    guard !query.isEmpty else {
        // Empty query matches everything with a neutral score
        return FuzzyMatchResult(score: 0, matchedIndices: [])
    }
    guard !candidate.isEmpty else { return nil }

    let queryChars = Array(query.lowercased())
    let candidateChars = Array(candidate.lowercased())
    let candidateOriginal = Array(candidate)

    // First, verify the candidate contains all query characters in order
    var checkIdx = 0
    for qc in queryChars {
        var found = false
        while checkIdx < candidateChars.count {
            if candidateChars[checkIdx] == qc {
                found = true
                checkIdx += 1
                break
            }
            checkIdx += 1
        }
        if !found { return nil }
    }

    // Now find the best match using a recursive approach with memoization.
    // For command palette scale (tens of items, short strings) this is fine.
    var bestScore = Int.min
    var bestIndices: [Int] = []

    func search(qIdx: Int, cIdx: Int, currentIndices: [Int], currentScore: Int) {
        if qIdx == queryChars.count {
            // All query chars matched
            if currentScore > bestScore {
                bestScore = currentScore
                bestIndices = currentIndices
            }
            return
        }

        let qChar = queryChars[qIdx]
        var idx = cIdx
        while idx < candidateChars.count {
            if candidateChars[idx] == qChar {
                var bonus = 0

                // Consecutive bonus: if this match is right after the previous one
                if let lastIdx = currentIndices.last, idx == lastIdx + 1 {
                    bonus += 8
                }

                // Word-boundary bonus: match at start of a word
                if idx == 0 {
                    bonus += 10 // prefix bonus (start of string)
                } else {
                    let prevChar = candidateOriginal[idx - 1]
                    if prevChar == " " || prevChar == "-" || prevChar == "_" || prevChar == "/" {
                        bonus += 6 // word boundary
                    } else if prevChar.isLowercase && candidateOriginal[idx].isUppercase {
                        bonus += 6 // camelCase boundary
                    }
                }

                // Base score for a match
                bonus += 1

                var newIndices = currentIndices
                newIndices.append(idx)
                search(qIdx: qIdx + 1, cIdx: idx + 1, currentIndices: newIndices, currentScore: currentScore + bonus)
            }
            idx += 1
        }
    }

    search(qIdx: 0, cIdx: 0, currentIndices: [], currentScore: 0)

    if bestScore == Int.min {
        return nil
    }

    return FuzzyMatchResult(score: bestScore, matchedIndices: bestIndices)
}
