//
//  ExpressionParser.swift
//  MJDrop
//
//  Tokenizer and recursive descent parser for the Milkdrop expression language.
//  Produces an AST (ExprNode) from expression strings like "zoom = 1.0 + 0.1*sin(time*0.3)".
//

import Foundation

// MARK: - Token

nonisolated enum Token: Equatable, Sendable {
    case number(Float)
    case identifier(String)
    case plus, minus, multiply, divide, modulo
    case leftParen, rightParen
    case comma
    case assign            // =
    case semicolon         // ;
    case less, greater     // < >
    case lessEqual, greaterEqual  // <= >=
    case equalEqual        // ==
    case notEqual          // !=
    case ampersand         // & (bitwise and/logical)
    case pipe              // | (bitwise or/logical)
    case eof
}

// MARK: - ExprNode (AST)

indirect enum ExprNode: Sendable {
    case literal(Float)
    case variable(Int)  // slot index
    case unaryMinus(ExprNode)
    case binaryOp(BinaryOp, ExprNode, ExprNode)
    case functionCall(BuiltinFunction, [ExprNode])
}

nonisolated enum BinaryOp: Sendable {
    case add, subtract, multiply, divide, modulo
    case less, greater, lessEqual, greaterEqual, equal, notEqual
    case logicalAnd, logicalOr
}

// MARK: - BuiltinFunction

nonisolated enum BuiltinFunction: String, Sendable, CaseIterable {
    case sin, cos, tan, asin, acos, atan, atan2
    case abs, sqrt, sqr, pow, log, exp, log10
    case floor, ceil, sign, frac = "frac", int = "int"
    case fmod, min, max, clamp, lerp
    case `if` = "if"
    case above, below, equal, band, bor, bnot
    case rand
    case sigmoid
    case noise

    var arity: Int {
        switch self {
        case .sin, .cos, .tan, .asin, .acos, .atan, .abs, .sqrt, .sqr,
             .log, .exp, .log10, .floor, .ceil, .sign, .frac, .int,
             .bnot, .rand, .sigmoid, .noise:
            return 1
        case .pow, .fmod, .min, .max, .atan2, .above, .below, .equal, .band, .bor:
            return 2
        case .clamp, .lerp, .if:
            return 3
        }
    }
}

// MARK: - CompiledAssignment

/// A single `variable = expression` assignment ready to execute.
nonisolated struct CompiledAssignment: Sendable {
    let targetSlot: Int
    let expression: ExprNode
}

// MARK: - Tokenizer

