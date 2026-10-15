"""Tests for the CEL rule engine — parser, evaluator, context, builtins."""

import sys
from pathlib import Path

# add parent to path so imports work
sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

from engine.cel_parser import parse, Lexer, TokenType, ExprKind
from engine.cel_evaluator import evaluate
from engine.context import create_context
from engine.builtins import make_builtins
from models.rules import DailyStats, Goal, ExecutionContext


class TestLexer:
    def test_basic_tokens(self):
        lex = Lexer("123 45.6 'hello' true")
        tokens = []
        while True:
            t = lex.next_token()
            tokens.append(t)
            if t.type == TokenType.EOF:
                break

        assert tokens[0].type == TokenType.INT
        assert tokens[0].value == 123
        assert tokens[1].type == TokenType.FLOAT
        assert tokens[1].value == 45.6
        assert tokens[2].type == TokenType.STRING
        assert tokens[2].value == "hello"
        assert tokens[3].type == TokenType.INT
        assert tokens[3].value == 1  # true → 1

    def test_operators(self):
        expected = [
            TokenType.PLUS, TokenType.MINUS, TokenType.STAR,
            TokenType.SLASH, TokenType.PERCENT, TokenType.EQ,
            TokenType.NEQ, TokenType.LT, TokenType.LE,
            TokenType.GT, TokenType.GE, TokenType.AND,
            TokenType.OR, TokenType.NOT,
        ]
        got = []
        lex = Lexer("+ - * / % == != < <= > >= && || !")
        while True:
            t = lex.next_token()
            if t.type == TokenType.EOF:
                break
            got.append(t.type)
        assert got == expected


class TestParser:
    def test_literal(self):
        ast = parse("42")
        assert ast.kind == ExprKind.LITERAL
        assert ast.value == 42

    def test_arithmetic(self):
        ast = parse("1 + 2 * 3")
        assert ast.op == "+"
        assert ast.left.value == 1
        assert ast.right.op == "*"
        assert ast.right.left.value == 2
        assert ast.right.right.value == 3

    def test_comparison(self):
        ast = parse("a > 5")
        assert ast.op == ">"
        assert ast.left.kind == ExprKind.IDENT
        assert ast.left.value == "a"

    def test_logic(self):
        ast = parse("a && b || c")
        assert ast.op == "||"
        assert ast.left.op == "&&"

    def test_ternary(self):
        ast = parse("a ? 1 : 2")
        assert ast.kind == ExprKind.TERNARY
        assert ast.left.value == 1
        assert ast.right.value == 2

    def test_member_access(self):
        ast = parse("today.calories")
        assert ast.kind == ExprKind.MEMBER
        assert ast.left.value == "today"
        assert ast.right.value == "calories"

    def test_function_call(self):
        ast = parse("streak.current()")
        assert ast.kind == ExprKind.CALL
        assert ast.left.kind == ExprKind.MEMBER

    def test_complex(self):
        ast = parse(
            "today.calories >= goal.calories * 0.9 "
            "&& today.calories <= goal.calories * 1.1"
        )
        assert ast.op == "&&"
        left = ast.left
        assert left.op == ">="
        assert left.left.kind == ExprKind.MEMBER


class TestEvaluator:
    def test_arithmetic(self):
        ctx = ExecutionContext()
        assert evaluate(parse("1 + 2 * 3"), ctx) == 7
        assert evaluate(parse("10 / 2"), ctx) == 5
        assert evaluate(parse("10 % 3"), ctx) == 1

    def test_comparison(self):
        ctx = ExecutionContext(variables={"a": 5, "b": 3})
        assert evaluate(parse("a > b"), ctx) is True
        assert evaluate(parse("a == b"), ctx) is False

    def test_logic(self):
        ctx = ExecutionContext()
        assert evaluate(parse("true && false"), ctx) == 0
        assert evaluate(parse("true || false"), ctx) == 1
        assert evaluate(parse("!false"), ctx) is True

    def test_ternary(self):
        ctx = ExecutionContext(variables={"x": 10})
        result = evaluate(parse("x > 5 ? 'big' : 'small'"), ctx)
        assert result == "big"

    def test_member_access(self):
        ctx = ExecutionContext(variables={"today": {"calories": 1500}})
        assert evaluate(parse("today.calories"), ctx) == 1500

    def test_list_map(self):
        ctx = ExecutionContext()
        lst = evaluate(parse("[1, 2, 3]"), ctx)
        assert lst == [1, 2, 3]
        m = evaluate(parse('{"a": 1, "b": 2}'), ctx)
        assert m == {"a": 1, "b": 2}

    def test_undefined_variable(self):
        ctx = ExecutionContext()
        with pytest.raises(NameError):
            evaluate(parse("nonexistent"), ctx)


class TestContext:
    def test_goal_check(self):
        stats = DailyStats(calories=1800, protein=55, meals_count=3)
        goal = Goal(calories=2000, protein=50)
        ctx = create_context(daily_stats=stats, goal=goal, streak_days=3)

        # today.calories < goal.calories
        assert evaluate(parse("today.calories < goal.calories"), ctx) is True
        # protein goal met
        assert evaluate(parse("today.protein >= goal.protein"), ctx) is True
        # streak
        assert evaluate(parse("user.streak >= 3"), ctx) is True
        assert evaluate(parse("user.streak >= 7"), ctx) is False

    def test_builtin_functions(self):
        ctx = create_context()
        result = evaluate(parse("nutrition.is_greens('spinach')"), ctx)
        assert result is True
        result = evaluate(parse("nutrition.is_greens('steak')"), ctx)
        assert result is False
        result = evaluate(parse("nutrition.is_processed('potato chips')"), ctx)
        assert result is True
        result = evaluate(parse("nutrition.is_processed('apple')"), ctx)
        assert result is False


class TestBuiltins:
    def test_make_builtins_with_context(self):
        fn = make_builtins(
            daily_stats=DailyStats(calories=500),
            goal=Goal(calories=2000),
            streak_days=5,
        )
        assert fn["stats.calories_left"]() == 1500
        assert fn["streak.current"]() == 5


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
