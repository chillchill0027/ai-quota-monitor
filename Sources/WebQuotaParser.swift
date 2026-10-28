import Foundation

/// Parses text already shown to the user. It never loads a page or makes a request.
/// Unknown labels and ambiguous values fail closed instead of borrowing unrelated numbers.
enum WebQuotaParser {
    struct Window: Equatable {
        let remainingPercent: Double
        let resetText: String?
    }
    struct GeminiQuota {
        let fiveHour: Window?
        let weekly: Window?
        var hasValues: Bool { fiveHour != nil || weekly != nil }
    }
    struct Money: Equatable {
        let amount: Double
        let currency: String
        var currencySymbol: String { currency == "USD" ? "$" : "¥" }
    }

    private enum WindowKind: Hashable { case fiveHour, weekly }
    private struct Header { let kind: WindowKind }

    static func parseGemini(_ text: String) -> GeminiQuota {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var cards: [WindowKind: [Window?]] = [:]
        var resetValueLines = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard !resetValueLines.contains(index), let header = windowHeader(line) else { continue }
            var block = [line]
            var expectingResetValue = false
            for (offset, next) in lines.dropFirst(index + 1).prefix(7).enumerated() {
                if expectingResetValue && isDateOrDuration(next) {
                    block.append(next)
                    resetValueLines.insert(index + 1 + offset)
                    expectingResetValue = false
                    continue
                }
                if windowHeader(next) != nil { break }
                if isPayloadLine(next) {
                    block.append(next)
                    expectingResetValue = isResetLabelOnly(next)
                } else {
                    break
                }
            }
            cards[header.kind, default: []].append(parseWindow(block))
        }
        func unique(_ kind: WindowKind) -> Window? {
            guard let candidates = cards[kind], !candidates.isEmpty,
                  candidates.allSatisfy({ $0 != nil }), let first = candidates[0] else { return nil }
            // Repeated cards from another product/model are not interchangeable.
            return candidates.allSatisfy { $0 == first } ? first : nil
        }
        return GeminiQuota(fiveHour: unique(.fiveHour), weekly: unique(.weekly))
    }

    private static func windowHeader(_ line: String) -> Header? {
        guard !containsReset(line) else { return nil }
        let patterns: [(WindowKind, String)] = [
            (.fiveHour, #"^(?:(?:5|five)[\s-]*(?:hours?|hrs?|h)|5\s*(?:小时|小時)|五\s*小时|当前用量|當前用量|目前用量|current\s*(?:usage|limit|quota|window))(?:[\s-]*(?:limit|quota|window|usage)|(?:用量限额|用量限制|使用量|限额|限額|配额|配額|窗口|用量))?(?:[\s\t]*[ⓘℹ️ℹ(（iI）)])?"#),
            (.weekly, #"^(?:weekly(?:[\s-]*(?:limit|quota|window|usage))?|7[\s-]*(?:days?|天)(?:[\s-]*(?:limit|quota|window|usage)|(?:限额|配额|窗口|用量))?|每周(?:限额|限額|配额|配額|窗口|用量)?|每週(?:限额|限額|配额|配額|窗口|用量)?|本周(?:限额|配额|窗口|用量)?|周(?:限额|配额|窗口|用量))"#)
        ]
        for (kind, pattern) in patterns {
            guard let match = matches(pattern, in: line).first,
                  let range = Range(match.range, in: line) else { continue }
            let tail = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：-ⓘℹ️ℹ")))
            if tail.isEmpty || isPayloadLine(tail) { return Header(kind: kind) }
        }
        return nil
    }

    private static func isPayloadLine(_ line: String) -> Bool {
        if containsReset(line) { return true }
        if !matches(#"^[0-9.+\-\s%％:：ⓘℹ️ℹ(（iI）)]+$"#, in: line).isEmpty { return true }
        if !matches(#"^(?:limits?|usage|quota|window|用量|限额|配额|窗口|ⓘ|ℹ️|ℹ|i|info|info_outline)$"#, in: line).isEmpty { return true }
        // Requiring a leading semantic label/percentage avoids crossing into unrelated cards.
        return !matches(#"^(?:(?:remaining|left|available|used|consumed|剩余|可用|已用|已使用|已消耗)\b|(?:剩余|可用|已用|已使用|已消耗)|[+\-]?[0-9]+(?:\.[0-9]+)?\s*[%％])"#, in: line).isEmpty
    }

    private static func parseWindow(_ lines: [String]) -> Window? {
        let text = lines.joined(separator: "\n").replacingOccurrences(of: "％", with: "%")
        let percentages = matches(#"(?<![A-Za-z0-9.,+\-])([+\-]?[0-9]+(?:\.[0-9]+)?)\s*%"#, in: text)
        guard !percentages.isEmpty else { return nil }
        let number = #"(?<![A-Za-z0-9.,+\-])([+\-]?[0-9]+(?:\.[0-9]+)?)\s*%"#
        let remaining = #"(?:(?:remaining|left|available)\b|剩余|可用)(?:\s*(?:quota|allowance|额度|配额))?"#
        let used = #"(?:(?:used|consumed)\b|已使用|已消耗|已用)(?:\s*(?:quota|allowance|额度|配额))?"#
        let patterns: [(String, Bool)] = [
            (remaining + #"\s*[:：]?\s*"# + number, false),
            (number + #"\s*"# + remaining, false),
            (used + #"\s*[:：]?\s*"# + number, true),
            (number + #"\s*"# + used, true)
        ]
        // Prefer same-line labels. Otherwise the trailing "used" from one row could
        // incorrectly bind the next row's remaining percentage across a newline.
        var values: [Int: Set<Double>] = [:]
        for crossLine in [false, true] {
            var passValues: [Int: Set<Double>] = [:]
            for (pattern, isUsed) in patterns {
                let actualPattern = crossLine ? pattern : pattern.replacingOccurrences(of: "\\s", with: "[ \t]")
                for match in matches(actualPattern, in: text) {
                    let position = match.range(at: 1).location
                    if crossLine && values[position] != nil { continue }
                    guard let capture = Range(match.range(at: 1), in: text),
                          let raw = Double(text[capture]), raw.isFinite, (0...100).contains(raw) else { return nil }
                    passValues[position, default: []].insert(isUsed ? 100 - raw : raw)
                }
            }
            values.merge(passValues) { existing, additional in existing.union(additional) }
        }
        // Every percentage in this card must have an unambiguous used/remaining meaning.
        guard percentages.allSatisfy({ values[$0.range(at: 1).location]?.count == 1 }) else { return nil }
        let allValues = Set(values.values.flatMap { $0 })
        guard allValues.count == 1, let value = allValues.first else { return nil }
        let resets = lines.enumerated().compactMap { index, line -> String? in
            guard containsReset(line) else { return nil }
            if isResetLabelOnly(line), lines.indices.contains(index + 1), isDateOrDuration(lines[index + 1]) {
                return line + " " + lines[index + 1]
            }
            return isResetLabelOnly(line) ? nil : line
        }
        let uniqueResets = Set(resets)
        guard uniqueResets.count <= 1 else { return nil }
        return Window(remainingPercent: value, resetText: uniqueResets.first)
    }

    private static func containsReset(_ text: String) -> Bool {
        !matches(#"\b(?:resets?|refresh(?:es)?)\b|重置|刷新"#, in: text).isEmpty
    }
    private static func isResetLabelOnly(_ text: String) -> Bool {
        !matches(#"^(?:resets?|refresh(?:es)?|重置(?:时间)?|刷新(?:时间)?)\s*[:：]?$"#, in: text).isEmpty
    }
    private static func isDateOrDuration(_ text: String) -> Bool {
        // Preserve server/page text; do not infer a timezone or turn a relative phrase into a date.
        !matches(#"^(?:in\s+)?(?:[0-9]|明天|今天|周[一二三四五六日天]|星期|Mon|Tue|Wed|Thu|Fri|Sat|Sun|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"#, in: text).isEmpty
    }

    static func parseMiMoBalance(_ text: String) -> Money? {
        // Only cash balance is accepted: account/available/total balances may include gifts.
        // Currency must be explicit and adjacent to the amount or in the label.
        let number = #"([+\-−]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
        let label = #"(?:^|\n)[ \t]*(?:Cash[ \t]+Balance|(?:账户)?现金余额)[ \t]*(?:[（(][ \t]*(CNY|RMB|USD)[ \t]*[）)])?[ \t]*[:：]?[ \t\n]*"#
        let pattern = label + #"(¥|￥|\$|CNY|RMB|USD)?[ \t\n]*"# + number + #"[ \t]*(CNY|RMB|USD|元|美元)?[ \t]*(?=\n|$)"#
        var found: [Money] = []
        for match in matches(pattern, in: text) {
            func group(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            guard let amountText = group(3)?.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-"),
                  let amount = Double(amountText), amount.isFinite else { return nil }
            let currencies = [group(1), group(2), group(4)].compactMap { token -> String? in
                guard let token else { return nil }
                return ["USD", "$", "美元"].contains(token.uppercased()) ? "USD" : "CNY"
            }
            guard !currencies.isEmpty, Set(currencies).count == 1, let currency = currencies.first else { return nil }
            found.append(Money(amount: amount, currency: currency))
        }
        guard matches(label, in: text).count == found.count,
              let first = found.first, found.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}
