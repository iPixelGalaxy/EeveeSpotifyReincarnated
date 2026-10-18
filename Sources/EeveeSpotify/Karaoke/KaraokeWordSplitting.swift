import Foundation
import NaturalLanguage

// Native adaptation of ExperimentalWordSync.ts's word units and weighted ranges.
// Original phrase boundaries remain authoritative; generated timing is approximate.
extension KaraokeLyricsDto {
    func splittingTimedWords() -> KaraokeLyricsDto {
        var result = self
        for index in result.lines.indices where !result.lines[index].isInterlude {
            let line = result.lines[index]
            // Line-only adapters store separate words with instantaneous timestamps.
            // Rebuild their timing from the line range before splitting its words.
            let instantaneous = !line.syllables.isEmpty && line.syllables.allSatisfy {
                $0.startMs == line.startMs && $0.endMs <= $0.startMs
            }
            let source: [KaraokeSyllableDto]
            if line.isLineSynced || instantaneous {
                source = [KaraokeSyllableDto(text: line.plainText, startMs: line.startMs,
                    endMs: max(line.startMs, line.endMs), isPartOfWord: false)]
            } else { source = line.syllables }
            let words = source.flatMap { splitTimedSyllable($0) }
            if words != line.syllables { result.hasExperimentalWordTiming = true }
            result.lines[index].syllables = words
            result.lines[index].isLineSynced = false
        }
        return result
    }
}

private struct KaraokeSplitUnit {
    let text: String
    var joined: Bool
}

private func splitTimedSyllable(_ original: KaraokeSyllableDto) -> [KaraokeSyllableDto] {
    let tokens = original.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    var units = [KaraokeSplitUnit]()
    for token in tokens {
        let cjk = token.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
        var cuts = Set([0, token.utf16.count])
        if cjk {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = token
            for range in tokenizer.tokens(for: token.startIndex..<token.endIndex).dropFirst() {
                cuts.insert(NSRange(token.startIndex..<range.lowerBound, in: token).length)
            }
            if cuts.count == 2, token.count > 1 {
                for index in token.indices.dropFirst() { cuts.insert(NSRange(token.startIndex..<index, in: token).length) }
            }
        }
        if let expression = karaokeWordDashSeparator {
            for match in expression.matches(in: token, range: NSRange(token.startIndex..<token.endIndex, in: token)) {
                cuts.insert(NSMaxRange(match.range))
            }
        }
        let boundaries = cuts.sorted()
        for index in 0..<(boundaries.count - 1) {
            let range = NSRange(location: boundaries[index], length: boundaries[index + 1] - boundaries[index])
            guard let slice = Range(range, in: token) else { continue }
            units.append(KaraokeSplitUnit(text: String(token[slice]), joined: index + 1 < boundaries.count - 1))
        }
    }
    guard units.count > 1 else { return [original] }
    units[units.count - 1].joined = original.isPartOfWord
    let weights = units.map { unit -> Int in
        let characters = unit.text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return max(1, String(String.UnicodeScalarView(characters)).utf16.count)
    }
    let total = max(1, weights.reduce(0, +))
    let duration = max(0, original.endMs - original.startMs)
    var consumed = 0
    return units.indices.map { index in
        let start = original.startMs + duration * consumed / total
        consumed += weights[index]
        let end = original.startMs + duration * consumed / total
        return KaraokeSyllableDto(text: units[index].text, startMs: start, endMs: end, isPartOfWord: units[index].joined)
    }
}

private let karaokeWordDashSeparator = try? NSRegularExpression(pattern: #"(?<=[\p{L}\p{M}\p{N}])[-‐‑‒–—―]+(?=[\p{L}\p{N}])"#)
