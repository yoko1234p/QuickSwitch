// Contributor migration/audit tool. Uses the SwiftSyntax libraries bundled with Xcode.
import Foundation
import SwiftParser
import SwiftSyntax

let englishUI: Set<String> = CommandLine.arguments.contains("--english-ui")
    ? Set((try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "scripts/localization/english-ui.json"))) as! [String: String]).keys)
    : []

let canonicalArguments: Set<String> = [
    "aliases", "pattern", "regex", "sample", "example", "input", "code", "script", "category",
    "keywords", "searchKeywords", "source", "identifier", "id", "path", "filename", "rawValue",
]
let canonicalCalls: Set<String> = [
    "contains", "hasPrefix", "hasSuffix", "range", "firstMatch", "matches", "replacingOccurrences",
    "components", "split", "NSRegularExpression", "precondition", "assert", "fatalError",
    "debug", "notice", "fault", "log", "info",
]

func callName(_ call: FunctionCallExprSyntax) -> String {
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
    return call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
}

func skipReason(_ node: StringLiteralExprSyntax, filename: String, ignoringLocalizedKey: Bool = false) -> String? {
    if parts(node).0.contains("tell application ") { return "AppleScript source" }
    var parent = node.parent
    var child = Syntax(node)
    while let current = parent {
        if current.is(EnumCaseElementSyntax.self) { return "enum raw value" }
        if current.is(SwitchCaseLabelSyntax.self) { return "switch match" }
        if let sequence = current.as(SequenceExprSyntax.self), sequence.elements.contains(where: { $0.id == child.id }),
            sequence.elements.contains(where: { expression in
                expression.as(BinaryOperatorExprSyntax.self).map { ["==", "!=", "~="].contains($0.operator.text) } ?? false
            }) { return "comparison operand" }
        if let element = current.as(DictionaryElementSyntax.self),
            element.key.position <= node.position && element.key.endPosition >= node.endPosition
        { return "dictionary key" }
        if let argument = current.as(LabeledExprSyntax.self),
            let label = argument.label?.text, canonicalArguments.contains(label)
        { return "canonical argument: \(label)" }
        if let binding = current.as(PatternBindingSyntax.self) {
            let name = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["categories", "aliases", "units", "digits", "sample", "samples", "example", "examples", "rawValue", "sourceCode", "keywords", "script"].contains(name)
                || name.range(of: "(?:Titles|Labels|Selectors|Patterns)$", options: .regularExpression) != nil {
                return "canonical binding: \(name)"
            }
        }
        if let function = current.as(FunctionDeclSyntax.self), function.name.text == "lunarLabel" { return "lunar calendar data" }
        if let call = current.as(FunctionCallExprSyntax.self) {
            let name = callName(call)
            if canonicalCalls.contains(name) { return "canonical call: \(name)" }
            if !ignoringLocalizedKey, name == "text", call.calledExpression.description.contains("L10n."),
                let first = call.arguments.first,
                first.position <= node.position && first.endPosition >= node.endPosition
            { return "localized key" }
            if filename.hasSuffix("/SuperPilotCore/Action.swift"), name == "init",
                call.arguments.count >= 3 {
                let category = Array(call.arguments)[2]
                if category.position <= node.position && category.endPosition >= node.endPosition { return "action category ID" }
            }
        }
        child = current
        parent = current.parent
    }
    return nil
}

final class RepairCanonical: SyntaxRewriter {
    let filename: String
    init(_ filename: String) { self.filename = filename; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        let result = super.visit(node)
        guard let call = result.as(FunctionCallExprSyntax.self), callName(call) == "text",
            call.calledExpression.description.contains("L10n."),
            let key = call.arguments.first?.expression.as(StringLiteralExprSyntax.self),
            // Inspect the original parent chain, not the rewritten detached expression.
            let originalKey = node.arguments.first?.expression.as(StringLiteralExprSyntax.self),
            skipReason(originalKey, filename: filename, ignoringLocalizedKey: true) != nil
        else { return result }
        var source = String(reflecting: parts(key).0)
        for (index, argument) in call.arguments.dropFirst().enumerated().reversed() {
            var value = argument.expression
            if let string = value.as(FunctionCallExprSyntax.self), callName(string) == "String",
                string.arguments.first?.label?.text == "describing", let expression = string.arguments.first?.expression {
                value = expression
            }
            source = source.replacingOccurrences(of: "%\(index + 1)$@", with: "\\(" + value.description + ")")
        }
        let tree = Parser.parse(source: "let value = " + source)
        let expression = tree.statements.first!.item.as(VariableDeclSyntax.self)!.bindings.first!.initializer!.value
        return expression.with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
    }
}

