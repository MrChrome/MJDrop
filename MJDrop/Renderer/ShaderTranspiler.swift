//
//  ShaderTranspiler.swift
//  MJDrop
//
//  Transpiles Milkdrop v2 HLSL pixel shaders into Metal Shading Language.
//  The Milkdrop HLSL dialect is limited enough for string-based transformation:
//    - No classes, templates, or complex preprocessor
//    - Fixed set of built-in functions and samplers
//    - Simple `shader_body { ... }` wrapper
//

import Foundation

enum ShaderType {
    case warp
    case composite
}

struct TranspileResult {
    let metalSource: String
    let functionName: String
}

struct ShaderTranspiler {

    // MARK: - Public API

    static func transpile(hlsl: String, type: ShaderType, presetName: String) -> TranspileResult? {
        // 1. Extract shader_body content
        guard let body = extractShaderBody(from: hlsl) else {
            print("[ShaderTranspiler] Failed to extract shader_body from \(type) shader in '\(presetName)'")
            return nil
        }

        // 2. Apply HLSL → Metal transformations
        let transformed = applyTransformations(body)

        // 3. Generate a stable function name
        let safeName = presetName
            .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)
            .prefix(40)
        let funcName = "v2_\(type == .warp ? "warp" : "comp")_\(safeName)"

        // 4. Wrap in Metal function with preamble
        let metalSource = buildMetalSource(body: transformed, type: type, functionName: funcName)

