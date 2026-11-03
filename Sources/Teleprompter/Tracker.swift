import Foundation

/// Works out where the speaker is in the script by aligning the most recently
/// recognised words against the script's words (local alignment with a
/// preference for staying close to the current position).
struct Tracker {
    private(set) var words: [String]
    /// Index of the next script word the speaker is expected to say.
    var position: Int = 0

    /// How many trailing recognised words to align.
    var tailLength = 10

    /// Similarity of a heard word against every script word, cached because the same words are re-sent with each partial result.
    private var similarityCache: [String: [Double]] = [:]

    private mutating func similarities(for heard: String) -> [Double] {
        if let cached = similarityCache[heard] { return cached }
        if similarityCache.count > 4000 { similarityCache.removeAll() }
        let row = words.map { Self.similarity(heard, $0) }
        similarityCache[heard] = row
        return row
    }

    init(words: [String]) {
        self.words = words
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "first": "1st", "second": "2nd", "third": "3rd",
    ]

    private static func canonical(_ w: String) -> String {
        numberWords[w] ?? w
    }

    /// Similarity of two normalised words: 2 = same, 1.2 = close, negative = different.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 2 }
        let ca = canonical(a), cb = canonical(b)
        if ca == cb { return 2 }
        let shorter = min(ca.count, cb.count)
        if shorter >= 4 {
            if ca.hasPrefix(cb) || cb.hasPrefix(ca) { return 1.2 }
            let d = levenshtein(ca, cb, limit: 2)
            if d <= 1 || (d <= 2 && shorter >= 7) { return 1.2 }
        }
        return -1
    }

    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Feed the words heard so far (only the tail is used). Returns true if the position changed.
    @discardableResult
    mutating func update(heard: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let tail = Array(heard.suffix(tailLength))
        let m = tail.count, n = words.count
        guard m >= 2 else { return false }

        let gap = -1.0
        // score[i][j]: best local alignment ending at tail[i-1], words[j-1]; matches[i][j]: matched word count.
        var prevScore = [Double](repeating: 0, count: n + 1)
        var prevMatch = [Int](repeating: 0, count: n + 1)
        var curScore = prevScore, curMatch = prevMatch

        var best: (score: Double, pos: Int, matched: Int)?

        let rows = tail.map { similarities(for: $0) }

        for i in 1...m {
            let row = rows[i - 1]
            curScore[0] = 0; curMatch[0] = 0
            for j in 1...n {
                let sim = row[j - 1]
                var s = prevScore[j - 1] + sim
                var c = prevMatch[j - 1] + (sim > 0 ? 1 : 0)
                if prevScore[j] + gap > s { s = prevScore[j] + gap; c = prevMatch[j] }   // extra heard word
                if curScore[j - 1] + gap > s { s = curScore[j - 1] + gap; c = curMatch[j - 1] } // skipped script word
                if s <= 0 { s = 0; c = 0 }
                curScore[j] = s; curMatch[j] = c
            }
            // Only accept alignments that reach the latest (or almost latest) heard words,
            // since the last word of a partial result is often unstable.
            let dropped = m - i
            if dropped <= 2 {
                for j in 1...n where curMatch[j] >= 2 && row[j - 1] > 0 {
                    let candidate = j // next word after words[j-1]
                    let d = candidate - position
                    let adjusted = curScore[j] - Double(dropped) * 0.75 - penalty(distance: d)
                    let needed: Int
                    if d >= -2 && d <= 8 { needed = 2 }
                    else if d > 8 && d <= 30 { needed = 3 }
                    else if abs(d) <= 200 { needed = 4 }
                    else { needed = 5 }
                    guard curMatch[j] >= needed, adjusted >= 3 else { continue }
                    if best == nil || adjusted > best!.score + 1e-9
                        || (abs(adjusted - best!.score) < 1e-9 && abs(d) < abs(best!.pos - position)) {
                        best = (adjusted, candidate, curMatch[j])
                    }
                }
            }
            swap(&prevScore, &curScore); swap(&prevMatch, &curMatch)
        }

        guard let b = best, b.pos != position else { return false }
        position = b.pos
        return true
    }

    private func penalty(distance d: Int) -> Double {
        if d >= -2 && d <= 30 { return 0 }
        if d < 0 { return 0.5 + Double(-d) * 0.02 }
        return Double(d - 30) * 0.01
    }
}
