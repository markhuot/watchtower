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
///
/// Uses an O(n*m) dynamic programming approach (n = query length, m = candidate
/// length) so it stays fast even for very long candidate strings like URLs.
func fuzzyMatch(query: String, candidate: String) -> FuzzyMatchResult? {
    guard !query.isEmpty else {
        // Empty query matches everything with a neutral score
        return FuzzyMatchResult(score: 0, matchedIndices: [])
    }
    guard !candidate.isEmpty else { return nil }

    let queryChars = Array(query.lowercased())
    let candidateChars = Array(candidate.lowercased())
    let candidateOriginal = Array(candidate)
    let n = queryChars.count
    let m = candidateChars.count

    guard m >= n else { return nil }

    // First, verify the candidate contains all query characters in order (quick reject)
    var checkIdx = 0
    for qc in queryChars {
        var found = false
        while checkIdx < m {
            if candidateChars[checkIdx] == qc {
                found = true
                checkIdx += 1
                break
            }
            checkIdx += 1
        }
        if !found { return nil }
    }

    // DP approach: two tables of size [n][m]
    // score[q][c] = best score matching queryChars[0...q] ending with queryChars[q] matched at candidateChars[c]
    // We track two variants per cell:
    //   - "consecutive": the match at (q, c) extends a match at (q-1, c-1)
    //   - "fresh": the match at (q, c) starts a new run (best of all (q-1, c') where c' < c)
    // This lets us compute the consecutive bonus correctly.

    // For memory efficiency, use flat arrays. Index as [q * m + c].
    // scoreConsec[q][c]: best score where (q,c) is consecutive with (q-1,c-1)
    // scoreFresh[q][c]:  best score where (q,c) starts a new run
    // best[q][c] = max(scoreConsec, scoreFresh) for this cell
    // We also need to track which choice was made, for backtracking.

    let sentinel = Int.min / 2  // "no valid path" marker (avoid overflow on addition)

    // For each query char q and candidate position c, compute the bonus for matching there
    func matchBonus(q: Int, c: Int) -> Int {
        var bonus = 1  // base score for a match
        if c == 0 {
            bonus += 10 // prefix bonus (start of string)
        } else {
            let prevChar = candidateOriginal[c - 1]
            if prevChar == " " || prevChar == "-" || prevChar == "_" || prevChar == "/" {
                bonus += 6 // word boundary
            } else if prevChar.isLowercase && candidateOriginal[c].isUppercase {
                bonus += 6 // camelCase boundary
            }
        }
        return bonus
    }

    // We only need two rows at a time (current query char and previous).
    // For each row, track the best score at each candidate position and the
    // running maximum up to each position (for "fresh start" lookups).

    // prev[c] = best score for matching queryChars[0..q-1] with last match at candidate position c
    // prevRunningMax = running max of prev[0..c] (so we can look up "best score for q-1 ending before c")
    // prevMaxIdx[c] = the candidate index that achieved prevRunningMax up to position c

    var prev = [Int](repeating: sentinel, count: m)
    var prevRunningMax = [Int](repeating: sentinel, count: m)
    var prevMaxSource = [Int](repeating: -1, count: m)  // which c achieved the running max

    var curr = [Int](repeating: sentinel, count: m)

    // For backtracking: choice[q][c] stores the candidate index of the previous match
    // -1 = no previous (q == 0), -2 = invalid cell
    // We store these in a flat array [n * m]
    var choice = [Int](repeating: -2, count: n * m)

    // Fill first query row (q = 0)
    let qc0 = queryChars[0]
    for c in 0..<m {
        if candidateChars[c] == qc0 {
            let bonus = matchBonus(q: 0, c: c)
            prev[c] = bonus
            choice[c] = -1  // no predecessor
        }
        if c == 0 {
            prevRunningMax[c] = prev[c]
            prevMaxSource[c] = prev[c] > sentinel ? c : -1
        } else {
            if prev[c] > prevRunningMax[c - 1] {
                prevRunningMax[c] = prev[c]
                prevMaxSource[c] = c
            } else {
                prevRunningMax[c] = prevRunningMax[c - 1]
                prevMaxSource[c] = prevMaxSource[c - 1]
            }
        }
    }

    // Fill remaining query rows
    for q in 1..<n {
        let qc = queryChars[q]
        curr = [Int](repeating: sentinel, count: m)

        for c in q..<m {  // c must be >= q (need at least q+1 candidate chars for q+1 query chars)
            guard candidateChars[c] == qc else { continue }

            let bonus = matchBonus(q: q, c: c)
            var bestForCell = sentinel
            var bestPrevC = -2

            // Option 1: consecutive — extends match at (q-1, c-1)
            if c > 0 && prev[c - 1] > sentinel {
                let consecScore = prev[c - 1] + bonus + 8  // +8 consecutive bonus
                if consecScore > bestForCell {
                    bestForCell = consecScore
                    bestPrevC = c - 1
                }
            }

            // Option 2: fresh start — best of prev[0..c-2] (non-consecutive)
            if c >= 2 && prevRunningMax[c - 2] > sentinel {
                let freshScore = prevRunningMax[c - 2] + bonus
                if freshScore > bestForCell {
                    bestForCell = freshScore
                    bestPrevC = prevMaxSource[c - 2]
                }
            }

            // Option 2b: fresh start from c-1 (gap of 0 positions but still "fresh" since
            // the prev match was NOT at c-1... wait, if prev match IS at c-1 that's consecutive.
            // Actually we need fresh from any prev position < c that is NOT c-1, plus consecutive from c-1.
            // The running max up to c-2 covers all positions < c-1. We also need to consider c-1 as fresh
            // only if it wasn't already handled as consecutive. But since consecutive always scores higher
            // (same base + 8 bonus), the consecutive path dominates when prev[c-1] is valid. So fresh
            // from prevRunningMax[c-2] is correct.

            if bestForCell > sentinel {
                curr[c] = bestForCell
                choice[q * m + c] = bestPrevC
            }
        }

        // Update prev and running max for next iteration
        prev = curr
        prevRunningMax = [Int](repeating: sentinel, count: m)
        prevMaxSource = [Int](repeating: -1, count: m)
        for c in 0..<m {
            if c == 0 {
                prevRunningMax[c] = prev[c]
                prevMaxSource[c] = prev[c] > sentinel ? c : -1
            } else {
                if prev[c] > prevRunningMax[c - 1] {
                    prevRunningMax[c] = prev[c]
                    prevMaxSource[c] = c
                } else {
                    prevRunningMax[c] = prevRunningMax[c - 1]
                    prevMaxSource[c] = prevMaxSource[c - 1]
                }
            }
        }
    }

    // Find the best score in the last query row
    var bestScore = sentinel
    var bestEndC = -1
    for c in 0..<m {
        if prev[c] > bestScore {
            bestScore = prev[c]
            bestEndC = c
        }
    }

    guard bestScore > sentinel, bestEndC >= 0 else { return nil }

    // Backtrack to recover matched indices
    var matchedIndices = [Int](repeating: 0, count: n)
    var c = bestEndC
    for q in stride(from: n - 1, through: 0, by: -1) {
        matchedIndices[q] = c
        if q > 0 {
            c = choice[q * m + c]
        }
    }

    return FuzzyMatchResult(score: bestScore, matchedIndices: matchedIndices)
}
