//
//  ExpressionEvaluator.swift
//  MJDrop
//
//  Tree-walking evaluator for Milkdrop expression ASTs.
//  Evaluates ExprNode trees against an ExpressionContext, executing
//  built-in functions and sanitizing results (NaN/Inf → 0).
//

import Foundation

// MARK: - Evaluator

/// Evaluate an expression node tree against a context.
/// Returns the Float result.
nonisolated func evaluate(_ node: ExprNode, ctx: ExpressionContext) -> Float {
    switch node {
    case .literal(let v):
        return v

    case .variable(let slot):
        return ctx[slot]

    case .unaryMinus(let operand):
        return -evaluate(operand, ctx: ctx)

    case .binaryOp(let op, let left, let right):
        let l = evaluate(left, ctx: ctx)
        let r = evaluate(right, ctx: ctx)
        switch op {
        case .add: return l + r
        case .subtract: return l - r
        case .multiply: return l * r
        case .divide: return r != 0 ? l / r : 0
        case .modulo: return r != 0 ? fmod(l, r) : 0
        case .less: return l < r ? 1 : 0
        case .greater: return l > r ? 1 : 0
        case .lessEqual: return l <= r ? 1 : 0
        case .greaterEqual: return l >= r ? 1 : 0
        case .equal: return abs(l - r) < 0.00001 ? 1 : 0
        case .notEqual: return abs(l - r) >= 0.00001 ? 1 : 0
        case .logicalAnd: return (l != 0 && r != 0) ? 1 : 0
        case .logicalOr: return (l != 0 || r != 0) ? 1 : 0
        }

    case .functionCall(let fn, let args):
        return evaluateFunction(fn, args: args, ctx: ctx)
    }
}

/// Execute a list of assignments against a context.
/// Sanitizes NaN/Inf to 0 after each assignment.
nonisolated func executeExpressions(_ assignments: [CompiledAssignment], ctx: ExpressionContext) {
    for assignment in assignments {
        var result = evaluate(assignment.expression, ctx: ctx)
        // Sanitize
        if result.isNaN || result.isInfinite {
            result = 0
        }
        ctx[assignment.targetSlot] = result
    }
}

// MARK: - Built-in Functions

private nonisolated func evaluateFunction(_ fn: BuiltinFunction, args: [ExprNode], ctx: ExpressionContext) -> Float {
    // Evaluate arguments
    let a: [Float] = args.map { evaluate($0, ctx: ctx) }

    switch fn {
    case .sin:
        return a.count >= 1 ? sinf(a[0]) : 0

    case .cos:
        return a.count >= 1 ? cosf(a[0]) : 0

    case .tan:
        return a.count >= 1 ? tanf(a[0]) : 0

    case .asin:
        guard a.count >= 1 else { return 0 }
        let clamped = Swift.max(-1, Swift.min(1, a[0]))
        return asinf(clamped)

    case .acos:
        guard a.count >= 1 else { return 0 }
        let clamped = Swift.max(-1, Swift.min(1, a[0]))
        return acosf(clamped)

    case .atan:
        return a.count >= 1 ? atanf(a[0]) : 0

    case .atan2:
        return a.count >= 2 ? atan2f(a[0], a[1]) : 0

    case .abs:
        return a.count >= 1 ? Swift.abs(a[0]) : 0

    case .sqrt:
        guard a.count >= 1 else { return 0 }
        return a[0] >= 0 ? sqrtf(a[0]) : 0

    case .sqr:
        return a.count >= 1 ? a[0] * a[0] : 0

    case .pow:
        guard a.count >= 2 else { return 0 }
        let result = powf(a[0], a[1])
        return result.isNaN || result.isInfinite ? 0 : result

    case .log:
        guard a.count >= 1, a[0] > 0 else { return 0 }
        return logf(a[0])

    case .exp:
        guard a.count >= 1 else { return 0 }
        let result = expf(a[0])
        return result.isInfinite ? 1e10 : result

    case .log10:
        guard a.count >= 1, a[0] > 0 else { return 0 }
        return log10f(a[0])

    case .floor:
        return a.count >= 1 ? floorf(a[0]) : 0

    case .ceil:
        return a.count >= 1 ? ceilf(a[0]) : 0

    case .sign:
        guard a.count >= 1 else { return 0 }
        if a[0] > 0 { return 1 }
        if a[0] < 0 { return -1 }
        return 0

    case .frac:
        guard a.count >= 1 else { return 0 }
        return a[0] - floorf(a[0])

    case .int:
        return a.count >= 1 ? floorf(a[0]) : 0

    case .fmod:
        guard a.count >= 2 else { return 0 }
        return a[1] != 0 ? fmodf(a[0], a[1]) : 0

    case .min:
        return a.count >= 2 ? Swift.min(a[0], a[1]) : (a.first ?? 0)

    case .max:
        return a.count >= 2 ? Swift.max(a[0], a[1]) : (a.first ?? 0)

    case .clamp:
        guard a.count >= 3 else { return a.first ?? 0 }
        return Swift.max(a[1], Swift.min(a[2], a[0]))

    case .lerp:
        guard a.count >= 3 else { return a.first ?? 0 }
        return a[0] + a[2] * (a[1] - a[0])

    case .if:
        guard a.count >= 3 else { return 0 }
        return a[0] != 0 ? a[1] : a[2]

    case .above:
        return a.count >= 2 ? (a[0] > a[1] ? 1 : 0) : 0

    case .below:
        return a.count >= 2 ? (a[0] < a[1] ? 1 : 0) : 0

    case .equal:
        return a.count >= 2 ? (Swift.abs(a[0] - a[1]) < 0.00001 ? 1 : 0) : 0

    case .band:
        return a.count >= 2 ? ((a[0] != 0 && a[1] != 0) ? 1 : 0) : 0

    case .bor:
        return a.count >= 2 ? ((a[0] != 0 || a[1] != 0) ? 1 : 0) : 0

    case .bnot:
        return a.count >= 1 ? (a[0] == 0 ? 1 : 0) : 0

    case .rand:
        guard a.count >= 1 else { return 0 }
        let upper = Swift.max(a[0], 1)
        return Float.random(in: 0..<upper)

    case .sigmoid:
        guard a.count >= 1 else { return 0 }
        let clamped = Swift.max(-20, Swift.min(20, a[0]))
        return 1.0 / (1.0 + expf(-clamped))

    case .noise:
        // Simple pseudo-random noise based on input
        guard a.count >= 1 else { return 0 }
        let x = a[0]
        // Simple hash-based noise
        let n = sinf(x * 12.9898 + 78.233) * 43758.5453
        return n - floorf(n)
    }
}