nonisolated struct Tokenizer {
    private let source: [Character]
    private var pos: Int = 0

    init(_ string: String) {
        source = Array(string)
    }

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while pos < source.count {
            skipWhitespace()
            guard pos < source.count else { break }

            let ch = source[pos]

            // Numbers
            if ch.isNumber || (ch == "." && pos + 1 < source.count && source[pos + 1].isNumber) {
                tokens.append(readNumber())
                continue
            }

            // Identifiers and keywords
            if ch.isLetter || ch == "_" {
                tokens.append(readIdentifier())
                continue
            }

            // Operators and punctuation
            switch ch {
            case "+": tokens.append(.plus); pos += 1
            case "-": tokens.append(.minus); pos += 1
            case "*": tokens.append(.multiply); pos += 1
            case "/": tokens.append(.divide); pos += 1
            case "%": tokens.append(.modulo); pos += 1
            case "(": tokens.append(.leftParen); pos += 1
            case ")": tokens.append(.rightParen); pos += 1
            case ",": tokens.append(.comma); pos += 1
            case ";": tokens.append(.semicolon); pos += 1
            case "&":
                pos += 1
                if pos < source.count && source[pos] == "&" { pos += 1 }
                tokens.append(.ampersand)
            case "|":
                pos += 1
                if pos < source.count && source[pos] == "|" { pos += 1 }
                tokens.append(.pipe)
            case "=":
                pos += 1
                if pos < source.count && source[pos] == "=" {
                    pos += 1
                    tokens.append(.equalEqual)
                } else {
                    tokens.append(.assign)
                }
            case "!":
                pos += 1
                if pos < source.count && source[pos] == "=" {
                    pos += 1
                    tokens.append(.notEqual)
                }
                // standalone ! not supported, skip
            case "<":
                pos += 1
                if pos < source.count && source[pos] == "=" {
                    pos += 1
                    tokens.append(.lessEqual)
                } else {
                    tokens.append(.less)
                }
            case ">":
                pos += 1
                if pos < source.count && source[pos] == "=" {
                    pos += 1
                    tokens.append(.greaterEqual)
                } else {
                    tokens.append(.greater)
                }
            default:
                // Skip unknown characters
                pos += 1
            }
        }
        tokens.append(.eof)
        return tokens
    }

    private mutating func skipWhitespace() {
        while pos < source.count && (source[pos] == " " || source[pos] == "\t" || source[pos] == "\r" || source[pos] == "\n") {
            pos += 1
        }
    }

    private mutating func readNumber() -> Token {
        var str = ""
        // Handle hex: 0x...
        if pos + 1 < source.count && source[pos] == "0" && (source[pos + 1] == "x" || source[pos + 1] == "X") {
            str += "0x"
            pos += 2
            while pos < source.count && source[pos].isHexDigit {
                str.append(source[pos])
                pos += 1
            }
            if let val = UInt32(str.dropFirst(2), radix: 16) {
                return .number(Float(val))
            }
            return .number(0)
        }

        while pos < source.count && (source[pos].isNumber || source[pos] == ".") {
            str.append(source[pos])
            pos += 1
        }
        // Handle scientific notation: 1e-3
        if pos < source.count && (source[pos] == "e" || source[pos] == "E") {
            str.append(source[pos])
            pos += 1
            if pos < source.count && (source[pos] == "+" || source[pos] == "-") {
                str.append(source[pos])
                pos += 1
            }
            while pos < source.count && source[pos].isNumber {
                str.append(source[pos])
                pos += 1
            }
        }
        return .number(Float(str) ?? 0)
    }

    private mutating func readIdentifier() -> Token {
        var str = ""
        while pos < source.count && (source[pos].isLetter || source[pos].isNumber || source[pos] == "_") {
            str.append(source[pos])
            pos += 1
        }
        return .identifier(str.lowercased())
    }
}

// MARK: - Parser

