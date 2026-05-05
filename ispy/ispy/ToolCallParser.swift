import Foundation

struct ParsedToolCall {
    let name: String
    let args: [String: String]
}

enum ToolCallParser {
    static let strQ = "<|\u{22}|>"

    static func stripThinking(_ text: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"<\|channel>.*?<channel\|>"#, options: .dotMatchesLineSeparators
        ) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    static func parse(from text: String) -> ParsedToolCall? {
        let stripped = stripThinking(text)

        // call:TOOLNAME{...} — greedy (.*) handles empty {} and args containing "}"
        let callPattern = #"<\|tool_call>\s*call:([a-z_]+)\s*\{(.*)\}\s*<tool_call\|>"#
        if let re = try? NSRegularExpression(pattern: callPattern, options: .dotMatchesLineSeparators),
           let m = re.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let nameRange = Range(m.range(at: 1), in: stripped),
           let argsRange = Range(m.range(at: 2), in: stripped) {
            let name = String(stripped[nameRange])
            let argsStr = String(stripped[argsRange])
            var args = parseArgs(argsStr)
            if args.isEmpty { args = parseJSONArgs("{\(argsStr)}") }
            return ParsedToolCall(name: name, args: args)
        }

        // {"name": "tool", "arguments": {...}} format
        let jsonNamePattern = #"<\|tool_call>.*?"name":\s*"([a-z_]+)".*?<tool_call\|>"#
        if let re = try? NSRegularExpression(pattern: jsonNamePattern, options: .dotMatchesLineSeparators),
           let m = re.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let nameRange = Range(m.range(at: 1), in: stripped) {
            let argsPat = #""arguments":\s*(\{.+\})"#
            var args: [String: String] = [:]
            if let ar = try? NSRegularExpression(pattern: argsPat, options: .dotMatchesLineSeparators),
               let am = ar.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
               let ar2 = Range(am.range(at: 1), in: stripped) {
                args = parseJSONArgs(String(stripped[ar2]))
            }
            return ParsedToolCall(name: String(stripped[nameRange]), args: args)
        }

        return nil
    }

    static func formatResponse(_ name: String, result: String) -> String {
        "<|tool_response>response:\(name){result:\(strQ)\(result)\(strQ)}<tool_response|>\n"
    }

    // MARK: - Private

    private static func parseArgs(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let re = try? NSRegularExpression(
            pattern: #"(\w+):<\|"\|>(.*?)<\|"\|>"#, options: .dotMatchesLineSeparators
        ) else { return result }
        for m in re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let k = Range(m.range(at: 1), in: raw),
                  let v = Range(m.range(at: 2), in: raw) else { continue }
            result[String(raw[k])] = String(raw[v])
        }
        return result
    }

    private static func parseJSONArgs(_ json: String) -> [String: String] {
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj.compactMapValues { $0 as? String }
        }
        // LLMs often emit literal newlines/tabs inside JSON string values — escape them and retry
        var escaped = ""
        var inString = false
        var prev: Character = " "
        for ch in json {
            if ch == "\"" && prev != "\\" { inString.toggle(); escaped.append(ch) }
            else if inString && ch == "\n" { escaped += "\\n" }
            else if inString && ch == "\r" { escaped += "\\r" }
            else if inString && ch == "\t" { escaped += "\\t" }
            else { escaped.append(ch) }
            prev = ch
        }
        guard let data = escaped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }
}
