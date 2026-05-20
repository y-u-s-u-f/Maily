import Foundation

enum FuzzyMatch {
    static func score(query: String, in candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !c.isEmpty else { return nil }

        var qi = 0
        var firstMatchIndex = -1
        var lastMatchIndex = -1
        var consecutive = 0
        var maxConsecutive = 0
        var matchedCount = 0

        for (ci, ch) in c.enumerated() {
            if qi < q.count && ch == q[qi] {
                if firstMatchIndex == -1 { firstMatchIndex = ci }
                if lastMatchIndex == ci - 1 {
                    consecutive += 1
                } else {
                    consecutive = 1
                }
                maxConsecutive = max(maxConsecutive, consecutive)
                lastMatchIndex = ci
                matchedCount += 1
                qi += 1
                if qi == q.count { break }
            }
        }

        guard qi == q.count else { return nil }

        var score = 1000
        score -= firstMatchIndex * 50
        if firstMatchIndex == 0 { score += 200 }
        score += maxConsecutive * 30
        let span = lastMatchIndex - firstMatchIndex + 1
        let gaps = span - matchedCount
        score -= gaps * 10
        score -= c.count
        return score
    }

    static func bestScore(query: String, title: String, keywords: [String]) -> Int? {
        var best: Int? = score(query: query, in: title)
        for k in keywords {
            if let s = score(query: query, in: k) {
                if let b = best { best = max(b, s) } else { best = s }
            }
        }
        return best
    }
}
