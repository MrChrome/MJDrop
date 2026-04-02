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

    // MARK: - Inline Helper Types

    /// Metadata for a multi-statement helper function to be inlined at every call site.
    private struct InlineHelper {
        let name: String
        let returnType: String
        let paramTypes: [String]
        let paramNames: [String]
        let bodyLines: [String]  // individual statements (trimmed, non-empty)
    }

    private struct HelperCallSite {
        let range: Range<String.Index>
        let args: [String]
    }

    // MARK: - Public API

    static func transpile(hlsl: String, type: ShaderType, presetName: String) -> TranspileResult? {
        // 1. Extract shader_body content
        guard let body = extractShaderBody(from: hlsl) else {
            print("[ShaderTranspiler] Failed to extract shader_body from \(type) shader in '\(presetName)'")
            return nil
        }

        // 2. Apply HLSL → Metal transformations
        let transformed = applyTransformations(body)

        // 3. Extract helper function definitions; single-expression ones become #define macros,
        //    multi-statement ones are collected for inline expansion at call sites.
        let (cleanBody, hoistedFunctions, inlineHelpers) = extractHelperFunctions(from: transformed)

        // 3b. Inline-expand multi-statement helper calls (Metal has no lambdas, so we can't
        //     use the [&](...) -> T { ... }(args) pattern — instead we emit scoped blocks).
        let expandedBody = inlineExpandHelperCalls(cleanBody, helpers: inlineHelpers)

        // 4. Generate a stable function name
        let safeName = presetName
            .replacingOccurrences(of: "[^a-zA-Z0-9_]", with: "_", options: .regularExpression)
            .prefix(40)
        let funcName = "v2_\(type == .warp ? "warp" : "comp")_\(safeName)"

        // 5. Wrap in Metal function with preamble
        let metalSource = buildMetalSource(body: expandedBody, type: type, functionName: funcName, hoistedFunctions: hoistedFunctions)

        return TranspileResult(metalSource: metalSource, functionName: funcName)
    }

    // MARK: - Extract shader_body

    /// Returns (pre-body declarations, body content).
    /// Pre-body declarations are variable declarations before shader_body that need to be preserved.
    private static func extractShaderBody(from hlsl: String) -> String? {
        guard let bodyRange = hlsl.range(of: "shader_body") else { return nil }

        // Capture pre-body variable declarations AND function definitions before shader_body.
        // Variable declarations are inlined into the function body.
        // Function definitions are collected separately to be hoisted via extractHelperFunctions.
        let prebody = String(hlsl[hlsl.startIndex..<bodyRange.lowerBound])
        var preDeclarations = ""
        let preBodyLines = prebody.components(separatedBy: "\n")
        var pbIdx = 0
        while pbIdx < preBodyLines.count {
            let trimmed = preBodyLines[pbIdx].trimmingCharacters(in: .whitespaces)
            // Collect multi-line function definitions (they will be hoisted later)
            let funcDefPat = #"^(float[234]?|int|void|bool|half[234]?)\s+[a-zA-Z_]\w*\s*\([^)]*\)\s*\{"#
            if trimmed.range(of: funcDefPat, options: .regularExpression) != nil {
                // Accumulate until matching close brace
                var funcLines = trimmed
                var depth = trimmed.filter({ $0 == "{" }).count - trimmed.filter({ $0 == "}" }).count
                pbIdx += 1
                while depth > 0 && pbIdx < preBodyLines.count {
                    let l = preBodyLines[pbIdx].trimmingCharacters(in: .whitespaces)
                    funcLines += "\n" + l
                    depth += l.filter({ $0 == "{" }).count - l.filter({ $0 == "}" }).count
                    pbIdx += 1
                }
                preDeclarations += funcLines + "\n"
                continue
            }
            // Keep `#define` macros — often used to alias functions (e.g. `#define MyGet GetPixel`)
            if trimmed.hasPrefix("#define") {
                preDeclarations += trimmed + "\n"
            }
            // Keep float/float2/float3/float4/int/bool/half variable declarations, skip sampler decls
            else if trimmed.contains(";") && !trimmed.contains("sampler") {
                let varDeclPrefixes = ["float", "int", "bool", "half"]
                if varDeclPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                    preDeclarations += trimmed + "\n"
                }
            }
            pbIdx += 1
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

    /// Returns true if a `float[N] <varName>` declaration exists at brace depth 0 in `source`.
    /// Ignores declarations buried inside function bodies (depth > 0), which is critical because
    /// `extractHelperFunctions` removes those bodies — so a declaration inside a helper function
    /// must NOT suppress injection of an outer-scope declaration.
    private static func declaredAtTopLevel(_ varName: String, in source: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: varName)
        guard let regex = try? NSRegularExpression(pattern: "float[234]?\\s+\(escaped)\\b") else { return false }
        var depth = 0
        for line in source.components(separatedBy: "\n") {
            if depth == 0 {
                let ns = line as NSString
                let nsRange = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(in: line, range: nsRange) {
                    // Reject matches inside parentheses (function parameter lists).
                    // Count `(` vs `)` before the match position to get paren depth.
                    let beforeMatch = ns.substring(to: match.range.location)
                    let parenDepth = beforeMatch.filter { $0 == "(" }.count
                                   - beforeMatch.filter { $0 == ")" }.count
                    if parenDepth == 0 {
                        return true
                    }
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        }
        return false
    }

    /// Returns true if `line` is a comma-separated variable declaration of the form
    /// `float[N]? a, b, varName, c;` that includes `varName` as one of the declared names.
    /// Handles depth-0 comma splitting so initializers like `float2(x,y)` are not misinterpreted.
    private static func isMultiVarDeclaration(_ line: String, declaring varName: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Must start with a float type keyword and end with ";"
        guard trimmed.range(of: #"^float[234]?\s+"#, options: .regularExpression) != nil,
              trimmed.hasSuffix(";") else { return false }
        // Extract the vars section: drop type prefix and trailing ";"
        guard let typeEnd = trimmed.range(of: #"^float[234]?\s+"#, options: .regularExpression) else { return false }
        let varsSection = String(trimmed[typeEnd.upperBound...].dropLast())
        // Split on depth-0 commas and check each declared name
        var depth = 0
        var current = ""
        for ch in varsSection {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1 }
            else if ch == "," && depth == 0 {
                let name = String(current.trimmingCharacters(in: .whitespaces)
                    .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if name == varName { return true }
                current = ""
                continue
            }
            current.append(ch)
        }
        let lastName = String(current.trimmingCharacters(in: .whitespaces)
            .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        return lastName == varName
    }

    /// Returns true if `varName` is used at top scope (brace depth 0) BEFORE any top-scope
    /// type declaration for it, OR if it is used at top scope but never declared there at all.
    /// Used to detect HLSL presets that rely on declaration-hoisting (valid HLSL but not Metal/C++).
    /// The check is paren-depth aware so function parameter declarations (inside `(...)`) are ignored.
    private static func usedBeforeTopLevelDecl(_ varName: String, in source: String) -> Bool {
        let escapedVar = NSRegularExpression.escapedPattern(for: varName)
        guard let declRegex = try? NSRegularExpression(pattern: "float[234]?\\s+\(escapedVar)\\b"),
              let useRegex  = try? NSRegularExpression(pattern: "\\b\(escapedVar)\\b") else { return false }

        var depth = 0
        for line in source.components(separatedBy: "\n") {
            defer {
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            }
            guard depth == 0 else { continue }

            let ns = line as NSString
            let nsRange = NSRange(location: 0, length: ns.length)

            // Check for a top-scope (paren-depth 0) declaration first.
            // Case 1: simple form `float2 uv2 [= ...]`
            if let m = declRegex.firstMatch(in: line, range: nsRange) {
                let before = ns.substring(to: m.range.location)
                if before.filter({ $0 == "(" }).count == before.filter({ $0 == ")" }).count {
                    return false  // declaration found before any use — no injection needed
                }
            }
            // Case 2: multi-var form `float2 dz, uv2, other;`
            // The simple declRegex won't match when varName isn't immediately after the type.
            // Without this check the use-regex below would fire on the declaration's own name.
            if isMultiVarDeclaration(line, declaring: varName) {
                return false  // declaration found before any use — no injection needed
            }

            // Check for any non-declaration use at top scope on this line.
            for useMatch in useRegex.matches(in: line, range: nsRange) {
                let before = ns.substring(to: useMatch.range.location)
                if before.filter({ $0 == "(" }).count == before.filter({ $0 == ")" }).count {
                    return true  // use found before any declaration — injection needed
                }
            }
        }
        return false  // varName not encountered at top scope
    }

    private static func applyTransformations(_ body: String) -> String {
        var s = body

        // Remove sampler declarations (handled by function args)
        s = s.replacingOccurrences(
            of: #"(?m)^\s*sampler\s+sampler_\w+\s*;\s*$"#,
            with: "",
            options: .regularExpression
        )

        // tex2d (lowercase) → tex2D
        s = s.replacingOccurrences(
            of: #"\btex2d\b"#,
            with: "tex2D",
            options: .regularExpression
        )

        // slow_roam_cos / slow_roam_sin → roam_cos / roam_sin
        s = s.replacingOccurrences(of: #"\bslow_roam_cos\b"#, with: "roam_cos", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bslow_roam_sin\b"#, with: "roam_sin", options: .regularExpression)

        // hue_shader — undeclared float3 variable some presets reference but never define
        // Insert a declaration if used but not declared at the top level
        if s.range(of: #"\bhue_shader\b"#, options: .regularExpression) != nil &&
           !declaredAtTopLevel("hue_shader", in: s) {
            s = "float3 hue_shader = float3(1.0);\n" + s
        }

        // M_INV_PI_2 → 1/(2*pi)
        s = s.replacingOccurrences(of: #"\bM_INV_PI_2\b"#, with: "(1.0/(2.0*3.14159265))", options: .regularExpression)

        // M_PI_2 → pi/2
        s = s.replacingOccurrences(of: #"\bM_PI_2\b"#, with: "(3.14159265/2.0)", options: .regularExpression)

        // Undeclared variable `anz` (typo for `ang` in some presets) — declare it
        if s.range(of: #"\banz\b"#, options: .regularExpression) != nil &&
           !declaredAtTopLevel("anz", in: s) {
            s = "float anz = 0.0;\n" + s
        }

        // `vol` — used in some presets as a local average-volume variable.
        // If used but not declared at top level, insert a declaration.
        if s.range(of: #"\bvol\b"#, options: .regularExpression) != nil &&
           !declaredAtTopLevel("vol", in: s) {
            s = "float vol = (bass + mid + treb) * 0.333333;\n" + s
        }

        // `uv2` — inject a default declaration when uv2 is used before it is declared at top
        // scope.  This covers: (a) presets that never declare uv2, (b) presets that declare it
        // only inside helper-function bodies (depth > 0, invisible to the outer scope after
        // extractHelperFunctions removes those bodies), and (c) presets that declare it AFTER
        // its first use (valid HLSL declaration-hoisting semantics, but invalid Metal/C++).
        // fixVariableRedefinitions will strip any subsequent same-scope re-declaration to an
        // assignment, preserving the correct final value.
        if s.range(of: #"\buv2\b"#, options: .regularExpression) != nil &&
           usedBeforeTopLevelDecl("uv2", in: s) {
            s = "float2 uv2 = uv;\n" + s
        }

        // `blur1_min`, `blur1_max`, `blur2_min`, `blur2_max`, `blur3_min`, `blur3_max`
        // — blur range uniforms that some presets reference. Provide safe defaults if missing.
        for blurVar in ["blur1_min", "blur1_max", "blur2_min", "blur2_max", "blur3_min", "blur3_max"] {
            if s.range(of: "\\b\(blurVar)\\b", options: .regularExpression) != nil &&
               !declaredAtTopLevel(blurVar, in: s) {
                let defaultVal = blurVar.hasSuffix("_min") ? "0.0" : "1.0"
                s = "float \(blurVar) = \(defaultVal);\n" + s
            }
        }

        // `sw2` — undefined float used in some presets, likely a wave switch variable. Default to 0.
        if s.range(of: #"\bsw2\b"#, options: .regularExpression) != nil &&
           !declaredAtTopLevel("sw2", in: s) {
            s = "float sw2 = 0.0;\n" + s
        }

        // `trel` (typo for `treb`) — remap to treb
        s = s.replacingOccurrences(of: #"\btrel\b"#, with: "treb", options: .regularExpression)

        // `while expr` without parens — HLSL allows `while expr`, Metal requires `while (expr)`.
        // Add parens around while conditions that are missing them.
        s = s.replacingOccurrences(
            of: #"\bwhile\s+(?!\s*\()"#,
            with: "while (",
            options: .regularExpression
        )
        s = fixWhileMissingCloseParen(s)

        // `_md_lum.xxx` — `_md_lum` is a function, not a variable. Some presets write
        // `_md_lum.xxx` meaning "luminance as a float3". Replace with `float3(_md_lum(ret))`.
        // Pattern: `_md_lum.` not followed by `(`
        s = s.replacingOccurrences(
            of: #"\b_md_lum\.([xyzwrgba]+)\b"#,
            with: "_md_lum(ret).$1",
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

        // lum(x) → _md_lum(x)  — only rename the function call, not variable declarations
        s = s.replacingOccurrences(
            of: #"\blum\s*\("#,
            with: "_md_lum(",
            options: .regularExpression
        )

        // Fix float4 declarations initialized from .xyz texture samples.
        // Our tex sampling transform appends .xyz (float3), but HLSL code may
        // declare the variable as float4. Downgrade to float3.
        s = fixFloat4FromXyzSample(s)

        // Fix variable redefinitions: when a variable is declared in pre-body
        // (e.g. `float3 neu, ret1;`) and then re-declared in body
        // (e.g. `float3 ret1 = 0;`), convert the second to an assignment.
        // Also removes re-declarations of preamble uniforms (decay, time, etc.)
        s = fixVariableRedefinitions(s)

        // Fix for loops where the counter variable is undeclared: `for (n=0; n<4; n++)`
        // Insert `int n;` before the for loop if `n` is not already declared.
        s = fixUndeclaredForLoopVars(s)

        // Fix `clamp(expr, int, int)` — Metal's clamp is overloaded and ambiguous
        // with integer literals. Cast integer literal args to float.
        s = fixClampIntLiterals(s)

        // Fix `(float_expr).x` — accessing .x on a scalar is illegal in Metal.
        // Pattern: `(something).x` where `something` produces a float.
        s = fixRedundantScalarSwizzle(s)

        // Handle HLSL implicit truncation for known float4 uniforms used as scalars.
        // When these appear in arithmetic without a swizzle, HLSL auto-truncates.
        // We handle this by inserting explicit swizzles where needed.
        s = fixImplicitTruncation(s)

        // Second redundant-swizzle pass: fixBlurMacrosInScalarContext (inside fixImplicitTruncation)
        // appends `.x` to each _md_GetBlurN call, which can leave the outer `(x - x).x` pattern.
        // That outer swizzle on a scalar is now redundant and illegal — strip it.
        s = fixRedundantScalarSwizzle(s)

        // Convert HLSL `%` modulo operator to Metal `fmod()`.
        // HLSL allows `%` on float operands; Metal requires `fmod()`.
        s = convertModuloToFmod(s)

        // Fix HLSL vector comparisons that produce bool vectors.
        // HLSL: `(vec >= 0)` yields a float vector (0.0/1.0).
        // Metal: `(vec >= 0)` yields a bool vector which can't be assigned to float.
        // Convert `expr >= val` to `step(val, expr)` and `expr <= val` to `step(expr, val)`.
        s = fixVectorComparisons(s)

        // Fix scalar variable swizzle: HLSL allows `scalarFloat.x` (returns the scalar),
        // but Metal does not support member access on scalar types.
        // Collect all `float name` (not float2/3/4) declarations and strip `.x`/`.r` etc.
        s = fixScalarVariableSwizzle(s)

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
        let knownTextures: Set<String> = [
            "main", "blur1", "blur2", "blur3",
            "noise_lq", "noise_mq", "noise_hq",
            "noisevol_lq", "noisevol_hq"
        ]
        var rest = name
        if rest.hasPrefix("sampler_") {
            rest = String(rest.dropFirst("sampler_".count))
        }

        // Check for mode prefix: fw_, pw_, fc_, pc_
        let modes = ["fw_", "pw_", "fc_", "pc_"]
        for mode in modes {
            if rest.hasPrefix(mode) {
                let texName = String(rest.dropFirst(mode.count))
                // Unknown user textures (e.g. sampler_pic) fall back to main
                let finalTex = knownTextures.contains(texName) ? texName : "main"
                return (finalTex, String(mode.dropLast()))
            }
        }

        // No mode prefix — default to fw (linear filter, wrap)
        // Unknown user textures fall back to main
        let finalTex = knownTextures.contains(rest) ? rest : "main"
        return (finalTex, "fw")
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

        // Pre-scan: collect all `float varname` (scalar) declarations so we can fix
        // standalone assignments like `scalarVar = expr.xyz` (no type prefix on that line).
        // Uses depth-0 comma splitting so ALL vars in `float dx, dy;` are captured,
        // not just the first one (the old single-capture regex missed e.g. `dy`).
        var scalarVarNames = Set<String>()
        if let scalarRe = try? NSRegularExpression(pattern: "\\bfloat\\s+([^;{}\\n]+);") {
            let ns = source as NSString
            for m in scalarRe.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1 {
                    let varList = ns.substring(with: m.range(at: 1))
                    // Split on depth-0 commas to avoid splitting inside initializers like float2(a,b)
                    var parts: [String] = []
                    var cur = ""
                    var depth = 0
                    for ch in varList {
                        if ch == "(" { depth += 1 }
                        else if ch == ")" { depth -= 1 }
                        else if ch == "," && depth == 0 { parts.append(cur); cur = ""; continue }
                        cur.append(ch)
                    }
                    parts.append(cur)
                    for part in parts {
                        let name = String(part.trimmingCharacters(in: .whitespaces)
                            .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                        if !name.isEmpty { scalarVarNames.insert(name) }
                    }
                }
            }
        }

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

            // Also handle standalone assignments to known scalar vars: `scalarName [op]?= ...`
            if declType == nil {
                for name in scalarVarNames {
                    let ops = ["=", "+=", "-=", "*=", "/="]
                    if ops.contains(where: { trimmed.hasPrefix(name + " " + $0) || trimmed.hasPrefix(name + $0) }) {
                        declType = "float"
                        break
                    }
                }
            }

            // Also handle single-component vector accesses like `uv.x +=` or `ret.y =`.
            // A single-char swizzle component is always scalar float, even if the parent
            // variable is float2/float3/float4. Exclude double-char swizzles like `.xy`.
            if declType == nil {
                if trimmed.range(of: #"^[a-zA-Z_]\w*\.[xyzwrgba](?![xyzwrgba])\s*[-+*/]?=(?!=)"#,
                                 options: .regularExpression) != nil {
                    declType = "float"
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

            // For float2/float LHS, replace ALL .xyz in the statement (including mid-expression
            // and multi-line continuations). HLSL tex2D returns float4 and presets rely on
            // implicit truncation; our transpiler appends .xyz, but float2/float contexts need .xy/.x.
            switch declType {
            case "float2":
                for j in i...stmtEnd {
                    lines[j] = lines[j].replacingOccurrences(of: ".xyz", with: ".xy")
                }
            case "float":
                for j in i...stmtEnd {
                    lines[j] = lines[j].replacingOccurrences(of: ".xyz", with: ".x")
                }
            default:
                // For float4 LHS: downgrade type to float3 when RHS ends with .xyz
                let beforeSemicolon = combined.components(separatedBy: ";").first ?? combined
                let rhsTrimmed = beforeSemicolon.trimmingCharacters(in: .whitespaces)
                if rhsTrimmed.hasSuffix(".xyz") && declType == "float4" {
                    lines[i] = lines[i].replacingOccurrences(of: "float4 ", with: "float3 ", options: [], range: lines[i].range(of: "float4 "))
                }
            }

            i = stmtEnd + 1
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Variable Redefinition Fix

    /// Removes `varName` from a comma-separated declaration like `float2 a, varName, c;`.
    /// If `varName` held an initializer it is discarded — the caller has already injected a
    /// declaration above. Returns the modified line, or "" when all variables were removed.
    private static func removeVarFromMultiVarDecl(_ line: String, varName: String) -> String {
        let esc = NSRegularExpression.escapedPattern(for: varName)
        // Try "varName [= simple_expr]," (middle or first position — trailing comma stays)
        if let re = try? NSRegularExpression(pattern: "\\b\(esc)\\b(?:\\s*=\\s*[^,;]+)?\\s*,\\s*") {
            let ms = NSMutableString(string: line)
            let r = NSRange(location: 0, length: ms.length)
            if re.firstMatch(in: ms as String, range: r) != nil {
                re.replaceMatches(in: ms, range: r, withTemplate: "")
                return ms as String
            }
        }
        // Try ", varName [= simple_expr]" (last position)
        if let re = try? NSRegularExpression(pattern: ",\\s*\\b\(esc)\\b(?:\\s*=\\s*[^,;]+)?") {
            let ms = NSMutableString(string: line)
            let r = NSRange(location: 0, length: ms.length)
            if re.firstMatch(in: ms as String, range: r) != nil {
                re.replaceMatches(in: ms, range: r, withTemplate: "")
                // If only the type keyword remains (all vars removed), blank the line
                let stripped = (ms as String).trimmingCharacters(in: .whitespaces)
                if stripped.range(of: #"^(float[234]?|int|bool)\s*;"#, options: .regularExpression) != nil {
                    return ""
                }
                return ms as String
            }
        }
        return line
    }

    /// HLSL (and some Milkdrop presets) declare variables in pre-body
    /// (e.g. `float3 neu, ret1;`) then re-declare them inside the body
    /// (e.g. `float3 ret1 = 0;`). Metal/C++ doesn't allow this in the same scope.
    /// This pass tracks declared variable names and converts re-declarations to assignments.
    private static func fixVariableRedefinitions(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        // Pre-seed with variables declared in the Metal preamble so user shaders
        // that re-declare them (e.g. `float decay = ...;`) get converted to assignments.
        var declaredVars: [String: String] = [
            "time": "float", "fps": "float", "frame": "float",
            "bass": "float", "mid": "float", "treb": "float",
            "bass_att": "float", "mid_att": "float", "treb_att": "float",
            "decay": "float", "aspect": "float4", "texsize": "float4",
            "rand_frame": "float4", "rand_preset": "float4",
            "roam_cos": "float4", "roam_sin": "float4",
            "uv": "float2", "uv_orig": "float2",
            "rad": "float", "ang": "float",
            "ret": "float3",
        ]

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
                            let beforeReplace = lines[lineIdx]
                            let mutableLine = NSMutableString(string: lines[lineIdx])
                            redeclRegex.replaceMatches(in: mutableLine, range: NSRange(location: 0, length: mutableLine.length), withTemplate: varName)
                            lines[lineIdx] = mutableLine as String

                            // If the line is now just `varName;` (no initializer), remove it
                            let stripped = lines[lineIdx].trimmingCharacters(in: .whitespaces)
                            if stripped == "\(varName);" || stripped == "\(varName) ;" {
                                lines[lineIdx] = ""
                            } else if lines[lineIdx] == beforeReplace &&
                                      isMultiVarDeclaration(lines[lineIdx], declaring: varName) {
                                // Pattern didn't match — varName is in a comma-separated
                                // declaration list (e.g. `float2 dz,uv2,other;`).
                                // Confirmed it's a real declaration (not a function-call arg)
                                // before removing varName from the list.
                                lines[lineIdx] = removeVarFromMultiVarDecl(lines[lineIdx], varName: varName)
                            }
                        }
                    } else {
                        declaredVars[varName] = type
                    }
                }
            }

            // Handle multi-line declarations where ';' is on a later line.
            // The declRegex above requires ';', so `float dx = longFunc(\n  arg\n);`
            // is missed on the first line. Detect and fix these by checking if the
            // line starts with a type keyword followed by an already-declared variable.
            if matches.isEmpty && !line.contains(";") {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                let typeKeywords = ["float4", "float3", "float2", "float", "int", "bool"]
                for typeKw in typeKeywords {
                    guard trimmedLine.hasPrefix(typeKw + " ") || trimmedLine.hasPrefix(typeKw + "\t") else { continue }
                    let rest = String(trimmedLine.dropFirst(typeKw.count)).trimmingCharacters(in: .whitespaces)
                    let varName = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                    guard !varName.isEmpty else { break }
                    if declaredVars[varName] != nil {
                        // Redeclaration on a multi-line statement — strip the type prefix
                        let redeclPat = "\\b\(NSRegularExpression.escapedPattern(for: typeKw))\\s+\(NSRegularExpression.escapedPattern(for: varName))\\b"
                        if let re = try? NSRegularExpression(pattern: redeclPat) {
                            let ms = NSMutableString(string: lines[lineIdx])
                            re.replaceMatches(in: ms, range: NSRange(location: 0, length: ms.length), withTemplate: varName)
                            lines[lineIdx] = ms as String
                        }
                    } else {
                        declaredVars[varName] = typeKw
                    }
                    break
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

        // 4a. Fix `_md_GetBlur1/2/3(...)` and `_md_GetPixel(...)` used as scalars.
        //     These macros return float3 but HLSL presets routinely use them as floats.
        //     Add `.x` to any call not already followed by a dot-swizzle, UNLESS the call
        //     is the sole RHS of a direct `identifier = _md_Get...(args)` assignment.
        s = fixBlurMacrosInScalarContext(s)

        // 4b. Fix `ret.x = vector_expr` — scalar component assignment from a vector.
        //     Metal doesn't implicitly truncate float4/float3 to a component scalar.
        //     Transform: `ret.x = expr.xyz` → `ret.x = expr.x`
        //                `ret.x = tex.sample(...).xyz` → `ret.x = tex.sample(...).x`
        //                `ret.x = tex.sample(...)` → `ret.x = tex.sample(...).x`
        s = fixComponentAssignmentFromVector(s)

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
    /// Fix `_md_GetBlur1/2/3(...)` and `_md_GetPixel(...)` calls used in scalar context.
    /// These macros return `float3` (via `.xyz` expansion), but HLSL presets use them as
    /// scalars frequently (e.g., `ret.x += (ret.x - _md_GetBlur3(uv)) * 0.1`).
    /// We add `.x` to any call not already followed by a dot-swizzle, UNLESS the call
    /// is the sole expression on the RHS of a plain `=` assignment.
    private static func fixBlurMacrosInScalarContext(_ source: String) -> String {
        let macroNames = ["_md_GetBlur1", "_md_GetBlur2", "_md_GetBlur3", "_md_GetPixel"]
        var result = source
        let chars = Array(result)
        let n = chars.count
        var insertions: [(offset: Int, str: String)] = []  // (index after ), ".x")

        // Pre-compute which character offsets are on #define / #undef lines (skip those)
        var onDefLine = [Bool](repeating: false, count: n)
        var lineStart = 0
        for pos in 0..<n {
            if chars[pos] == "\n" { lineStart = pos + 1 }
            // Check if current line starts with optional whitespace then #define or #undef
            var ls = lineStart
            while ls < pos && (chars[ls] == " " || chars[ls] == "\t") { ls += 1 }
            if ls + 7 <= n && String(chars[ls..<(ls+7)]) == "#define" { onDefLine[pos] = true }
            else if ls + 6 <= n && String(chars[ls..<(ls+6)]) == "#undef" { onDefLine[pos] = true }
        }

        var i = 0
        while i < n {
            // Skip #define / #undef lines entirely
            if onDefLine[i] { i += 1; continue }

            // Try to match any macro name at position i
            var matched: String? = nil
            for name in macroNames {
                let nameChars = Array(name)
                let nameLen = nameChars.count
                if i + nameLen <= n {
                    let slice = chars[i..<(i + nameLen)]
                    if slice.elementsEqual(nameChars) {
                        // Make sure it's not preceded by an identifier char (avoid matching inside longer names)
                        if i > 0 && (chars[i-1].isLetter || chars[i-1].isNumber || chars[i-1] == "_") {
                            break
                        }
                        matched = name
                        break
                    }
                }
            }
            guard let macroName = matched else { i += 1; continue }

            let macroStart = i
            i += macroName.count
            // Skip whitespace before (
            while i < n && chars[i] == " " { i += 1 }
            guard i < n && chars[i] == "(" else { continue }

            // Find the matching close paren (paren-depth tracking)
            var depth = 1
            i += 1  // skip (
            while i < n && depth > 0 {
                if chars[i] == "(" { depth += 1 }
                else if chars[i] == ")" { depth -= 1 }
                i += 1
            }
            // i is now the index AFTER the closing )
            let callEnd = i  // index right after the closing paren of the macro call

            // Check what follows the call:
            // If already followed by `.` (swizzle) → skip
            var peekIdx = callEnd
            while peekIdx < n && chars[peekIdx] == " " { peekIdx += 1 }
            if peekIdx < n && chars[peekIdx] == "." {
                // Already has a swizzle — check if it's a valid component or named swizzle
                // e.g. `.x`, `.xyz`, `.r` → skip
                continue
            }

            // Check: is this call the SOLE RHS of a direct assignment to a float3 target?
            // Pattern: `float3 var = _md_GetBlurN(...)` or `ret = _md_GetBlurN(...)`
            // Only skip if the LHS is clearly a float3 (don't skip for float/float2 LHS).
            var prevIdx = macroStart - 1
            while prevIdx >= 0 && (chars[prevIdx] == " " || chars[prevIdx] == "\t") { prevIdx -= 1 }
            let skipForFloat3: Bool
            if prevIdx >= 0 && chars[prevIdx] == "=" {
                // Check it's not `+=`, `-=`, `*=`, `/=`
                let prevPrev = prevIdx - 1
                if prevPrev >= 0 && "+-*/!<>".contains(chars[prevPrev]) {
                    skipForFloat3 = false
                } else {
                    // It IS a plain `= macro(...)` — check that the call is sole on RHS
                    var ahead = callEnd
                    while ahead < n && (chars[ahead] == " " || chars[ahead] == "\t") { ahead += 1 }
                    let isSoleRhs = ahead >= n || chars[ahead] == ";" || chars[ahead] == "\n" || chars[ahead] == "\r"
                    if isSoleRhs {
                        // Now check: is the LHS a float3 declaration or a known float3 variable?
                        // Walk left from the `=` to find the LHS token
                        let float3Vars: Set<String> = ["ret", "ret1", "ret2", "color", "bloom", "col", "c", "c2", "c3", "rgb", "hsv", "n", "glow"]
                        var lhsEnd = prevIdx - 1
                        while lhsEnd >= 0 && (chars[lhsEnd] == " " || chars[lhsEnd] == "\t") { lhsEnd -= 1 }
                        if lhsEnd < 0 {
                            // prevIdx was 0 — no LHS token before `=`, can't determine type safely
                            skipForFloat3 = false
                        } else {
                            var lhsStart = lhsEnd
                            while lhsStart > 0 && (chars[lhsStart-1].isLetter || chars[lhsStart-1].isNumber || chars[lhsStart-1] == "_") { lhsStart -= 1 }
                            let lhsVarName = String(chars[lhsStart...lhsEnd])
                            // Check for `float3 varname =` — look further left for "float3"
                            let typeEnd0 = lhsStart - 1
                            if typeEnd0 < 0 {
                                // No room for a type keyword — rely on known variable names only
                                skipForFloat3 = float3Vars.contains(lhsVarName)
                            } else {
                                var typeEnd = typeEnd0
                                while typeEnd >= 0 && (chars[typeEnd] == " " || chars[typeEnd] == "\t") { typeEnd -= 1 }
                                var typeStart = typeEnd
                                while typeStart > 0 && (chars[typeStart-1].isLetter || chars[typeStart-1].isNumber || chars[typeStart-1] == "_") { typeStart -= 1 }
                                let typeName = typeStart <= typeEnd ? String(chars[typeStart...typeEnd]) : ""
                                skipForFloat3 = typeName == "float3" || float3Vars.contains(lhsVarName)
                            }
                        }
                    } else {
                        skipForFloat3 = false
                    }
                }
            } else {
                skipForFloat3 = false
            }

            if !skipForFloat3 {
                // Record insertion of ".x" at callEnd
                insertions.append((offset: callEnd, str: ".x"))
            }

            // i already advanced past the call, continue
        }

        // Apply insertions in reverse order so offsets stay valid
        if insertions.isEmpty { return result }
        for ins in insertions.reversed() {
            let idx = result.index(result.startIndex, offsetBy: ins.offset)
            result.insert(contentsOf: ins.str, at: idx)
        }
        return result
    }

    ///
    /// Smart enough to skip cases where the float2 var is inside a scalar-returning function
    /// like `length()`, `dot()`, `distance()`, etc.
    /// Fix `scalar_lhs = vector_expr` where `scalar_lhs` is a single-component member like `ret.x`.
    /// Metal doesn't implicit-truncate float4/float3 → float. We add `.x` to the RHS.
    /// Also handles `ret.x += vector_expr` and similar compound assignments.
    private static func fixComponentAssignmentFromVector(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")

        // Pattern: `<expr>.<single_component> [+|-|*|/]?= <rhs>;`
        // where <single_component> is x, y, z, w, r, g, b, a
        // and <rhs> ends with `.xyz`, `.xy`, `.xyzw`, or is a bare `.sample()` call (no swizzle)
        for i in 0..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comment lines
            if trimmed.hasPrefix("//") { continue }

            // Look for patterns like: `someVar.x = ` or `someVar.x += ` etc.
            // Using a regex to find the assignment operator position
            guard let assignRange = line.range(of: #"\.[xyzwrgba]\s*[\+\-\*\/]?="#, options: .regularExpression) else { continue }

            // Verify the char before the swizzle is an identifier character (word char)
            let dotIdx = assignRange.lowerBound
            if dotIdx > line.startIndex {
                let prevIdx = line.index(before: dotIdx)
                let prevChar = line[prevIdx]
                guard prevChar.isLetter || prevChar.isNumber || prevChar == "_" else { continue }
            }

            // Extract the RHS (after the `=` sign)
            guard let eqPos = line.range(of: "=", range: assignRange) else { continue }
            let rhsStart = line.index(after: eqPos.lowerBound)
            // Skip leading whitespace
            var rhsBegin = rhsStart
            while rhsBegin < line.endIndex && line[rhsBegin] == " " { rhsBegin = line.index(after: rhsBegin) }
            let rhs = String(line[rhsBegin...]).trimmingCharacters(in: CharacterSet(charactersIn: ";").union(.whitespaces))

            // Check if RHS is a vector expression that needs truncation.
            // Conditions to apply fix:
            // 1. RHS ends with `.xyz`, `.xyzw`, `.xy` (multi-component swizzle on vector) — change to `.x`
            // 2. RHS ends with a texture .sample(...) call with no swizzle — add `.x`
            // 3. RHS ends with blur/pixel function result (returns float3) — add `.x`

            let multiSwizzles = [".xyz", ".xyzw", ".xy", ".yzw", ".zw"]
            if multiSwizzles.contains(where: { rhs.hasSuffix($0) }) {
                // Replace the multi-component swizzle with `.x`
                let dotIdx2 = rhs.lastIndex(of: ".")!
                let newRhs = String(rhs[..<dotIdx2]) + ".x"
                let newLine = String(line[..<rhsBegin]) + newRhs + ";"
                lines[i] = newLine
                continue
            }

            // Check if RHS ends with a tex/blur sample call (float4) or blur (float3) without any swizzle
            let endsWithSample = rhs.hasSuffix(")") || rhs.hasSuffix(", 0)") // loose check
            if endsWithSample {
                // More specific check: does the expression contain .sample( or _md_GetBlur or _md_GetPixel?
                let isVectorReturn = rhs.contains(".sample(") || rhs.contains("_md_GetBlur") ||
                                     rhs.contains("_md_GetPixel") || rhs.contains("tex2D(") ||
                                     rhs.contains("tex3D(")
                if isVectorReturn {
                    let newLine = String(line[..<rhsBegin]) + rhs + ".x;"
                    lines[i] = newLine
                    continue
                }
            }
        }

        return lines.joined(separator: "\n")
    }

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
        // Functions that accept float2 UV args but whose result is not a float2.
        // When a float2 var appears inside these, it's used as a UV coord (scalar-safe context).
        let scalarReturningFuncs = ["length", "dot", "distance", "_md_lum", "atan2",
                                    "_md_GetBlur1", "_md_GetBlur2", "_md_GetBlur3",
                                    "_md_GetPixel", "tex2D", "tex3D", "sample"]
        let pattern = #"(?m)^(\s*float\s+\w+\s*=\s*)(.+?)\s*;\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }

        let nsSource = source as NSString
        var result = source
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        // Process in reverse to preserve indices
        for match in matches.reversed() {
            let rhsRange = match.range(at: 2)
            let rhs = nsSource.substring(with: rhsRange)

            // If the RHS already ends with a scalar swizzle (.x, .y, .z, .w etc.),
            // the result is already scalar — no wrapping needed.
            let trimmedRhs = rhs.trimmingCharacters(in: .whitespaces)
            let scalarSuffixes = [".x", ".y", ".z", ".w", ".r", ".g", ".b", ".a"]
            if scalarSuffixes.contains(where: { trimmedRhs.hasSuffix($0) }) {
                continue
            }

            // Check if RHS contains a known float2 variable (indicating possible vector result)
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
            // Includes plain `=` and compound operators `*=`, `+=`, `-=`, `/=`.
            var assignsToFloat2 = false
            for f2var in float2Vars {
                let compoundOps = ["=", "*=", "+=", "-=", "/="]
                for op in compoundOps {
                    if trimmed.hasPrefix("\(f2var) \(op)") || trimmed.hasPrefix("\(f2var)\(op)") {
                        assignsToFloat2 = true
                        break
                    }
                }
                if assignsToFloat2 { break }
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
                // Don't truncate float3 vars that already have a swizzle.
                // (?<!\\.) prevents matching swizzle components: e.g. `z` in `foo.z`.
                let pattern = "(?<!\\.)\\b\(NSRegularExpression.escapedPattern(for: f3var))\\b(?!\\s*[.\\[])"
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

        let intermediate = lines.joined(separator: "\n")
        // Also fix float3 vars inside 2D texture sample UV arguments.
        // tex2D UV must be float2; float3 vars in the UV arg need .xy.
        let afterSample = fixFloat3InSample2DUV(intermediate, float3Vars: float3Vars)
        // Also fix float3 vars inside _md_GetPixel / _md_GetBlur1/2/3 UV arguments.
        return fixFloat3InGetMacroArgs(afterSample, float3Vars: float3Vars)
    }

    /// Fix float3 variables that appear in the UV argument of `_md_GetPixel(...)`,
    /// `_md_GetBlur1(...)`, `_md_GetBlur2(...)`, and `_md_GetBlur3(...)`.
    /// These functions all take a single float2 UV argument, so any unswizzled
    /// float3 variable in that argument needs `.xy` appended.
    private static func fixFloat3InGetMacroArgs(_ source: String, float3Vars: Set<String>) -> String {
        let macros = ["_md_GetPixel", "_md_GetBlur1", "_md_GetBlur2", "_md_GetBlur3"]
        guard macros.contains(where: { source.contains($0 + "(") }) else { return source }
        guard !float3Vars.isEmpty else { return source }

        let chars = Array(source)
        let n = chars.count
        var result: [Character] = []
        result.reserveCapacity(n)
        var i = 0

        while i < n {
            // Try to match any macro name at position i
            var matchedMacro: String? = nil
            for macro in macros {
                let macroChars = Array(macro)
                let macroLen = macroChars.count
                guard i + macroLen + 1 <= n else { continue }
                guard chars[i..<(i + macroLen)].elementsEqual(macroChars) else { continue }
                // Must be followed by '(' (optionally whitespace)
                var k = i + macroLen
                while k < n && (chars[k] == " " || chars[k] == "\t") { k += 1 }
                guard k < n && chars[k] == "(" else { continue }
                // Must not be preceded by identifier character
                if i > 0 && (chars[i-1].isLetter || chars[i-1].isNumber || chars[i-1] == "_") { continue }
                matchedMacro = macro
                break
            }

            guard let macro = matchedMacro else {
                result.append(chars[i])
                i += 1
                continue
            }

            // Append the macro name
            result.append(contentsOf: macro)
            i += macro.count

            // Skip whitespace and the opening '('
            while i < n && (chars[i] == " " || chars[i] == "\t") {
                result.append(chars[i])
                i += 1
            }
            guard i < n && chars[i] == "(" else { continue }
            result.append("(")
            i += 1  // skip '('

            // Extract the full argument expression (depth-balanced)
            var depth = 1
            var argChars: [Character] = []
            while i < n && depth > 0 {
                if chars[i] == "(" { depth += 1 }
                else if chars[i] == ")" { depth -= 1; if depth == 0 { break } }
                argChars.append(chars[i])
                i += 1
            }

            // Fix float3 vars in the argument by adding .xy
            var uvExpr = String(argChars)
            // Strip _md_f3() wrappers — inner arg is already float2 for these UV-expecting calls.
            uvExpr = stripMdf3Wrappers(uvExpr)
            for f3var in float3Vars {
                let escapedVar = NSRegularExpression.escapedPattern(for: f3var)
                let pat = "(?<!\\.)\\b\(escapedVar)\\b(?!\\s*[.\\[=])"
                if let regex = try? NSRegularExpression(pattern: pat) {
                    let ns = uvExpr as NSString
                    let matches = regex.matches(in: uvExpr, range: NSRange(location: 0, length: ns.length))
                    for m in matches.reversed() {
                        uvExpr = (uvExpr as NSString).replacingCharacters(in: m.range, with: "\(f3var).xy")
                    }
                }
            }
            result.append(contentsOf: uvExpr)

            // Append closing ')'
            if i < n && chars[i] == ")" {
                result.append(")")
                i += 1
            }
        }

        return String(result)
    }

    /// Fix float3 variables that appear in the UV argument of texture2d sample calls.
    /// The UV for a 2d texture must be float2, so any unswizzled float3 var needs `.xy`.
    /// 3D textures (names containing "vol") are skipped since their UV is float3.
    /// Strips `_md_f3(innerExpr)` wrappers, returning just `innerExpr`.
    /// Used when an expression that was promoted to float3 (for arithmetic) is used
    /// in a context that requires float2 (e.g., 2D texture UV, _md_GetPixel arg).
    private static func stripMdf3Wrappers(_ expr: String) -> String {
        guard expr.contains("_md_f3(") else { return expr }
        var result = expr
        let marker = "_md_f3("
        while let range = result.range(of: marker) {
            let afterOpen = range.upperBound
            var depth = 1
            var idx = afterOpen
            while idx < result.endIndex && depth > 0 {
                if result[idx] == "(" { depth += 1 }
                else if result[idx] == ")" { depth -= 1 }
                if depth > 0 { idx = result.index(after: idx) }
            }
            guard depth == 0, idx < result.endIndex else { break }
            let inner = String(result[afterOpen..<idx])
            result.replaceSubrange(range.lowerBound...idx, with: inner)
        }
        return result
    }

    private static func fixFloat3InSample2DUV(_ source: String, float3Vars: Set<String>) -> String {
        guard source.contains(".sample(") else { return source }

        let targetStr = ".sample("
        let targetChars = Array(targetStr)
        let targetLen = targetChars.count

        var chars = Array(source)
        let n = chars.count
        var result: [Character] = []
        result.reserveCapacity(n)
        var i = 0

        while i < n {
            // Try to match ".sample(" at position i
            guard i + targetLen <= n && chars[i..<(i + targetLen)].elementsEqual(targetChars) else {
                result.append(chars[i])
                i += 1
                continue
            }

            // Find the texture name immediately before the '.'
            var tnEnd = i - 1
            while tnEnd >= 0 && (chars[tnEnd].isLetter || chars[tnEnd].isNumber || chars[tnEnd] == "_") {
                tnEnd -= 1
            }
            let texNameStart = tnEnd + 1
            let texName = texNameStart < i ? String(chars[texNameStart..<i]) : ""

            // Append ".sample(" and advance
            result.append(contentsOf: targetChars)
            i += targetLen

            // 3D textures have float3 UVs — skip them
            if texName.contains("vol") { continue }

            // depth = 1 since we're inside the opening '(' of sample(...)
            var depth = 1

            // Pass 1: copy the sampler argument (up to the first ',' at depth 1)
            var foundComma = false
            while i < n && !foundComma {
                let c = chars[i]
                if c == "(" { depth += 1 }
                else if c == ")" {
                    depth -= 1
                    if depth == 0 {
                        // sample() closed with no UV arg (shouldn't happen in valid shaders)
                        result.append(c)
                        i += 1
                        break
                    }
                }
                if depth == 1 && c == "," {
                    result.append(c)
                    i += 1
                    foundComma = true
                } else {
                    result.append(c)
                    i += 1
                }
            }
            if !foundComma || depth == 0 { continue }

            // Pass 2: extract the UV expression until the closing ')' at depth 0
            var uvChars: [Character] = []
            while i < n {
                let c = chars[i]
                if c == "(" { depth += 1 }
                else if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                uvChars.append(c)
                i += 1
            }

            // Fix: add .xy to any unswizzled float3 var inside the UV expression
            var uvExpr = String(uvChars)
            // Strip _md_f3() wrappers: they promote float2→float3 for ret arithmetic,
            // but 2D texture UV must be float2 — the inner arg is already float2.
            uvExpr = stripMdf3Wrappers(uvExpr)
            for f3var in float3Vars {
                let escapedVar = NSRegularExpression.escapedPattern(for: f3var)
                let pat = "(?<!\\.)\\b\(escapedVar)\\b(?!\\s*[.\\[=])"
                if let regex = try? NSRegularExpression(pattern: pat) {
                    let ns = uvExpr as NSString
                    let matches = regex.matches(in: uvExpr, range: NSRange(location: 0, length: ns.length))
                    for m in matches.reversed() {
                        uvExpr = (uvExpr as NSString).replacingCharacters(in: m.range, with: "\(f3var).xy")
                    }
                }
            }
            result.append(contentsOf: uvExpr)

            // Append the closing ')' of sample()
            if i < n && chars[i] == ")" {
                result.append(")")
                i += 1
            }
        }

        return String(result)
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

    // MARK: - while Missing Close Paren Fix

    /// After we prepend `while (` for HLSL `while condition` patterns (no parens),
    /// we need to find the end of the condition and insert the closing `)`.
    /// The condition ends just before the `{` that opens the loop body, or at end-of-line
    /// if the opening brace is on the next line.
    private static func fixWhileMissingCloseParen(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        for i in 0..<lines.count {
            var line = lines[i]
            // Only process lines we modified — they now contain `while (`
            // but the `(` we inserted for the condition may not be balanced.
            guard let whileRange = line.range(of: "while (") else { continue }

            // Count parens starting after the `(` we inserted.
            let start = whileRange.upperBound  // character after `while (`
            var depth = 1  // we opened one `(` for the condition
            var idx = start
            var insertionPoint: String.Index? = nil

            while idx < line.endIndex {
                let ch = line[idx]
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        // The condition is already closed — nothing to do.
                        insertionPoint = nil
                        break
                    }
                } else if ch == "{" {
                    // Hit the body-open brace; insert `)` before it (and any preceding spaces)
                    var closeAt = idx
                    while closeAt > start {
                        let prev = line.index(before: closeAt)
                        if line[prev] == " " || line[prev] == "\t" {
                            closeAt = prev
                        } else {
                            break
                        }
                    }
                    insertionPoint = closeAt
                    break
                }
                idx = line.index(after: idx)
            }

            if let pos = insertionPoint {
                line.insert(")", at: pos)
                lines[i] = line
            } else if depth > 0 {
                // No `{` found on this line and paren not closed — append `)` at end of line
                line += ")"
                lines[i] = line
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - For Loop Variable Fix

    /// `for (n=0; n<4; n++)` without `int n` declared → insert `int n = 0;` before the loop.
    private static func fixUndeclaredForLoopVars(_ source: String) -> String {
        // Find all `for (` loops where the init is an assignment without a type
        let forPattern = #"\bfor\s*\(\s*([a-zA-Z_]\w*)\s*="#
        guard let regex = try? NSRegularExpression(pattern: forPattern) else { return source }
        var lines = source.components(separatedBy: "\n")
        var declared: Set<String> = []

        // Collect already-declared vars
        let declPat = #"\b(float[234]?|int|bool)\s+([a-zA-Z_]\w*)"#
        if let declRegex = try? NSRegularExpression(pattern: declPat) {
            for line in lines {
                let ns = line as NSString
                for m in declRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    declared.insert(ns.substring(with: m.range(at: 2)))
                }
            }
        }

        var insertions: [(index: Int, decl: String)] = []
        for (lineIdx, line) in lines.enumerated() {
            let ns = line as NSString
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let varName = ns.substring(with: m.range(at: 1))
                if !declared.contains(varName) {
                    insertions.append((lineIdx, "int \(varName) = 0;"))
                    declared.insert(varName)
                }
            }
        }
        // Insert in reverse so indices stay valid
        for ins in insertions.sorted(by: { $0.index > $1.index }) {
            lines.insert(ins.decl, at: ins.index)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Clamp Int Literal Fix

    /// `clamp(expr, -6, 0)` — Metal's `clamp` is ambiguous when mixing float expr with int literals.
    /// Cast bare integer literals in 2nd and 3rd args to float.
    private static func fixClampIntLiterals(_ source: String) -> String {
        // Match clamp( ... , intLiteral, intLiteral ) where intLiteral is [-]digits with no `.`
        let pattern = #"\bclamp\s*\(([^,]+),\s*(-?\d+)\s*,\s*(-?\d+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let ns = source as NSString
        var result = source
        var offset = 0
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let fullRange = Range(m.range, in: result)!
            let exprRange = Range(m.range(at: 1), in: source)!
            let lo = ns.substring(with: m.range(at: 2))
            let hi = ns.substring(with: m.range(at: 3))
            let expr = String(source[exprRange])
            let replacement = "clamp(\(expr), \(lo).0, \(hi).0)"
            let adjustedRange = result.index(result.startIndex, offsetBy: result.distance(from: result.startIndex, to: fullRange.lowerBound) + offset)..<result.index(result.startIndex, offsetBy: result.distance(from: result.startIndex, to: fullRange.upperBound) + offset)
            result.replaceSubrange(adjustedRange, with: replacement)
            offset += replacement.count - result.distance(from: fullRange.lowerBound, to: fullRange.upperBound)
        }
        return result
    }

    // MARK: - Redundant Scalar Swizzle Fix

    /// `(float_expr).x` where `float_expr` already produces a scalar — removes the `.x`.
    /// Metal doesn't allow swizzling a scalar. This iteratively strips `.COMPONENT` suffixes
    /// from parenthesized expressions that already evaluate to a scalar (all sub-expressions
    /// have a single-component swizzle or are multiplied/divided scalars).
    private static func fixRedundantScalarSwizzle(_ source: String) -> String {
        var s = source
        // Repeatedly apply until no more changes (handles nested cases)
        var prev = ""
        while prev != s {
            prev = s
            // Pattern: `(expr).X` where X is a single letter swizzle component (x,y,z,w,r,g,b,a)
            // AND every leaf in expr ends with a single-component swizzle.
            // Heuristic: scan for `).x` / `).y` etc and check if the balanced-paren group
            // only contains scalars (no bare vec constructors or unswizzled vec results).
            s = stripScalarSwizzleOnParens(s)
        }
        return s
    }

    private static func stripScalarSwizzleOnParens(_ source: String) -> String {
        // Functions that ALWAYS return a float scalar regardless of argument type.
        // A `.x` swizzle on their result is always illegal in Metal.
        let scalarReturnFunctions: Set<String> = [
            "length", "dot", "distance",
            "abs", "sign", "floor", "ceil", "round", "trunc", "fract",
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "exp", "exp2", "log", "log2", "sqrt", "rsqrt",
            "saturate", "pow", "fmod", "clamp", "min", "max",
            "step", "smoothstep", "_md_lum"
        ]

        var result = ""
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            // Look for `)` followed by `.` followed by single component letter
            if chars[i] == ")" && i + 2 < chars.count && chars[i+1] == "." {
                let comp = chars[i+2]
                let singleComponents: Set<Character> = ["x","y","z","w","r","g","b","a"]
                let notFollowedByAlnum = (i + 3 >= chars.count) || !chars[i+3].isLetter && !chars[i+3].isNumber && chars[i+3] != "_"
                if singleComponents.contains(comp) && notFollowedByAlnum {
                    // Find the matching open paren for this `)`
                    var depth = 1
                    var j = i - 1
                    while j >= 0 && depth > 0 {
                        if chars[j] == ")" { depth += 1 }
                        else if chars[j] == "(" { depth -= 1 }
                        if depth > 0 { j -= 1 }
                    }
                    if j >= 0 {
                        // Check for a function name immediately before the `(`
                        var fnEnd = j - 1
                        while fnEnd >= 0 && (chars[fnEnd] == " " || chars[fnEnd] == "\t") { fnEnd -= 1 }
                        let hasFuncName = fnEnd >= 0 &&
                            (chars[fnEnd].isLetter || chars[fnEnd].isNumber || chars[fnEnd] == "_")

                        var shouldStrip = false
                        if hasFuncName {
                            // It's a function call — only strip if the function is known to
                            // return a scalar. For unknown functions (e.g. _md_GetBlur1, tex.sample)
                            // the result may be a vector, so keep the swizzle.
                            var fnStart = fnEnd
                            while fnStart > 0 &&
                                (chars[fnStart-1].isLetter || chars[fnStart-1].isNumber || chars[fnStart-1] == "_") {
                                fnStart -= 1
                            }
                            let funcName = String(chars[fnStart...fnEnd])
                            shouldStrip = scalarReturnFunctions.contains(funcName)
                        } else {
                            // No function name — it's a parenthesized expression `(expr).x`.
                            // Check if the inner expression is provably scalar (all sub-calls
                            // already swizzled to single components, no bare vector constructors).
                            let inner = String(chars[(j+1)..<i])
                            shouldStrip = isScalarExpression(inner)
                        }

                        if shouldStrip {
                            result.append(")")
                            i += 3 // skip ), ., component
                            continue
                        }
                    }
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Returns true if the expression is likely scalar-valued (not a vector).
    ///
    /// Approach: walk at the top nesting level (depth == 0).
    /// At depth 0, every `)` that ends a sub-expression must be followed by a single-component
    /// swizzle (`.x`, `.y`, etc.) to be considered scalar. A `)` without `.X` means an
    /// unswizzled function/paren result — which could be a vector.
    ///
    /// To avoid false-negatives from `)` inside function *arguments* (e.g. `float2(d,0)` inside
    /// `GetBlur2(...)`), we only examine `)` chars that are at the *outermost* paren depth.
    private static func isScalarExpression(_ expr: String) -> Bool {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        let chars = Array(trimmed)
        let n = chars.count
        var depth = 0
        let singleComponents: Set<Character> = ["x","y","z","w","r","g","b","a"]
        let vecTypes: Set<String> = ["float2", "float3", "float4", "half2", "half3", "half4",
                                     "int2", "int3", "int4"]

        var i = 0
        while i < n {
            let ch = chars[i]
            if ch == "(" {
                // Before incrementing depth, check if this is a vector constructor at depth 0
                if depth == 0 {
                    // Look at the word immediately before this `(`
                    var j = i - 1
                    while j >= 0 && (chars[j] == " " || chars[j] == "\t") { j -= 1 }
                    if j >= 0 && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                        var k = j
                        while k > 0 && (chars[k-1].isLetter || chars[k-1].isNumber || chars[k-1] == "_") { k -= 1 }
                        let word = String(chars[k...j])
                        if vecTypes.contains(word) {
                            return false  // vector constructor at top level
                        }
                    }
                }
                depth += 1
            } else if ch == ")" {
                depth -= 1
                // Only examine closes at the outermost level
                if depth == 0 {
                    let next = i + 1
                    if next < n && chars[next] == "." {
                        let compIdx = next + 1
                        if compIdx < n {
                            let c = chars[compIdx]
                            let afterComp = compIdx + 1
                            let nextIsAlnum = afterComp < n &&
                                (chars[afterComp].isLetter || chars[afterComp].isNumber || chars[afterComp] == "_")
                            if singleComponents.contains(c) && !nextIsAlnum {
                                // single-component swizzle → scalar ✓
                                i = compIdx + 1
                                continue
                            } else {
                                // .xyz or .sample or other member — vector ✗
                                return false
                            }
                        }
                    } else {
                        // `)` at depth 0 without following `.X`.
                        // This could be an unswizzled vector return (e.g. `tex_main.sample(...)`) 
                        // — treat as non-scalar to be safe.
                        return false
                    }
                }
            }
            i += 1
        }
        return true
    }

    /// Removes single-component swizzles (`.x`, `.y`, `.z`, `.w`, `.r`, `.g`, `.b`, `.a`)
    /// from variables declared as scalar `float` in the source.
    /// HLSL allows `scalarFloat.x` (it's a no-op returning the same scalar), but Metal
    /// rejects member access on non-struct/union types.
    ///
    /// Uses `(?<!\.)` lookbehind to avoid falsely stripping swizzles from vector members,
    /// e.g. `vec.x` where `x` happens to also be a scalar variable name.
    private static func fixScalarVariableSwizzle(_ source: String) -> String {
        guard let declRegex = try? NSRegularExpression(
            pattern: #"\bfloat\s+([a-zA-Z_]\w*)"#
        ) else { return source }

        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)

        var scalarNames = Set<String>()
        for match in declRegex.matches(in: source, range: fullRange) {
            guard match.numberOfRanges > 1 else { continue }
            let r = match.range(at: 1)
            guard r.location != NSNotFound else { continue }
            scalarNames.insert(nsSource.substring(with: r))
        }

        guard !scalarNames.isEmpty else { return source }

        var s = source
        // Sort by length descending to avoid partial replacements (e.g. "bl2" before "bl")
        for name in scalarNames.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)

            // 1. Multi-component swizzle on a scalar: HLSL allows `scalar.xxx` to broadcast
            //    to float3, but Metal does not. Replace with floatN(scalar).
            //    e.g. `crisp.xxx` → `float3(crisp)`, `crisp.xy` → `float2(crisp)`
            if let multiRegex = try? NSRegularExpression(
                pattern: "(?<!\\.)\\b\(escaped)\\.([xyzwrgba]{2,4})\\b"
            ) {
                let ns = s as NSString
                let matchList = multiRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
                var result = s
                for m in matchList.reversed() {
                    let swizzle = ns.substring(with: m.range(at: 1))
                    let replacement = "float\(swizzle.count)(\(name))"
                    result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
                }
                s = result
            }

            // 2. Single-component swizzle: `scalar.x` → `scalar` (strip the swizzle).
            //    Negative lookbehind prevents matching `vec.name` (where name follows a dot).
            s = s.replacingOccurrences(
                of: "(?<!\\.)\\b\(escaped)\\.(x|y|z|w|r|g|b|a)\\b",
                with: name,
                options: .regularExpression
            )
        }
        return s
    }

    // MARK: - Metal Source Generation

    // MARK: - Helper Function Extraction & Inline Expansion

    /// Detects inline function definitions in the shader body (e.g. `float3 Get1(float2 uvi) { ... }`).
    /// Single-expression bodies become simple `#define` macros (no lambda needed).
    /// Multi-statement bodies are returned as `InlineHelper` structs — Metal doesn't support C++
    /// lambdas so the old `[&](...) -> T { body }(args)` IIFE pattern is invalid.
    private static func extractHelperFunctions(from body: String) -> (body: String, hoisted: [String], inlineHelpers: [InlineHelper]) {
        var macros:  [String]       = []
        var helpers: [InlineHelper] = []
        var cleanLines: [String]    = []

        let lines = body.components(separatedBy: "\n")
        var i = 0

        // Pattern: type name(params) {
        let funcDefPattern = #"^\s*(float[234]?|int|void|bool|half[234]?)\s+([a-zA-Z_]\w*)\s*\(([^)]*)\)\s*\{"#
        let funcDefRegex = try? NSRegularExpression(pattern: funcDefPattern)

        while i < lines.count {
            let line  = lines[i]
            let nsLine = line as NSString
            let match = funcDefRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length))

            if let match, match.numberOfRanges >= 4 {
                let returnType = nsLine.substring(with: match.range(at: 1))
                let funcName   = nsLine.substring(with: match.range(at: 2))
                let paramsRaw  = nsLine.substring(with: match.range(at: 3))

                // Collect full function source until braces balance
                var funcSource  = line
                var braceDepth  = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                var j = i + 1
                while braceDepth > 0 && j < lines.count {
                    funcSource += "\n" + lines[j]
                    braceDepth += lines[j].filter { $0 == "{" }.count - lines[j].filter { $0 == "}" }.count
                    j += 1
                }

                if let openBrace  = funcSource.firstIndex(of: "{"),
                   let closeBrace = funcSource.lastIndex(of: "}") {
                    let innerBody = String(funcSource[funcSource.index(after: openBrace)..<closeBrace])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // Parse parameter types and names
                    var paramTypes: [String] = []
                    var paramNames: [String] = []
                    for param in paramsRaw.components(separatedBy: ",") {
                        let parts = param.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if parts.count >= 2 {
                            paramTypes.append(parts.dropLast().joined(separator: " "))
                            paramNames.append(parts.last!)
                        } else if let only = parts.first, !only.isEmpty {
                            paramTypes.append("float")
                            paramNames.append(only)
                        }
                    }
                    let macroArgs = paramNames.joined(separator: ", ")

                    // Detect single-return body: the entire body is `return <expr>;`
                    let singleReturnPat = #"^\s*return\s+(.*?)\s*;\s*$"#
                    var singleExpr: String? = nil
                    if let rx = try? NSRegularExpression(pattern: singleReturnPat, options: .dotMatchesLineSeparators),
                       let m = rx.firstMatch(in: innerBody, range: NSRange(innerBody.startIndex..., in: innerBody)) {
                        let candidate = (innerBody as NSString).substring(with: m.range(at: 1))
                        if !candidate.contains(";") { singleExpr = candidate }
                    }

                    if let expr = singleExpr {
                        // Single expression: safe as a simple #define (no lambda)
                        macros.append("#define \(funcName)(\(macroArgs)) (\(returnType))(\(expr))")
                    } else {
                        // Multi-statement: store for inline expansion at call sites
                        let bodyLines = innerBody
                            .components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        helpers.append(InlineHelper(
                            name: funcName, returnType: returnType,
                            paramTypes: paramTypes, paramNames: paramNames,
                            bodyLines: bodyLines))
                    }
                }
                i = j
            } else {
                cleanLines.append(line)
                i += 1
            }
        }

        return (cleanLines.joined(separator: "\n"), macros, helpers)
    }

    // MARK: - Inline Helper Expansion

    /// Replaces every call to a multi-statement helper with an anonymous-block inline expansion.
    /// Metal doesn't support C++ lambdas, but it does support anonymous scoped blocks (`{ }`),
    /// which naturally inherit all outer-scope variables without extra parameters.
    private static func inlineExpandHelperCalls(_ body: String, helpers: [InlineHelper]) -> String {
        if helpers.isEmpty { return body }
        var lines = body.components(separatedBy: "\n")
        var counter = 0

        for helper in helpers {
            var processed: [String] = []
            for line in lines {
                guard line.contains(helper.name) else { processed.append(line); continue }

                var expandedBlocks: [String] = []
                var currentLine = line
                var guard2 = 0
                while guard2 < 20, let call = findNextHelperCall(in: currentLine, funcName: helper.name) {
                    guard2 += 1
                    let id = counter; counter += 1
                    let (blockLines, resultVar) = makeInlineBlock(helper: helper, args: call.args, id: id)
                    expandedBlocks.append(contentsOf: blockLines)
                    currentLine = String(currentLine[..<call.range.lowerBound])
                                + resultVar
                                + String(currentLine[call.range.upperBound...])
                }
                processed.append(contentsOf: expandedBlocks)
                processed.append(currentLine)
            }
            lines = processed
        }
        return lines.joined(separator: "\n")
    }

    /// Finds the first well-formed call to `funcName(...)` in `line` (word-boundary-aware,
    /// balanced parens).  Returns the full call range and the split argument list.
    private static func findNextHelperCall(in line: String, funcName: String) -> HelperCallSite? {
        var searchIdx = line.startIndex
        while searchIdx < line.endIndex {
            guard let nameRange = line.range(of: funcName, range: searchIdx..<line.endIndex) else { return nil }

            let prevOK: Bool = nameRange.lowerBound == line.startIndex ? true : {
                let prev = line[line.index(before: nameRange.lowerBound)]
                return !prev.isLetter && !prev.isNumber && prev != "_"
            }()
            let afterOK: Bool = nameRange.upperBound >= line.endIndex ? true : {
                let next = line[nameRange.upperBound]
                return !next.isLetter && !next.isNumber && next != "_"
            }()

            if prevOK && afterOK {
                var parenIdx = nameRange.upperBound
                while parenIdx < line.endIndex && line[parenIdx] == " " { parenIdx = line.index(after: parenIdx) }
                if parenIdx < line.endIndex && line[parenIdx] == "(" {
                    var depth = 1
                    var idx = line.index(after: parenIdx)
                    while idx < line.endIndex && depth > 0 {
                        if line[idx] == "(" { depth += 1 }
                        else if line[idx] == ")" { depth -= 1; if depth == 0 { break } }
                        idx = line.index(after: idx)
                    }
                    let argsStr = String(line[line.index(after: parenIdx)..<idx])
                    let callEnd = line.index(after: idx)
                    return HelperCallSite(range: nameRange.lowerBound..<callEnd,
                                         args: splitTopLevelCommas(argsStr))
                }
            }
            searchIdx = line.index(after: nameRange.lowerBound)
        }
        return nil
    }

    /// Splits a top-level-comma-separated argument string (ignores commas inside parens/brackets).
    private static func splitTopLevelCommas(_ s: String) -> [String] {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return [] }
        var result: [String] = []; var current = ""; var depth = 0
        for c in t {
            switch c {
            case "(", "[": depth += 1; current.append(c)
            case ")", "]": depth -= 1; current.append(c)
            case "," where depth == 0: result.append(current); current = ""
            default: current.append(c)
            }
        }
        result.append(current)
        return result
    }

    /// Generates the anonymous-block inline expansion for a single helper call.
    ///
    ///   ReturnType _md_Name_N_ret;
    ///   { ParamType _md_Name_N_p = (arg); <renamed body>; _md_Name_N_ret = returnExpr; }
    private static func makeInlineBlock(helper: InlineHelper, args: [String], id: Int) -> (lines: [String], resultVar: String) {
        let prefix    = "_md_\(helper.name)_\(id)"
        let resultVar = "\(prefix)_ret"
        var out: [String] = []

        // Collect local variable names from body for renaming (handles comma-decls like `float2 a, b;`)
        var localVars: [String] = []
        let declPat = #"^\s*(?:float[234]?|int|bool|half[234]?|uint)\s+([\w ,]+?)(?:\s*=|\s*;)"#
        if let rx = try? NSRegularExpression(pattern: declPat) {
            for bLine in helper.bodyLines {
                let ns = bLine as NSString
                if let m = rx.firstMatch(in: bLine, range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges >= 2 {
                    for part in (ns.substring(with: m.range(at: 1))).components(separatedBy: ",") {
                        let vn = part.trimmingCharacters(in: .whitespaces)
                        if !vn.isEmpty { localVars.append(vn) }
                    }
                }
            }
        }

        // Build rename table, longer names first (prevents partial replacements)
        var renames: [(String, String)] = []
        for p in helper.paramNames { renames.append((p, "\(prefix)_\(p)")) }
        for lv in localVars where !helper.paramNames.contains(lv) { renames.append((lv, "\(prefix)_\(lv)")) }
        renames.sort { $0.0.count > $1.0.count }

        if helper.returnType != "void" { out.append("\(helper.returnType) \(resultVar);") }
        out.append("{")
        for (idx, (pType, pName)) in zip(helper.paramTypes, helper.paramNames).enumerated() {
            let argExpr = idx < args.count ? args[idx].trimmingCharacters(in: .whitespaces) : "0"
            out.append("    \(pType) \(prefix)_\(pName) = (\(argExpr));")
        }
        for bLine in helper.bodyLines {
            var stmt = bLine
            for (from, to) in renames {
                stmt = stmt.replacingOccurrences(
                    of: #"\b\#(NSRegularExpression.escapedPattern(for: from))\b"#,
                    with: to, options: .regularExpression)
            }
            let t = stmt.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("return ") {
                var expr = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if expr.hasSuffix(";") { expr = String(expr.dropLast()).trimmingCharacters(in: .whitespaces) }
                out.append("    \(resultVar) = \(expr);")
            } else {
                out.append("    \(stmt)")
            }
        }
        out.append("}")
        return (out, resultVar)
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

        // Helper: HLSL normalize() accepts scalars (returns sign(x)), Metal does not
        static float normalize(float x) { return sign(x); }

        // Helpers for HLSL-style implicit float2→float3 conversion
        static float3 _md_f3(float2 v) { return float3(v, 0); }
        static float3 _md_f3(float3 v) { return v; }
        static float3 _md_f3(float v) { return float3(v); }

        // HLSL cross() allows scalar promotion for either argument; MSL requires float3+float3
        static float3 cross(float3 a, float b) { return cross(a, float3(b)); }
        static float3 cross(float b, float3 a) { return cross(float3(b), a); }
        static float3 cross(float3 a, float2 b) { return cross(a, float3(b, 0)); }
        static float3 cross(float2 b, float3 a) { return cross(float3(b, 0), a); }

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