func parts(_ node: StringLiteralExprSyntax) -> (String, [String]) {
    var pattern = ""
    var arguments: [String] = []
    for segment in node.segments {
        if let string = segment.as(StringSegmentSyntax.self) { pattern += string.content.text }
        if let expression = segment.as(ExpressionSegmentSyntax.self) {
            pattern += "%\(arguments.count + 1)$@"
            let values = Array(expression.expressions)
            let value = values.first!.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let specifier = values.dropFirst().first(where: { $0.label?.text == "specifier" }) {
                arguments.append("String(format: \(specifier.expression), \(value))")
            } else if let format = values.dropFirst().first(where: { $0.label?.text == "format" }) {
                arguments.append("(\(value)).formatted(\(format.expression))")
            } else {
                arguments.append("String(describing: \(value))")
            }
        }
    }
    let literal = node.with(\.segments, StringLiteralSegmentListSyntax([
        .stringSegment(StringSegmentSyntax(content: .stringSegment(pattern)))
    ]))
    return (literal.representedLiteralValue ?? pattern, arguments)
}

func hasChinese(_ node: StringLiteralExprSyntax) -> Bool {
    node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        .range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil
}

func isEnglishUI(_ node: StringLiteralExprSyntax, filename: String) -> Bool {
    guard skipReason(node, filename: filename) == nil,
        parts(node).0.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return false }
    var parent = node.parent
    var label: String?
    while let current = parent {
        if let argument = current.as(LabeledExprSyntax.self) { label = argument.label?.text }
        if let call = current.as(FunctionCallExprSyntax.self) {
            let name = callName(call)
            if ["title", "message", "buttonTitle", "actionTitle", "help", "okText", "failText"].contains(label ?? "") { return true }
            return label == nil && ["Text", "Button", "Toggle", "Picker", "Label", "TextField", "Section", "LabeledContent", "ColorPicker", "help", "accessibilityLabel", "accessibilityHint"].contains(name)
        }
        parent = current.parent
    }
    return false
}

final class Scan: SyntaxVisitor {
    let filename: String
    var records: [[String: Any]] = []
    init(_ filename: String) { self.filename = filename; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        if hasChinese(node) || skipReason(node, filename: filename) == "localized key" || (CommandLine.arguments.contains("--find-english-ui") && isEnglishUI(node, filename: filename)) {
            let (pattern, arguments) = parts(node)
            records.append(["file": filename, "key": pattern, "arguments": arguments,
                "skip": skipReason(node, filename: filename) ?? "", "offset": node.position.utf8Offset])
        }
        return .visitChildren
    }
}

final class Localize: SyntaxRewriter {
    let filename: String
    init(_ filename: String) { self.filename = filename; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        let result = super.visit(node)
        guard (englishUI.isEmpty ? hasChinese(node) : englishUI.contains(parts(node).0)), skipReason(node, filename: filename) == nil,
            let rewritten = result.as(StringLiteralExprSyntax.self)
        else { return result }
        let (pattern, arguments) = parts(rewritten)
        let values = [String(reflecting: pattern)] + arguments
        let source = "let value = L10n.text(" + values.joined(separator: ", ") + ")"
        let tree = Parser.parse(source: source)
        let expression = tree.statements.first!.item.as(VariableDeclSyntax.self)!.bindings.first!.initializer!.value
        return expression.with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
    }
}

let apply = CommandLine.arguments.contains("--apply")
let repair = CommandLine.arguments.contains("--repair-canonical")
let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
var records: [[String: Any]] = []
for filename in files {
    let source = try String(contentsOfFile: filename, encoding: .utf8)
    let tree = Parser.parse(source: source)
    let scan = Scan(filename)
    scan.walk(tree)
    records += scan.records
    if apply || repair {
        let result = repair ? RepairCanonical(filename).rewrite(tree).description : Localize(filename).rewrite(tree).description
        if source != result {
            let backup = URL(fileURLWithPath: ".build/i18n-before/" + filename)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try source.write(to: backup, atomically: true, encoding: .utf8)
            }
            try result.write(toFile: filename, atomically: true, encoding: .utf8)
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