        return TranspileResult(metalSource: metalSource, functionName: funcName)
    }

    // MARK: - Extract shader_body

    /// Returns (pre-body declarations, body content).
    /// Pre-body declarations are variable declarations before shader_body that need to be preserved.
    private static func extractShaderBody(from hlsl: String) -> String? {
        guard let bodyRange = hlsl.range(of: "shader_body") else { return nil }

        // Capture pre-body variable declarations (lines before shader_body)
        let prebody = String(hlsl[hlsl.startIndex..<bodyRange.lowerBound])
        var preDeclarations = ""
        for line in prebody.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Keep float/float2/float3/float4 variable declarations, skip sampler decls
            if trimmed.hasPrefix("float") && trimmed.contains(";") && !trimmed.contains("sampler") {
                preDeclarations += trimmed + "\n"
            }
        }

        let afterBody = hlsl[bodyRange.upperBound...]
        guard let openBrace = afterBody.firstIndex(of: "{") else { return nil }

        // Find matching close brace using brace counting
        var depth = 0
        var closeIndex: String.Index? = nil
        var i = openBrace
        while i < hlsl.endIndex {
            let ch = hlsl[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { closeIndex = i; break }
            }
            i = hlsl.index(after: i)
        }

        guard let close = closeIndex else { return nil }
        let bodyContent = String(hlsl[hlsl.index(after: openBrace)..<close])

        // Combine: pre-declarations + body
        return preDeclarations + bodyContent
    }

    // MARK: - HLSL → Metal Transformations

    private static func applyTransformations(_ body: String) -> String {
        var s = body

        // Remove sampler declarations (handled by function args)
        s = s.replacingOccurrences(
            of: #"(?m)^\s*sampler\s+sampler_\w+\s*;\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Remove variable declarations that appear before shader_body
        // (float3 ret; is declared in preamble, float3 color; etc. are user vars)
        // Only strip re-declarations of 'ret'
        s = s.replacingOccurrences(
            of: #"(?m)^\s*float3\s+ret\s*;\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Remove standalone variable/sampler declarations that leaked through
        s = s.replacingOccurrences(
            of: #"(?m)^\s*float[234]?\s+texsize_\w+\s*;\s*$"#,
            with: "",
            options: .regularExpression
        )

        // HLSL float1 → Metal float
        s = s.replacingOccurrences(
            of: #"\bfloat1\b"#,
            with: "float",
            options: .regularExpression
        )

        // lerp → mix
        s = s.replacingOccurrences(
            of: #"\blerp\b"#,
            with: "mix",
            options: .regularExpression
        )

        // frac → fract
        s = s.replacingOccurrences(
            of: #"\bfrac\b"#,
            with: "fract",
            options: .regularExpression
        )

        // ddx → dfdx, ddy → dfdy
        s = s.replacingOccurrences(
            of: #"\bddx\b"#,
            with: "dfdx",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\bddy\b"#,
            with: "dfdy",
            options: .regularExpression
        )

        // tex2D(sampler_XX, uv) → tex_XX.sample(samp_XX, uv)
        s = transformTexSampling(s, funcName: "tex2D")

        // tex3D(sampler_XX, uvw) → tex_XX.sample(samp_XX, uvw)
        s = transformTexSampling(s, funcName: "tex3D")

        // mul(a, b) → (a * b)
        s = transformMul(s)

        // float2x2(a,b,c,d) → _md_float2x2(a,b,c,d)
        s = s.replacingOccurrences(
            of: #"\bfloat2x2\s*\("#,
            with: "_md_float2x2(",
            options: .regularExpression
        )

        // float3x3(args) → _md_float3x3(args)
        s = s.replacingOccurrences(
            of: #"\bfloat3x3\s*\("#,
            with: "_md_float3x3(",
            options: .regularExpression
        )

        // GetPixel(uv) → _md_GetPixel(uv)
        s = s.replacingOccurrences(
            of: #"\bGetPixel\b"#,
            with: "_md_GetPixel",
            options: .regularExpression
        )

        // GetBlur1/2/3 → _md_GetBlur1/2/3
        s = s.replacingOccurrences(
            of: #"\bGetBlur1\b"#,
            with: "_md_GetBlur1",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\bGetBlur2\b"#,
            with: "_md_GetBlur2",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\bGetBlur3\b"#,
            with: "_md_GetBlur3",
            options: .regularExpression
        )

        // lum(x) → _md_lum(x)
        s = s.replacingOccurrences(
            of: #"\blum\b"#,
            with: "_md_lum",
            options: .regularExpression
        )

        // Handle HLSL implicit truncation for known float4 uniforms used as scalars.
        // When these appear in arithmetic without a swizzle, HLSL auto-truncates.
        // We handle this by inserting explicit swizzles where needed.
        s = fixImplicitTruncation(s)

        return s
    }

    // MARK: - tex2D / tex3D Transformation

    /// Transforms `tex2D(sampler_XX, <uv_expr>)` → `tex_XX.sample(samp_XX, <uv_expr>)`
    /// Uses balanced-parenthesis parsing to correctly handle nested expressions.
    private static func transformTexSampling(_ source: String, funcName: String) -> String {
        var result = ""
        let chars = Array(source.unicodeScalars)
        var i = 0

        while i < chars.count {
            // Try to match funcName + "("
            if matchWord(chars, at: i, word: funcName),
               let parenStart = skipWhitespace(chars, from: i + funcName.count),
               parenStart < chars.count && chars[parenStart] == "(" {

                // Find the sampler argument (first arg before comma)
                let argsStart = parenStart + 1
                if let (samplerName, commaIdx) = extractFirstArg(chars, from: argsStart) {
                    let trimmedSampler = samplerName.trimmingCharacters(in: .whitespaces)
                    // Find closing paren with balanced counting
                    if let closeIdx = findMatchingParen(chars, from: parenStart) {
                        let uvExprScalars = chars[(commaIdx + 1)..<closeIdx]
                        let uvExpr = String(String.UnicodeScalarView(uvExprScalars)).trimmingCharacters(in: .whitespaces)

                        // Parse sampler name: sampler_[fw|pw|fc|pc]_texturename
                        let (texName, sampMode) = parseSamplerName(trimmedSampler)

                        // Check if original code already has a swizzle (e.g. `.xyz`, `.x`)
                        let afterClose = closeIdx + 1
                        if afterClose < chars.count && chars[afterClose] == "." {
                            // There's a swizzle — use that instead of adding .xyz
                            var swizzleEnd = afterClose + 1
                            while swizzleEnd < chars.count && (chars[swizzleEnd] >= "a" && chars[swizzleEnd] <= "z") {
                                swizzleEnd += 1
                            }
                            let swizzle = String(String.UnicodeScalarView(Array(chars[afterClose..<swizzleEnd])))
                            result += "tex_\(texName).sample(samp_\(sampMode), \(uvExpr))\(swizzle)"
                            i = swizzleEnd
                        } else {
                            // No swizzle — append .xyz since HLSL expects float3 from tex2D
                            result += "tex_\(texName).sample(samp_\(sampMode), \(uvExpr)).xyz"
                            i = closeIdx + 1
                        }
                        continue
                    }
                }
            }

            result.append(Character(chars[i]))
            i += 1
        }
        return result
    }

    /// Parses `sampler_XX` into (texture_name, sampler_mode).
    /// `sampler_main` → ("main", "fw")          (default filter+wrap)
    /// `sampler_fw_main` → ("main", "fw")
    /// `sampler_pc_noise_lq` → ("noise_lq", "pc")
    private static func parseSamplerName(_ name: String) -> (texName: String, sampMode: String) {
        var rest = name
        if rest.hasPrefix("sampler_") {
            rest = String(rest.dropFirst("sampler_".count))
        }

        // Check for mode prefix: fw_, pw_, fc_, pc_
        let modes = ["fw_", "pw_", "fc_", "pc_"]
        for mode in modes {
            if rest.hasPrefix(mode) {
                let texName = String(rest.dropFirst(mode.count))
                return (texName, String(mode.dropLast()))
            }
        }

        // No mode prefix — default to fw (linear filter, wrap)
        return (rest, "fw")
    }

    // MARK: - mul() Transformation

    /// Transforms `mul(a, b)` → `((a) * (b))` using balanced-paren parsing.
    private static func transformMul(_ source: String) -> String {
        var result = ""
        let chars = Array(source.unicodeScalars)
        var i = 0

        while i < chars.count {
            if matchWord(chars, at: i, word: "mul"),
               let parenStart = skipWhitespace(chars, from: i + 3),
               parenStart < chars.count && chars[parenStart] == "(" {

                if let closeIdx = findMatchingParen(chars, from: parenStart) {
                    let argsStart = parenStart + 1
                    if let (firstArg, commaIdx) = extractFirstArg(chars, from: argsStart) {
                        let secondArgScalars = chars[(commaIdx + 1)..<closeIdx]
                        let secondArg = String(String.UnicodeScalarView(secondArgScalars)).trimmingCharacters(in: .whitespaces)

                        result += "((\(firstArg.trimmingCharacters(in: .whitespaces))) * (\(secondArg)))"
                        i = closeIdx + 1
                        continue
                    }
                }
            }

            result.append(Character(chars[i]))
            i += 1
        }
        return result
    }

    // MARK: - HLSL Implicit Truncation Fix

    /// HLSL allows implicit narrowing: float4→float, float4→float3, float2→float.
    /// Metal does not. This pass adds explicit swizzles for known patterns.
    private static func fixImplicitTruncation(_ source: String) -> String {
        var s = source

        // 1. Known float4 uniforms used without swizzle in scalar/float3 context.
        //    Pattern: `rand_frame` not followed by `.` or `[` → `rand_frame.x`
        //    This handles `rand_frame * 64` (scalar usage) common in presets.
        let float4Uniforms = ["rand_frame", "rand_preset"]
        for name in float4Uniforms {
            // Replace standalone usage (not followed by `.` or `[`) with `.x`
            // But preserve when followed by swizzle like `.xy` or `.x`
            s = s.replacingOccurrences(
                of: "\\b\(name)\\b(?!\\s*[.\\[])",
                with: "\(name).x",
                options: .regularExpression
            )
        }

        // 2. `roam_cos` and `roam_sin` used as float3 (e.g. `mus *= roam_cos`)
        //    These are float4 but commonly used in float3 arithmetic.
        //    Add `.xyz` when not followed by swizzle.
        let float4AsFloat3 = ["roam_cos", "roam_sin"]
        for name in float4AsFloat3 {
            s = s.replacingOccurrences(
                of: "\\b\(name)\\b(?!\\s*[.\\[])",
                with: "\(name).xyz",
                options: .regularExpression
            )
        }

        // 3. Handle `texsize.xy * texsize_noise_XX.zw` → scalar result
        s = s.replacingOccurrences(
            of: #"\btexsize\.xy\s*\*\s*texsize_(\w+)\.zw\b"#,
            with: "texsize.x * texsize_$1.z",
            options: .regularExpression
        )

        // 4. Fix scalar assignments from vector expressions.
        s = fixScalarAssignments(s)

        // 5. Fix float3+float2 mixed arithmetic by promoting float2 expressions.
        //    When a `float2(` constructor or known float2 var appears in `+` or `-`
        //    with a float3 expression, wrap in float3(..., 0).
        s = fixMixedVectorArithmetic(s)

        return s
    }

    /// Fix mixed float3+float2 arithmetic by promoting float2 expressions
    /// to float3 when they appear in arithmetic with float3 expressions.
    private static func fixMixedVectorArithmetic(_ source: String) -> String {
        var s = source

        // Promote known float2 variables to float3 in lines that mix float2 and float3 types.
        s = promoteFloat2Variables(s)

        return s
    }

    /// For lines that mix float3 and float2 in arithmetic (outside of sample() calls),
    /// promote float2 sub-expressions to float3.
    /// Only applies to lines with direct `+`/`-` between float3 and float2 terms.
    private static func promoteFloat2Variables(_ source: String) -> String {
        let float2VarNames: Set<String> = ["uv", "uv1", "uv2", "uv_orig", "uv6"]
        var lines = source.components(separatedBy: "\n")

        var float3Vars: Set<String> = ["ret", "ret1", "ret2", "color", "blur", "crisp"]
        var float2Vars: Set<String> = float2VarNames

        for lineIdx in 0..<lines.count {
            let trimmed = lines[lineIdx].trimmingCharacters(in: .whitespaces)

            // Track float3 declarations
            if trimmed.hasPrefix("float3 ") {
                let rest = String(trimmed.dropFirst(7))
                let varName = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if !varName.isEmpty { float3Vars.insert(varName) }
            }
            // Track float2 declarations
            if trimmed.hasPrefix("float2 ") {
                let rest = String(trimmed.dropFirst(7))
                let varName = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if !varName.isEmpty { float2Vars.insert(varName) }
            }

            // Only process lines that are:
            // 1. Assignments to `ret` with `=` (not +=, which usually is sample-based)
            // 2. Multi-line continuations starting with `+` or `-`
            let isRetAssign = trimmed.hasPrefix("ret =") || trimmed.hasPrefix("ret=")
            let isContinuation = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")

            guard isRetAssign || isContinuation else { continue }

            // Check line has both float3 and float2 vars (outside sample calls)
            let lineContent = lines[lineIdx]
            // Strip out sample(...) calls to check for mixed types in remaining expression
            let strippedLine = lineContent.replacingOccurrences(
                of: #"\.sample\([^)]*\)"#,
                with: ".SAMPLE_REMOVED",
                options: .regularExpression
            )

            let hasFloat3 = float3Vars.contains(where: { name in
                strippedLine.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
            })
            let hasFloat2 = float2Vars.contains(where: { name in
                strippedLine.range(of: "\\b\(name)\\b(?!\\s*[.\\[=])", options: .regularExpression) != nil
            })

            if hasFloat3 && hasFloat2 {
                var line = lines[lineIdx]
                // Only wrap float2 vars that are NOT inside .sample() or _md_Get* calls
                // Simple heuristic: wrap them everywhere, which is fine for `ret =` lines
                // since the whole line is being assigned to float3
                for varName in float2Vars {
                    line = line.replacingOccurrences(
                        of: "(?<!float2 |float2\\t|_md_f3\\()\\b\(varName)\\b(?!\\s*[.\\[=])",
                        with: "_md_f3(\(varName))",
                        options: .regularExpression
                    )
                }
                // Also wrap float2(...) constructors
                line = line.replacingOccurrences(
                    of: #"(?<!_md_f3\()(?<!float3\()float2\s*\("#,
                    with: "_md_f3(float2(",
                    options: .regularExpression
                )
                line = closeF3Wrappers(line)
                lines[lineIdx] = line
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Close _md_f3(float2(...)) wrappers by adding the extra closing paren.
    private static func closeF3Wrappers(_ line: String) -> String {
        var result = ""
        let marker = "_md_f3(float2("
        var remaining = line[line.startIndex...]

        while let range = remaining.range(of: marker) {
            result += remaining[remaining.startIndex..<range.lowerBound]
            result += marker

            let afterFloat2Open = range.upperBound
            var depth = 1
            var idx = afterFloat2Open
            while idx < remaining.endIndex && depth > 0 {
                if remaining[idx] == "(" { depth += 1 }
                else if remaining[idx] == ")" { depth -= 1 }
                if depth > 0 { idx = remaining.index(after: idx) }
            }

            if idx < remaining.endIndex {
                result += remaining[afterFloat2Open...idx]
                result += ")"
                remaining = remaining[remaining.index(after: idx)...]
            } else {
                result += remaining[afterFloat2Open...]
                remaining = remaining[remaining.endIndex...]
            }
        }
        result += remaining
        return result
    }

    /// Detects lines like `float x = sin((uv1-q12)*q27);` where the RHS
    /// likely returns a vector type (because it operates on known float2/float3/float4 variables)
    /// and the LHS is a scalar `float`. Appends `.x` to the RHS expression.
    ///
    /// Smart enough to skip cases where the float2 var is inside a scalar-returning function
    /// like `length()`, `dot()`, `distance()`, etc.
    private static func fixScalarAssignments(_ source: String) -> String {
        // Known float2 variable names that appear in shader code
        let knownFloat2Vars = ["uv", "uv1", "uv2", "uv_orig", "uv6"]
        // Functions that always return a scalar regardless of input vector type
        let scalarReturningFuncs = ["length", "dot", "distance", "_md_lum", "atan2"]
        let pattern = #"(?m)^(\s*float\s+\w+\s*=\s*)(.+?)\s*;\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }

        let nsSource = source as NSString
        var result = source
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        // Process in reverse to preserve indices
        for match in matches.reversed() {
            let rhsRange = match.range(at: 2)
            let rhs = nsSource.substring(with: rhsRange)

            // Check if RHS contains a known float2 variable (indicating vector result)
            let containsVector = knownFloat2Vars.contains { name in
                rhs.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
            }

            if containsVector {
                // Check if every occurrence of every float2 var is either:
                // a) followed by a scalar swizzle (.x, .y, etc.)
                // b) inside a scalar-returning function call (length, dot, etc.)
                let allScalarContext = knownFloat2Vars.allSatisfy { name in
                    guard let varRegex = try? NSRegularExpression(pattern: "\\b\(name)\\b") else { return true }
                    let varMatches = varRegex.matches(in: rhs, range: NSRange(location: 0, length: (rhs as NSString).length))
                    if varMatches.isEmpty { return true } // var not present, skip

                    return varMatches.allSatisfy { varMatch in
                        let matchEnd = varMatch.range.location + varMatch.range.length
                        let nsRhs = rhs as NSString

                        // Case a: followed by scalar swizzle (.x, .y, .z, .w)
                        if matchEnd + 1 < nsRhs.length {
                            let afterChar = nsRhs.substring(with: NSRange(location: matchEnd, length: 1))
                            if afterChar == "." {
                                let swizzleChar = nsRhs.substring(with: NSRange(location: matchEnd + 1, length: 1))
                                if ["x", "y", "z", "w"].contains(swizzleChar) {
                                    return true
                                }
                            }
                        }

                        // Case b: inside a scalar-returning function call
                        // Look backwards from the var match to find if it's inside func(...)
                        let textBefore = nsRhs.substring(to: varMatch.range.location)
                        if isInsideScalarFunction(textBefore, scalarFuncs: scalarReturningFuncs) {
                            return true
                        }

                        return false
                    }
                }

                if !allScalarContext {
                    // RHS contains un-swizzled float2 var in vector context → result is likely vector
                    // Wrap the expression to extract .x
                    let fullRange = match.range(at: 0)
                    let lhs = nsSource.substring(with: match.range(at: 1))
                    let newLine = "\(lhs)(\(rhs)).x;"
                    result = (result as NSString).replacingCharacters(in: fullRange, with: newLine)
                }
            }
        }
        return result
    }

    /// Check if a position (given the text before it) is inside a scalar-returning function call.
    /// We look backwards for an unclosed `funcname(` pattern.
    private static func isInsideScalarFunction(_ textBefore: String, scalarFuncs: [String]) -> Bool {
        // Count open vs close parens going backwards to find unclosed open parens
        // At each unclosed open paren, check if it's preceded by a scalar-returning function name
        var depth = 0
        let chars = Array(textBefore.unicodeScalars.reversed())

        for (idx, ch) in chars.enumerated() {
            if ch == ")" { depth += 1 }
            else if ch == "(" {
                if depth > 0 {
                    depth -= 1
                } else {
                    // This is an unclosed open paren — check what precedes it
                    let beforeParen = String(String.UnicodeScalarView(chars[(idx+1)...].reversed()))
                    let trimmed = beforeParen.trimmingCharacters(in: .whitespaces)
                    for funcName in scalarFuncs {
                        if trimmed.hasSuffix(funcName) {
                            // Verify it's a whole word (not e.g. "my_length")
                            let prefixLen = trimmed.count - funcName.count
                            if prefixLen == 0 { return true }
                            let charBefore = trimmed[trimmed.index(trimmed.startIndex, offsetBy: prefixLen - 1)]
                            if !charBefore.isLetter && !charBefore.isNumber && charBefore != "_" {
                                return true
                            }
                        }
                    }
                    // Found an unclosed paren but it's not a scalar function — keep looking
                    // (the var might be in nested parens inside the scalar function)
                    // Don't break; continue checking outer unclosed parens
                }
            }
        }
        return false
    }

    // MARK: - Parsing Helpers

    /// Check if `word` appears at position `pos` as a whole word (not preceded by alphanumeric/_).
    private static func matchWord(_ chars: [Unicode.Scalar], at pos: Int, word: String) -> Bool {
        let wordChars = Array(word.unicodeScalars)
        guard pos + wordChars.count <= chars.count else { return false }

        // Check preceding char is not alphanumeric or underscore
        if pos > 0 {
            let prev = chars[pos - 1]
            if prev.isAlphaNumericOrUnderscore { return false }
        }

        // Match the word
        for j in 0..<wordChars.count {
            if chars[pos + j] != wordChars[j] { return false }
        }

        // Check following char is not alphanumeric or underscore (unless it's opening paren or whitespace)
        let afterPos = pos + wordChars.count
        if afterPos < chars.count {
            let next = chars[afterPos]
            if next.isAlphaNumericOrUnderscore { return false }
        }

        return true
    }

    /// Skip whitespace starting at `from`, return index of first non-whitespace.
    private static func skipWhitespace(_ chars: [Unicode.Scalar], from: Int) -> Int? {
        var i = from
        while i < chars.count && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r") {
            i += 1
        }
        return i
    }

    /// Find the index of the closing paren matching the open paren at `openPos`.
    private static func findMatchingParen(_ chars: [Unicode.Scalar], from openPos: Int) -> Int? {
        guard openPos < chars.count && chars[openPos] == "(" else { return nil }
        var depth = 0
        var i = openPos
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            else if chars[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Extract the first comma-separated argument from `startIdx`.
    /// Returns the argument string and the index of the comma.
    /// Respects nested parentheses.
    private static func extractFirstArg(_ chars: [Unicode.Scalar], from startIdx: Int) -> (String, Int)? {
        var depth = 0
        var i = startIdx
        while i < chars.count {
            let ch = chars[i]
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1 }
            else if ch == "," && depth == 0 {
                let argScalars = chars[startIdx..<i]
                return (String(String.UnicodeScalarView(argScalars)), i)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Metal Source Generation

    private static func buildMetalSource(body: String, type: ShaderType, functionName: String) -> String {
        let stageIn: String
        let uvSetup: String

        switch type {
        case .warp:
            stageIn = """
            struct WarpV2In {
                float4 position [[position]];
                float4 color;
                float2 uv;
                float2 uv_orig;
                float2 rad_ang;
            };
            """
            uvSetup = """
                float2 uv = _in.uv;
                float2 uv_orig = _in.uv_orig;
                float rad = _in.rad_ang.x;
                float ang = _in.rad_ang.y;
            """

        case .composite:
            stageIn = """
            struct CompV2In {
                float4 position [[position]];
                float2 uv;
            };
            """
            uvSetup = """
                float2 uv = _in.uv;
                float2 uv_orig = _in.uv;
                // Compute rad/ang for composite (from center)
                float2 _centered = uv - 0.5;
                float rad = length(_centered) * 2.0;
                float ang = atan2(_centered.y, _centered.x);
            """
        }

        let stageInType = type == .warp ? "WarpV2In" : "CompV2In"

        return """
        #include <metal_stdlib>
        using namespace metal;

        // V2PsUniforms — must match ShaderTypes.h layout
        struct V2PsUniforms {
            float time;
            float fps;
            float frame;
            float bass;
            float mid;
            float treb;
            float bass_att;
            float mid_att;
            float treb_att;
            float _pad0;
            float _pad0b;
            float _pad0c;
            float4 aspect;
            float4 texsize;
            float4 rand_frame;
            float4 rand_preset;
            float4 roam_cos;
            float4 roam_sin;
            float4 _qa;
            float4 _qb;
            float4 _qc;
            float4 _qd;
            float4 _qe;
            float4 _qf;
            float4 _qg;
            float4 _qh;
            float decay;
            float _pad1;
            float _pad2;
            float _pad3;
        };

        \(stageIn)

        // Helper: row-major float2x2 constructor (HLSL is row-major, Metal is column-major)
        static float2x2 _md_float2x2(float a, float b, float c, float d) {
            return float2x2(float2(a, c), float2(b, d));
        }

        // Helper: row-major float3x3 constructor
        static float3x3 _md_float3x3(float a, float b, float c,
                                       float d, float e, float f,
                                       float g, float h, float i) {
            return float3x3(float3(a, d, g), float3(b, e, h), float3(c, f, i));
        }

        // Helper: luminance
        static float _md_lum(float3 c) {
            return dot(c, float3(0.32, 0.49, 0.29));
        }
        static float _md_lum(float c) {
            return c;
        }

        // Helpers for HLSL-style implicit float2→float3 conversion
        static float3 _md_f3(float2 v) { return float3(v, 0); }
        static float3 _md_f3(float3 v) { return v; }
        static float3 _md_f3(float v) { return float3(v); }

        fragment float4 \(functionName)(
            \(stageInType) _in [[stage_in]],
            constant V2PsUniforms& u [[buffer(0)]],
            texture2d<float> tex_main [[texture(0)]],
            texture2d<float> tex_blur1 [[texture(1)]],
            texture2d<float> tex_blur2 [[texture(2)]],
            texture2d<float> tex_blur3 [[texture(3)]],
            texture2d<float> tex_noise_lq [[texture(4)]],
            texture2d<float> tex_noise_mq [[texture(5)]],
            texture2d<float> tex_noise_hq [[texture(6)]],
            texture3d<float> tex_noisevol_lq [[texture(7)]],
            texture3d<float> tex_noisevol_hq [[texture(8)]])
        {
            // Samplers: 4 combinations of filter × address mode
            constexpr sampler samp_fw(mag_filter::linear, min_filter::linear, address::repeat);
            constexpr sampler samp_pw(mag_filter::nearest, min_filter::nearest, address::repeat);
            constexpr sampler samp_fc(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            constexpr sampler samp_pc(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);

            // Unpack uniforms
            float time = u.time;
            float fps = u.fps;
            float frame = u.frame;
            float bass = u.bass;
            float mid = u.mid;
            float treb = u.treb;
            float bass_att = u.bass_att;
            float mid_att = u.mid_att;
            float treb_att = u.treb_att;
            float4 aspect = u.aspect;
            float4 texsize = u.texsize;
            float4 rand_frame = u.rand_frame;
            float4 rand_preset = u.rand_preset;
            float4 roam_cos = u.roam_cos;
            float4 roam_sin = u.roam_sin;
            float decay = u.decay;

            // Noise texture sizes (fixed, matching TextureManager)
            float4 texsize_noise_lq = float4(256.0, 256.0, 1.0/256.0, 1.0/256.0);
            float4 texsize_noise_mq = float4(256.0, 256.0, 1.0/256.0, 1.0/256.0);
            float4 texsize_noise_hq = float4(256.0, 256.0, 1.0/256.0, 1.0/256.0);
            float4 texsize_noisevol_lq = float4(32.0, 32.0, 1.0/32.0, 1.0/32.0);
            float4 texsize_noisevol_hq = float4(32.0, 32.0, 1.0/32.0, 1.0/32.0);

            // Unpack q1..q32
            float q1 = u._qa.x, q2 = u._qa.y, q3 = u._qa.z, q4 = u._qa.w;
            float q5 = u._qb.x, q6 = u._qb.y, q7 = u._qb.z, q8 = u._qb.w;
            float q9 = u._qc.x, q10 = u._qc.y, q11 = u._qc.z, q12 = u._qc.w;
            float q13 = u._qd.x, q14 = u._qd.y, q15 = u._qd.z, q16 = u._qd.w;
            float q17 = u._qe.x, q18 = u._qe.y, q19 = u._qe.z, q20 = u._qe.w;
            float q21 = u._qf.x, q22 = u._qf.y, q23 = u._qf.z, q24 = u._qf.w;
            float q25 = u._qg.x, q26 = u._qg.y, q27 = u._qg.z, q28 = u._qg.w;
            float q29 = u._qh.x, q30 = u._qh.y, q31 = u._qh.z, q32 = u._qh.w;

            // UV setup from stage-in
        \(uvSetup)

            // Built-in macros — use .xy to extract UV, handling both float2 and float3 args
            #define _md_GetPixel(UV) (tex_main.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur1(UV) (tex_blur1.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur2(UV) (tex_blur2.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur3(UV) (tex_blur3.sample(samp_fw, float2((UV).x, (UV).y)).xyz)

            // Output variable (user code writes to this)
            float3 ret = float3(0.0);

            // --- User shader body ---
        \(body)
            // --- End user shader body ---

            #undef _md_GetPixel
            #undef _md_GetBlur1
            #undef _md_GetBlur2
            #undef _md_GetBlur3

            return float4(saturate(ret), 1.0);
        }
        """
    }
}

// MARK: - Unicode.Scalar Extension

private extension Unicode.Scalar {
    var isAlphaNumericOrUnderscore: Bool {
        (self >= "a" && self <= "z") ||
        (self >= "A" && self <= "Z") ||
        (self >= "0" && self <= "9") ||
        self == "_"
    }
}
