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

        // 3. Hoist any inline helper function definitions out of the body
        let (cleanBody, hoistedFunctions) = extractHelperFunctions(from: transformed)

        // 4. Generate a stable function name
        let safeName = presetName
            .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)
            .prefix(40)
        let funcName = "v2_\(type == .warp ? "warp" : "comp")_\(safeName)"

        // 5. Wrap in Metal function with preamble
        let metalSource = buildMetalSource(body: cleanBody, type: type, functionName: funcName, hoistedFunctions: hoistedFunctions)

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

        // Fix float4 declarations initialized from .xyz texture samples.
        // Our tex sampling transform appends .xyz (float3), but HLSL code may
        // declare the variable as float4. Downgrade to float3.
        s = fixFloat4FromXyzSample(s)

        // Fix variable redefinitions: when a variable is declared in pre-body
        // (e.g. `float3 neu, ret1;`) and then re-declared in body
        // (e.g. `float3 ret1 = 0;`), convert the second to an assignment.
        s = fixVariableRedefinitions(s)

        // Handle HLSL implicit truncation for known float4 uniforms used as scalars.
        // When these appear in arithmetic without a swizzle, HLSL auto-truncates.
        // We handle this by inserting explicit swizzles where needed.
        s = fixImplicitTruncation(s)

        // Convert HLSL `%` modulo operator to Metal `fmod()`.
        // HLSL allows `%` on float operands; Metal requires `fmod()`.
        s = convertModuloToFmod(s)

        // Fix HLSL vector comparisons that produce bool vectors.
        // HLSL: `(vec >= 0)` yields a float vector (0.0/1.0).
        // Metal: `(vec >= 0)` yields a bool vector which can't be assigned to float.
        // Convert `expr >= val` to `step(val, expr)` and `expr <= val` to `step(expr, val)`.
        s = fixVectorComparisons(s)

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

    // MARK: - Type / Swizzle Mismatch Fix

    /// Fix mismatches between declared type and the swizzle on the RHS.
    /// The tex sampling transform appends `.xyz` (float3), but HLSL code may
    /// declare the variable as float4, float2, or float.
    ///   - `float4 x = ...sample(...).xyz;`  → change decl to `float3`
    ///   - `float2 x = ...sample(...).xyz;`  → change `.xyz` to `.xy`
    ///   - `float x  = ...sample(...).xyz;`  → change `.xyz` to `.x`
    /// Also handles assignments (not just declarations).
    private static func fixFloat4FromXyzSample(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // Determine the declared type (float4, float3, float2, or float)
            var declType: String?
            for t in ["float4 ", "float3 ", "float2 ", "float "] {
                if trimmed.hasPrefix(t) && trimmed.contains("=") {
                    declType = String(t.dropLast()) // remove trailing space
                    break
                }
            }

            guard let declType else {
                i += 1
                continue
            }

            // Collect the full statement up to the semicolon
            var stmtEnd = i
            var combined = trimmed
            while !combined.contains(";") && stmtEnd + 1 < lines.count {
                stmtEnd += 1
                combined += " " + lines[stmtEnd].trimmingCharacters(in: .whitespaces)
            }

            // Check if the RHS ends with .xyz before the semicolon
            let beforeSemicolon = combined.components(separatedBy: ";").first ?? combined
            let rhsTrimmed = beforeSemicolon.trimmingCharacters(in: .whitespaces)
            if rhsTrimmed.hasSuffix(".xyz") {
                switch declType {
                case "float4":
                    // float4 = ...xyz → downgrade decl to float3
                    lines[i] = lines[i].replacingOccurrences(of: "float4 ", with: "float3 ", options: [], range: lines[i].range(of: "float4 "))
                case "float2":
                    // float2 = ...xyz → change swizzle to .xy
                    // Find the last .xyz on the statement's last line and replace it
                    for j in stride(from: stmtEnd, through: i, by: -1) {
                        if let range = lines[j].range(of: ".xyz", options: .backwards) {
                            lines[j] = lines[j].replacingCharacters(in: range, with: ".xy")
                            break
                        }
                    }
                case "float":
                    // float = ...xyz → change swizzle to .x
                    for j in stride(from: stmtEnd, through: i, by: -1) {
                        if let range = lines[j].range(of: ".xyz", options: .backwards) {
                            lines[j] = lines[j].replacingCharacters(in: range, with: ".x")
                            break
                        }
                    }
                default:
                    break
                }
            }

            i = stmtEnd + 1
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Variable Redefinition Fix

    /// HLSL (and some Milkdrop presets) declare variables in pre-body
    /// (e.g. `float3 neu, ret1;`) then re-declare them inside the body
    /// (e.g. `float3 ret1 = 0;`). Metal/C++ doesn't allow this in the same scope.
    /// This pass tracks declared variable names and converts re-declarations to assignments.
    private static func fixVariableRedefinitions(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        // Track all declared variable names and their types
        var declaredVars: [String: String] = [:]  // varName -> type

        // Pattern to match declarations: `float3 varname` or `float2 a, b, c;`
        let declPattern = #"(?m)^\s*(float[234]?|int|bool)\s+(.+?)\s*;"#
        guard let declRegex = try? NSRegularExpression(pattern: declPattern) else { return source }

        for lineIdx in 0..<lines.count {
            let line = lines[lineIdx]
            let nsLine = line as NSString
            let matches = declRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

            for match in matches {
                let type = nsLine.substring(with: match.range(at: 1))
                let varsSection = nsLine.substring(with: match.range(at: 2))

                // Parse variable names from comma-separated list, handling initializers
                let parts = varsSection.components(separatedBy: ",")
                for part in parts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    // Extract just the variable name (before any `=` or space)
                    let varName = String(trimmed.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                    if varName.isEmpty { continue }

                    if declaredVars[varName] != nil {
                        // This variable was already declared — convert to assignment
                        // Replace `float3 ret1 = 0;` with `ret1 = 0;`
                        // Replace `float3 ret1;` with nothing (redundant)
                        let redeclPattern = "\\b\(NSRegularExpression.escapedPattern(for: type))\\s+\(NSRegularExpression.escapedPattern(for: varName))\\b"
                        if let redeclRegex = try? NSRegularExpression(pattern: redeclPattern) {
                            let mutableLine = NSMutableString(string: lines[lineIdx])
                            redeclRegex.replaceMatches(in: mutableLine, range: NSRange(location: 0, length: mutableLine.length), withTemplate: varName)
                            lines[lineIdx] = mutableLine as String

                            // If the line is now just `varName;` (no initializer), remove it
                            let stripped = lines[lineIdx].trimmingCharacters(in: .whitespaces)
                            if stripped == "\(varName);" || stripped == "\(varName) ;" {
                                lines[lineIdx] = ""
                            }
                        }
                    } else {
                        declaredVars[varName] = type
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
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

        // 6. Fix float3 variables used in float2 context (HLSL implicit truncation).
        //    When a float3 variable (e.g. noise from texture sample) is used in
        //    arithmetic with float2 variables, add `.xy` to truncate it.
        s = fixFloat3ToFloat2Truncation(s)

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

                // Mask out _md_GetPixel(...), _md_GetBlur1/2/3(...) args.
                // These macros expect float2 UVs — float2 vars inside should NOT be promoted.
                var masks: [(placeholder: String, original: String)] = []
                let getMacros = ["_md_GetPixel", "_md_GetBlur1", "_md_GetBlur2", "_md_GetBlur3"]
                for macro in getMacros {
                    while let macroRange = line.range(of: macro + "(") {
                        let afterOpen = macroRange.upperBound
                        // Find matching close paren
                        var depth = 1
                        var idx = afterOpen
                        while idx < line.endIndex && depth > 0 {
                            if line[idx] == "(" { depth += 1 }
                            else if line[idx] == ")" { depth -= 1 }
                            if depth > 0 { idx = line.index(after: idx) }
                        }
                        guard idx < line.endIndex else { break }
                        let closeIdx = line.index(after: idx)
                        let fullCall = String(line[macroRange.lowerBound..<closeIdx])
                        let placeholder = "___MASK\(masks.count)___"
                        masks.append((placeholder, fullCall))
                        line = line.replacingCharacters(in: macroRange.lowerBound..<closeIdx, with: placeholder)
                    }
                }

                // Wrap float2 vars in _md_f3()
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

                // Restore masked macro calls
                for mask in masks.reversed() {
                    line = line.replacingOccurrences(of: mask.placeholder, with: mask.original)
                }

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
        // Start with well-known float2 variable names, then scan for locally-declared ones
        var knownFloat2Vars = ["uv", "uv1", "uv2", "uv_orig", "uv6"]

        // Scan for locally-declared float2 variables: `float2 varname`
        let float2DeclPattern = #"(?m)\bfloat2\s+([a-zA-Z_]\w*)"#
        if let float2DeclRegex = try? NSRegularExpression(pattern: float2DeclPattern) {
            let nsSource = source as NSString
            let declMatches = float2DeclRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
            for m in declMatches {
                let varName = nsSource.substring(with: m.range(at: 1))
                if !knownFloat2Vars.contains(varName) {
                    knownFloat2Vars.append(varName)
                }
            }
        }
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

    // MARK: - Float3→Float2 Truncation

    /// When a float3 variable is used in arithmetic with float2 variables,
    /// HLSL implicitly truncates float3→float2. Metal does not.
    /// This adds `.xy` to float3 variables in float2 assignment contexts.
    private static func fixFloat3ToFloat2Truncation(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")

        // First pass: collect locally declared float2 and float3 variable names
        var float2Vars: Set<String> = ["uv", "uv1", "uv2", "uv_orig", "uv6"]
        var float3Vars: Set<String> = ["ret", "ret1", "ret2", "color", "blur", "crisp"]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("float2 ") {
                let rest = String(trimmed.dropFirst(7))
                let varName = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if !varName.isEmpty { float2Vars.insert(varName) }
            }
            if trimmed.hasPrefix("float3 ") {
                let rest = String(trimmed.dropFirst(7))
                let varName = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if !varName.isEmpty { float3Vars.insert(varName) }
            }
        }

        // Also treat texture sample results stored in non-typed vars as float3
        // e.g. `noise = tex_noise_lq.sample(...)` — noise is float3 from .xyz suffix
        // We detect `varname = tex_*.sample(` patterns
        let sampleAssignPattern = #"(?m)^\s*(\w+)\s*=\s*tex_\w+\.sample\("#
        if let regex = try? NSRegularExpression(pattern: sampleAssignPattern) {
            let nsSource = source as NSString
            let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
            for m in matches {
                let varName = nsSource.substring(with: m.range(at: 1))
                // Check the full match to see if it ends with .xyz (which makes it float3)
                // Since our tex2D transform adds .xyz, these are float3
                float3Vars.insert(varName)
            }
        }

        // Second pass: for lines that assign to a float2 var (or use float2 arithmetic),
        // truncate any float3 vars that don't already have a swizzle
        for lineIdx in 0..<lines.count {
            let trimmed = lines[lineIdx].trimmingCharacters(in: .whitespaces)

            // Detect if this line assigns to a known float2 variable
            var assignsToFloat2 = false
            for f2var in float2Vars {
                if trimmed.hasPrefix("\(f2var) =") || trimmed.hasPrefix("\(f2var)=") {
                    assignsToFloat2 = true
                    break
                }
                // Also detect `float2 varname = ...` declarations
                if trimmed.hasPrefix("float2 ") {
                    assignsToFloat2 = true
                    break
                }
            }

            guard assignsToFloat2 else { continue }

            // Check if the line references any float3 vars without a swizzle
            var line = lines[lineIdx]
            for f3var in float3Vars {
                // Don't truncate float3 vars that already have a swizzle
                // Match: word boundary + varname + NOT followed by . or [
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: f3var))\\b(?!\\s*[.\\[])"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

                let nsLine = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
                if matches.isEmpty { continue }

                // Also verify the line actually contains float2 context
                let hasFloat2Context = float2Vars.contains(where: { name in
                    line.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
                })

                if hasFloat2Context {
                    // Replace float3 var with var.xy (process in reverse to preserve indices)
                    for m in matches.reversed() {
                        let range = m.range
                        let replacement = "\(f3var).xy"
                        line = (line as NSString).replacingCharacters(in: range, with: replacement)
                    }
                }
            }
            lines[lineIdx] = line
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - HLSL Modulo → fmod()

    /// HLSL allows `%` on float operands. Metal `%` is integer-only.
    /// Converts `(expr) % (expr)` to `fmod(expr, expr)`.
    /// Uses balanced-parenthesis parsing for the left operand.
    private static func convertModuloToFmod(_ source: String) -> String {
        // Strategy: find `%` tokens that aren't inside comments,
        // then extract the left operand (scanning back) and right operand (scanning forward)
        // and replace with fmod(left, float(right))
        var lines = source.components(separatedBy: "\n")

        for lineIdx in 0..<lines.count {
            lines[lineIdx] = convertModuloInLine(lines[lineIdx])
        }

        return lines.joined(separator: "\n")
    }

    /// Convert `expr % expr` → `fmod(expr, float(expr))` in a single line.
    private static func convertModuloInLine(_ line: String) -> String {
        let chars = Array(line.unicodeScalars)
        guard chars.contains("%") else { return line }

        var result: [Unicode.Scalar] = []
        var i = 0

        while i < chars.count {
            if chars[i] == "%" {
                // Make sure it's not `%=` or `%%` or inside a comment
                let nextIdx = i + 1
                if nextIdx < chars.count && (chars[nextIdx] == "=" || chars[nextIdx] == "%") {
                    result.append(chars[i])
                    i += 1
                    continue
                }

                // Extract left operand by scanning backwards through result
                if let (leftExpr, leftStart) = extractLeftOperand(result) {
                    // Extract right operand by scanning forward
                    if let (rightExpr, rightEnd) = extractRightOperand(chars, from: nextIdx) {
                        // Replace: remove left operand from result, insert fmod(left, float(right))
                        result.removeSubrange(leftStart..<result.count)
                        let fmodExpr = "fmod(\(leftExpr), float(\(rightExpr)))"
                        result.append(contentsOf: fmodExpr.unicodeScalars)
                        i = rightEnd
                        continue
                    }
                }

                result.append(chars[i])
                i += 1
            } else {
                result.append(chars[i])
                i += 1
            }
        }

        return String(String.UnicodeScalarView(result))
    }

    /// Scan backwards from the end of `scalars` to extract the left operand of `%`.
    /// Returns the operand string and the start index in the array.
    private static func extractLeftOperand(_ scalars: [Unicode.Scalar]) -> (String, Int)? {
        var end = scalars.count - 1

        // Skip trailing whitespace
        while end >= 0 && (scalars[end] == " " || scalars[end] == "\t") {
            end -= 1
        }
        guard end >= 0 else { return nil }

        var start: Int

        if scalars[end] == ")" {
            // Balanced paren scan backwards
            var depth = 0
            start = end
            while start >= 0 {
                if scalars[start] == ")" { depth += 1 }
                else if scalars[start] == "(" { depth -= 1 }
                if depth == 0 { break }
                start -= 1
            }
            guard start >= 0 else { return nil }

            // Include any preceding function name or identifier
            var nameStart = start - 1
            while nameStart >= 0 && scalars[nameStart].isAlphaNumericOrUnderscore {
                nameStart -= 1
            }
            start = nameStart + 1
        } else if scalars[end].isAlphaNumericOrUnderscore || scalars[end] == "." {
            // Simple identifier, possibly with swizzle
            start = end
            while start > 0 && (scalars[start - 1].isAlphaNumericOrUnderscore || scalars[start - 1] == ".") {
                start -= 1
            }
        } else {
            // Number literal
            start = end
            while start > 0 && (scalars[start - 1] >= "0" && scalars[start - 1] <= "9" || scalars[start - 1] == ".") {
                start -= 1
            }
        }

        let operand = String(String.UnicodeScalarView(Array(scalars[start...end])))
        return (operand, start)
    }

    /// Scan forward from `from` to extract the right operand of `%`.
    /// Returns the operand string and the index after the operand.
    private static func extractRightOperand(_ chars: [Unicode.Scalar], from: Int) -> (String, Int)? {
        var start = from

        // Skip whitespace
        while start < chars.count && (chars[start] == " " || chars[start] == "\t") {
            start += 1
        }
        guard start < chars.count else { return nil }

        var end: Int

        if chars[start] == "(" {
            // Balanced paren scan forward
            var depth = 0
            end = start
            while end < chars.count {
                if chars[end] == "(" { depth += 1 }
                else if chars[end] == ")" { depth -= 1 }
                if depth == 0 { break }
                end += 1
            }
            guard end < chars.count else { return nil }
            end += 1 // include closing paren
        } else if chars[start].isAlphaNumericOrUnderscore {
            // Identifier or number
            end = start
            while end < chars.count && (chars[end].isAlphaNumericOrUnderscore || chars[end] == ".") {
                end += 1
            }
        } else if chars[start] == "-" || chars[start] == "+" {
            // Unary sign + number
            end = start + 1
            while end < chars.count && (chars[end] >= "0" && chars[end] <= "9" || chars[end] == ".") {
                end += 1
            }
        } else {
            return nil
        }

        let operand = String(String.UnicodeScalarView(Array(chars[start..<end])))
        return (operand, end)
    }

    // MARK: - Vector Comparison Fix

    /// HLSL allows comparisons like `(vec >= 0)` which produce a float vector (0.0 or 1.0).
    /// Metal comparisons produce bool vectors which can't be assigned to float types.
    /// Convert `(expr >= val)` to `step(val, expr)` and `(expr <= val)` to `step(expr, val)`.
    private static func fixVectorComparisons(_ source: String) -> String {
        var s = source
        // Handle `>= number` inside balanced parentheses
        s = fixComparisonOp(s, op: ">=")
        // Handle `<= number` inside balanced parentheses
        s = fixComparisonOp(s, op: "<=")
        return s
    }

    /// Find `(expr OP number)` patterns using balanced parens and replace with step().
    private static func fixComparisonOp(_ source: String, op: String) -> String {
        let chars = Array(source.unicodeScalars)
        var result: [Unicode.Scalar] = []
        var i = 0

        while i < chars.count {
            if chars[i] == "(" {
                // Find matching close paren
                if let closeIdx = findMatchingParen(chars, from: i) {
                    let inner = String(String.UnicodeScalarView(Array(chars[(i+1)..<closeIdx])))

                    // Look for ` >= number` or ` <= number` at the end
                    if let opRange = inner.range(of: op, options: .backwards) {
                        let lhs = String(inner[inner.startIndex..<opRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let rhs = String(inner[opRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                        // Check rhs is a simple number (possibly with leading dot like .7)
                        let isNumber = !rhs.isEmpty && rhs.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" })

                        // Also ensure the operator isn't inside nested parens in lhs
                        // (check lhs has balanced parens)
                        let lhsParensBalanced = lhs.filter({ $0 == "(" }).count == lhs.filter({ $0 == ")" }).count

                        if isNumber && lhsParensBalanced {
                            let replacement: String
                            if op == ">=" {
                                replacement = "step(\(rhs), \(lhs))"
                            } else {
                                replacement = "step(\(lhs), \(rhs))"
                            }
                            result.append(contentsOf: replacement.unicodeScalars)
                            i = closeIdx + 1
                            continue
                        }
                    }
                }
            }

            result.append(chars[i])
            i += 1
        }

        return String(String.UnicodeScalarView(result))
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

    // MARK: - Helper Function → Macro Conversion

    /// Detects inline function definitions in the shader body (e.g. `float3 Get1(float2 uvi) { ... }`)
    /// and converts them to preprocessor macros, since Metal doesn't allow nested function definitions.
    /// These helpers often reference textures/samplers from the enclosing fragment scope, so they
    /// can't simply be hoisted — macros expand inline and inherit the calling scope.
    /// Returns (body with functions replaced by macros, array of #define strings to place before body).
    private static func extractHelperFunctions(from body: String) -> (body: String, hoisted: [String]) {
        var macros: [String] = []
        var cleanLines: [String] = []

        let lines = body.components(separatedBy: "\n")
        var i = 0

        // Pattern: type name(params) { ... }
        // Matches: float3 Get1 (float2 uvi) {
        let funcDefPattern = #"^\s*(float[234]?|int|void|bool|half[234]?)\s+([a-zA-Z_]\w*)\s*\(([^)]*)\)\s*\{"#
        let funcDefRegex = try? NSRegularExpression(pattern: funcDefPattern)

        while i < lines.count {
            let line = lines[i]
            let nsLine = line as NSString
            let match = funcDefRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length))

            if let match, match.numberOfRanges >= 4 {
                let returnType = nsLine.substring(with: match.range(at: 1))
                let funcName = nsLine.substring(with: match.range(at: 2))
                let paramsRaw = nsLine.substring(with: match.range(at: 3))

                // Collect the full function body until matching close brace
                var funcSource = line
                var braceDepth = 0
                for ch in line { if ch == "{" { braceDepth += 1 } else if ch == "}" { braceDepth -= 1 } }

                var j = i + 1
                while braceDepth > 0 && j < lines.count {
                    funcSource += "\n" + lines[j]
                    for ch in lines[j] { if ch == "{" { braceDepth += 1 } else if ch == "}" { braceDepth -= 1 } }
                    j += 1
                }

                // Extract just the body between { and }
                if let openBrace = funcSource.firstIndex(of: "{"),
                   let closeBrace = funcSource.lastIndex(of: "}") {
                    var innerBody = String(funcSource[funcSource.index(after: openBrace)..<closeBrace])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // Parse parameter names for macro args
                    let paramNames = paramsRaw.components(separatedBy: ",").compactMap { param -> String? in
                        let trimmed = param.trimmingCharacters(in: .whitespaces)
                        // "float2 uvi" → "uvi"
                        let parts = trimmed.components(separatedBy: .whitespaces)
                        return parts.last.flatMap { $0.isEmpty ? nil : $0 }
                    }

                    // If body is a single `return expr;` statement, extract just the expr
                    let returnPattern = #"^\s*return\s+(.*?)\s*;\s*$"#
                    if let returnRegex = try? NSRegularExpression(pattern: returnPattern, options: .dotMatchesLineSeparators),
                       let returnMatch = returnRegex.firstMatch(in: innerBody, range: NSRange(location: 0, length: (innerBody as NSString).length)) {
                        innerBody = (innerBody as NSString).substring(with: returnMatch.range(at: 1))
                    }

                    // For multi-statement bodies, wrap in a lambda
                    let macroArgs = paramNames.joined(separator: ", ")
                    let hasSemicolon = innerBody.contains(";")

                    if hasSemicolon {
                        // Multi-statement: use a lambda that captures by reference
                        // [&](<params>) -> type { <body> }
                        let lambdaParams = zip(paramsRaw.components(separatedBy: ","), paramNames).map { raw, _ in
                            raw.trimmingCharacters(in: .whitespaces)
                        }.joined(separator: ", ")
                        macros.append("#define \(funcName)(\(macroArgs)) [&](\(lambdaParams)) -> \(returnType) { \(innerBody) }(\(macroArgs))")
                    } else {
                        // Single expression: simple macro
                        macros.append("#define \(funcName)(\(macroArgs)) (\(returnType))(\(innerBody))")
                    }
                }

                i = j
            } else {
                cleanLines.append(line)
                i += 1
            }
        }

        return (cleanLines.joined(separator: "\n"), macros)
    }

    private static func buildMetalSource(body: String, type: ShaderType, functionName: String, hoistedFunctions: [String] = []) -> String {
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
        // Overload: construct float2x2 from a single float4 (HLSL allows this)
        // HLSL row-major: v.xy = row 0, v.zw = row 1 → Metal columns: (v.x,v.z), (v.y,v.w)
        static float2x2 _md_float2x2(float4 v) {
            return float2x2(float2(v.x, v.z), float2(v.y, v.w));
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
        static float _md_lum(float2 c) {
            return dot(float3(c, 0), float3(0.32, 0.49, 0.29));
        }
        static float _md_lum(float c) {
            return c;
        }

        // Helper: HLSL length() accepts scalars, Metal does not
        static float length(float x) { return abs(x); }

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

            // Expose packed q-vectors (some shaders reference _qa.._qh directly)
            float4 _qa = u._qa, _qb = u._qb, _qc = u._qc, _qd = u._qd;
            float4 _qe = u._qe, _qf = u._qf, _qg = u._qg, _qh = u._qh;

            // Unpack q1..q32
            float q1 = _qa.x, q2 = _qa.y, q3 = _qa.z, q4 = _qa.w;
            float q5 = _qb.x, q6 = _qb.y, q7 = _qb.z, q8 = _qb.w;
            float q9 = _qc.x, q10 = _qc.y, q11 = _qc.z, q12 = _qc.w;
            float q13 = _qd.x, q14 = _qd.y, q15 = _qd.z, q16 = _qd.w;
            float q17 = _qe.x, q18 = _qe.y, q19 = _qe.z, q20 = _qe.w;
            float q21 = _qf.x, q22 = _qf.y, q23 = _qf.z, q24 = _qf.w;
            float q25 = _qg.x, q26 = _qg.y, q27 = _qg.z, q28 = _qg.w;
            float q29 = _qh.x, q30 = _qh.y, q31 = _qh.z, q32 = _qh.w;

            // UV setup from stage-in
        \(uvSetup)

            // Built-in macros — use .xy to extract UV, handling both float2 and float3 args
            #define _md_GetPixel(UV) (tex_main.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur1(UV) (tex_blur1.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur2(UV) (tex_blur2.sample(samp_fw, float2((UV).x, (UV).y)).xyz)
            #define _md_GetBlur3(UV) (tex_blur3.sample(samp_fw, float2((UV).x, (UV).y)).xyz)

            // Hoisted helper function macros
        \(hoistedFunctions.map { "    " + $0 }.joined(separator: "\n"))

            // Output variable (user code writes to this)
            float3 ret = float3(0.0);

            // --- User shader body ---
        \(body)
            // --- End user shader body ---

        \(hoistedFunctions.map { line -> String in
            // Extract macro name for #undef
            let parts = line.dropFirst("#define ".count).prefix(while: { $0 != "(" && $0 != " " })
            return "    #undef \(parts)"
        }.joined(separator: "\n"))
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