nonisolated struct ExpressionParser {
    private var tokens: [Token]
    private var pos: Int = 0
    private let builder: VariableTableBuilder

    init(tokens: [Token], builder: VariableTableBuilder) {
        self.tokens = tokens
        self.builder = builder
    }

    /// Parse a full line that may contain multiple semicolon-separated assignments.
    /// Returns compiled assignments.
    static func parseLine(_ line: String, builder: VariableTableBuilder) -> [CompiledAssignment] {
        // Split on semicolons for multi-statement lines
        let statements = line.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var assignments: [CompiledAssignment] = []
        for stmt in statements {
            var tokenizer = Tokenizer(stmt)
            let tokens = tokenizer.tokenize()
            var parser = ExpressionParser(tokens: tokens, builder: builder)
            if let assignment = parser.parseAssignment() {
                assignments.append(assignment)
            }
        }
        return assignments
    }

    /// Parse a single `identifier = expression` assignment.
    private mutating func parseAssignment() -> CompiledAssignment? {
        // Look for pattern: identifier = expression
        guard case .identifier(let name) = peek() else { return nil }
        advance()

        guard peek() == .assign else {
            // Not an assignment — could be a bare expression, skip it
            return nil
        }
        advance() // consume =

        let slot = builder.register(name)
        guard let expr = parseExpression() else { return nil }
        return CompiledAssignment(targetSlot: slot, expression: expr)
    }

    // MARK: - Recursive Descent

    /// expression = logicalOr
    private mutating func parseExpression() -> ExprNode? {
        return parseLogicalOr()
    }

    /// logicalOr = logicalAnd ( ('|' | '||') logicalAnd )*
    private mutating func parseLogicalOr() -> ExprNode? {
        guard var left = parseLogicalAnd() else { return nil }
        while peek() == .pipe {
            advance()
            guard let right = parseLogicalAnd() else { return left }
            left = .binaryOp(.logicalOr, left, right)
        }
        return left
    }

    /// logicalAnd = comparison ( ('&' | '&&') comparison )*
    private mutating func parseLogicalAnd() -> ExprNode? {
        guard var left = parseComparison() else { return nil }
        while peek() == .ampersand {
            advance()
            guard let right = parseComparison() else { return left }
            left = .binaryOp(.logicalAnd, left, right)
        }
        return left
    }

    /// comparison = additive ( ('<' | '>' | '<=' | '>=' | '==' | '!=') additive )?
    private mutating func parseComparison() -> ExprNode? {
        guard var left = parseAdditive() else { return nil }

        while true {
            let op: BinaryOp
            switch peek() {
            case .less: op = .less
            case .greater: op = .greater
            case .lessEqual: op = .lessEqual
            case .greaterEqual: op = .greaterEqual
            case .equalEqual: op = .equal
            case .notEqual: op = .notEqual
            default: return left
            }
            advance()
            guard let right = parseAdditive() else { return left }
            left = .binaryOp(op, left, right)
        }
    }

    /// additive = multiplicative ( ('+' | '-') multiplicative )*
    private mutating func parseAdditive() -> ExprNode? {
        guard var left = parseMultiplicative() else { return nil }
        while peek() == .plus || peek() == .minus {
            let isAdd = peek() == .plus
            advance()
            guard let right = parseMultiplicative() else { return left }
            left = .binaryOp(isAdd ? .add : .subtract, left, right)
        }
        return left
    }

    /// multiplicative = unary ( ('*' | '/' | '%') unary )*
    private mutating func parseMultiplicative() -> ExprNode? {
        guard var left = parseUnary() else { return nil }
        while peek() == .multiply || peek() == .divide || peek() == .modulo {
            let op: BinaryOp
            switch peek() {
            case .multiply: op = .multiply
            case .divide: op = .divide
            default: op = .modulo
            }
            advance()
            guard let right = parseUnary() else { return left }
            left = .binaryOp(op, left, right)
        }
        return left
    }

    /// unary = '-' unary | primary
    private mutating func parseUnary() -> ExprNode? {
        if peek() == .minus {
            advance()
            guard let operand = parseUnary() else { return nil }
            // Optimize: -literal
            if case .literal(let v) = operand {
                return .literal(-v)
            }
            return .unaryMinus(operand)
        }
        // Handle unary +
        if peek() == .plus {
            advance()
            return parseUnary()
        }
        return parsePrimary()
    }

    /// primary = number | identifier | functionCall | '(' expression ')'
    private mutating func parsePrimary() -> ExprNode? {
        switch peek() {
        case .number(let v):
            advance()
            return .literal(v)

        case .identifier(let name):
            advance()

            // Check if it's a function call
            if peek() == .leftParen {
                if let fn = BuiltinFunction(rawValue: name) {
                    advance() // consume (
                    var args: [ExprNode] = []
                    if peek() != .rightParen {
                        if let arg = parseExpression() {
                            args.append(arg)
                        }
                        while peek() == .comma {
                            advance()
                            if let arg = parseExpression() {
                                args.append(arg)
                            }
                        }
                    }
                    if peek() == .rightParen { advance() }
                    return .functionCall(fn, args)
                } else {
                    // Unknown function — treat as variable * (expression)
                    // This handles edge cases like "x(1+2)" meaning "x*(1+2)"
                    // Actually, just skip parenthesized part as unknown function
                    advance() // consume (
                    let inner = parseExpression()
                    if peek() == .rightParen { advance() }
                    // Treat as multiplication if inner exists
                    let varSlot = builder.register(name)
                    if let inner = inner {
                        return .binaryOp(.multiply, .variable(varSlot), inner)
                    }
                    return .variable(varSlot)
                }
            }

            // Plain variable
            let slot = builder.register(name)
            return .variable(slot)

        case .leftParen:
            advance()
            let expr = parseExpression()
            if peek() == .rightParen { advance() }
            return expr

        default:
            return nil
        }
    }

    // MARK: - Token Helpers

    private func peek() -> Token {
        guard pos < tokens.count else { return .eof }
        return tokens[pos]
    }

    private mutating func advance() {
        pos += 1
    }
}
