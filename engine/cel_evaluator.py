"""CEL expression evaluator — AST walker with execution context.

Evaluates parsed CEL expressions against an ExecutionContext,
mirroring Superscript-iOS's cel-eval Rust library behavior.
"""

from typing import Any

from .cel_parser import Expr, ExprKind


def evaluate(expr: Expr, ctx) -> Any:
    """Evaluate a parsed CEL expression against an execution context."""
    return _eval(expr, ctx)


def _eval(node: Expr, ctx) -> Any:
    if node.kind == ExprKind.LITERAL:
        return node.value

    if node.kind == ExprKind.IDENT:
        val = ctx.resolve(node.value)
        if val is not None:
            return val
        fn = ctx.functions.get(node.value)
        if fn is not None:
            return fn
        raise NameError(f"Undefined variable or function: '{node.value}'")

    if node.kind == ExprKind.UNARY:
        operand = _eval(node.left, ctx)
        if node.op == "-":
            return -operand
        if node.op == "!":
            return not _truthy(operand)
        raise ValueError(f"Unknown unary operator: {node.op}")

    if node.kind == ExprKind.BINARY:
        return _eval_binary(node, ctx)

    if node.kind == ExprKind.TERNARY:
        cond = _truthy(_eval(node.condition, ctx))
        return _eval(node.left, ctx) if cond else _eval(node.right, ctx)

    if node.kind == ExprKind.MEMBER:
        obj = _eval(node.left, ctx)
        if isinstance(node.right, Expr) and node.right.kind == ExprKind.LITERAL:
            field = node.right.value
        else:
            field = _eval(node.right, ctx)
        if isinstance(obj, dict):
            return obj.get(field)
        if hasattr(obj, field):
            return getattr(obj, field)
        raise AttributeError(f"Object has no attribute '{field}'")

    if node.kind == ExprKind.INDEX:
        obj = _eval(node.left, ctx)
        idx = _eval(node.right, ctx)
        return obj[idx]

    if node.kind == ExprKind.CALL:
        callee = node.left
        args = [_eval(a, ctx) for a in node.args]

        # try to resolve as a dotted function name (e.g. "nutrition.is_greens")
        full_fn_name = _dotted_name(callee)
        if full_fn_name:
            fn = ctx.functions.get(full_fn_name)
            if fn is not None:
                return fn(*args)

        if callee.kind == ExprKind.IDENT:
            fn_name = callee.value
            fn = ctx.functions.get(fn_name)
            if fn is not None:
                return fn(*args)
            raise NameError(f"Undefined function: '{fn_name}'")

        # member function call: obj.method(args)
        if callee.kind == ExprKind.MEMBER:
            obj = _eval(callee.left, ctx)
            method_name = (
                callee.right.value
                if isinstance(callee.right, Expr)
                else callee.right
            )
            method = getattr(obj, method_name, None)
            if method is not None:
                return method(*args)
            raise NameError(f"Object has no method '{method_name}'")
        raise ValueError("Cannot call this expression")

    if node.kind == ExprKind.LIST:
        return [_eval(item, ctx) for item in node.args]

    if node.kind == ExprKind.MAP:
        return {_eval(k, ctx): _eval(v, ctx) for k, v in node.entries}

    raise ValueError(f"Unknown expression kind: {node.kind}")


def _eval_binary(node: Expr, ctx) -> Any:
    """Evaluate binary operators with proper type coercion."""
    left = _eval(node.left, ctx)
    # short-circuit
    if node.op == "&&" and not _truthy(left):
        return left
    if node.op == "||" and _truthy(left):
        return left
    right = _eval(node.right, ctx)

    op = node.op
    if op == "+":
        return left + right
    if op == "-":
        return left - right
    if op == "*":
        return left * right
    if op == "/":
        if right == 0:
            raise ZeroDivisionError("Division by zero in CEL expression")
        return left / right
    if op == "%":
        return left % right
    if op == "==":
        return left == right
    if op == "!=":
        return left != right
    if op == "<":
        return left < right
    if op == "<=":
        return left <= right
    if op == ">":
        return left > right
    if op == ">=":
        return left >= right
    if op == "&&":
        return _truthy(left) and _truthy(right)
    if op == "||":
        return _truthy(left) or _truthy(right)

    raise ValueError(f"Unknown binary operator: {op}")


def _dotted_name(node: Expr) -> str | None:
    """Reconstruct a dotted name from a member access chain.

    MEMBER(IDENT("nutrition"), "is_greens") → "nutrition.is_greens"
    MEMBER(MEMBER(IDENT("a"), "b"), "c") → "a.b.c"
    IDENT("foo") → "foo"
    """
    if node.kind == ExprKind.IDENT:
        return node.value
    if node.kind == ExprKind.MEMBER:
        left = _dotted_name(node.left)
        if left is None:
            return None
        right = node.right.value if isinstance(node.right, Expr) else node.right
        return f"{left}.{right}"
    return None


def _truthy(val: Any) -> bool:
    """CEL truthiness: 0, empty string/list/dict, None, False → false."""
    if val is None:
        return False
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return val != 0
    if isinstance(val, str):
        return len(val) > 0
    if isinstance(val, (list, dict, tuple)):
        return len(val) > 0
    return True
