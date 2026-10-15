"""CEL expression parser — recursive descent.

Implements the subset of CEL used by Cal AI (Superscript-iOS).
Supports: arithmetic, comparison, logic, ternary, member access,
function calls, list/map literals, field selection.

AST mirrors JSONExpression / PassableValue from the Rust library.
"""

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Optional


# ── Tokens ──────────────────────────────────────────────────────────

class TokenType(Enum):
    EOF = auto()
    IDENT = auto()
    INT = auto()
    FLOAT = auto()
    STRING = auto()
    # operators
    PLUS = auto(); MINUS = auto(); STAR = auto(); SLASH = auto(); PERCENT = auto()
    EQ = auto(); NEQ = auto(); LT = auto(); LE = auto(); GT = auto(); GE = auto()
    AND = auto(); OR = auto(); NOT = auto()
    QUESTION = auto(); COLON = auto()
    DOT = auto(); COMMA = auto()
    LPAREN = auto(); RPAREN = auto()
    LBRACKET = auto(); RBRACKET = auto()
    LBRACE = auto(); RBRACE = auto()
    ASSIGN = auto()


@dataclass
class Token:
    type: TokenType
    value: Any = None
    pos: int = 0


KEYWORDS = {
    "true": TokenType.INT,   # bool as int 1
    "false": TokenType.INT,  # bool as int 0
    "null": TokenType.IDENT,
}


class Lexer:
    def __init__(self, source: str):
        self.source = source
        self.pos = 0

    def _peek(self, n: int = 0) -> str:
        if self.pos + n < len(self.source):
            return self.source[self.pos + n]
        return "\0"

    def _advance(self) -> str:
        ch = self._peek()
        self.pos += 1
        return ch

    def _skip_whitespace(self):
        while self._peek().isspace():
            self._advance()

    def _skip_line_comment(self):
        while self._peek() not in ("\n", "\0"):
            self._advance()

    def _read_string(self, quote: str) -> Token:
        start = self.pos
        s = []
        while True:
            ch = self._peek()
            if ch == "\0":
                raise SyntaxError(f"Unterminated string at {start}")
            if ch == "\\":
                self._advance()
                esc = self._advance()
                s.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"', "'": "'"}.get(esc, esc))
            elif ch == quote:
                self._advance()
                break
            else:
                s.append(self._advance())
        return Token(TokenType.STRING, "".join(s), start)

    def _read_number(self, first: str) -> Token:
        start = self.pos - 1
        num = first
        is_float = False
        while self._peek().isdigit():
            num += self._advance()
        if self._peek() == ".":
            is_float = True
            num += self._advance()
            while self._peek().isdigit():
                num += self._advance()
        if is_float:
            return Token(TokenType.FLOAT, float(num), start)
        return Token(TokenType.INT, int(num), start)

    def _read_ident(self, first: str) -> Token:
        start = self.pos - 1
        name = first
        while self._peek().isalnum() or self._peek() == "_":
            name += self._advance()
        kw = KEYWORDS.get(name)
        if kw:
            if name == "true":
                return Token(kw, 1, start)
            elif name == "false":
                return Token(kw, 0, start)
            return Token(kw, name, start)
        return Token(TokenType.IDENT, name, start)

    def next_token(self) -> Token:
        self._skip_whitespace()
        ch = self._peek()
        if ch == "\0":
            return Token(TokenType.EOF, pos=self.pos)
        if ch == "/" and self._peek(1) == "/":
            self._skip_line_comment()
            return self.next_token()

        start = self.pos
        self._advance()

        if ch in ('"', "'"):
            return self._read_string(ch)
        if ch.isdigit():
            return self._read_number(ch)
        if ch.isalpha() or ch == "_":
            return self._read_ident(ch)

        # single/double-char operators
        two_char = {
            "=": {"=": TokenType.EQ},
            "!": {"=": TokenType.NEQ},
            "<": {"=": TokenType.LE},
            ">": {"=": TokenType.GE},
            "&": {"&": TokenType.AND},
            "|": {"|": TokenType.OR},
        }
        if ch in two_char and self._peek() in two_char[ch]:
            self._advance()
            return Token(two_char[ch][self.source[self.pos - 1]], pos=start)

        single = {
            "+": TokenType.PLUS, "-": TokenType.MINUS,
            "*": TokenType.STAR, "/": TokenType.SLASH, "%": TokenType.PERCENT,
            "<": TokenType.LT, ">": TokenType.GT,
            "!": TokenType.NOT,
            "?": TokenType.QUESTION, ":": TokenType.COLON,
            ".": TokenType.DOT, ",": TokenType.COMMA,
            "(": TokenType.LPAREN, ")": TokenType.RPAREN,
            "[": TokenType.LBRACKET, "]": TokenType.RBRACKET,
            "{": TokenType.LBRACE, "}": TokenType.RBRACE,
        }
        if ch in single:
            return Token(single[ch], pos=start)

        raise SyntaxError(f"Unexpected character '{ch}' at position {start}")


# ── AST Nodes ───────────────────────────────────────────────────────

class ExprKind(Enum):
    LITERAL = auto(); IDENT = auto()
    UNARY = auto(); BINARY = auto()
    TERNARY = auto()
    MEMBER = auto(); INDEX = auto()
    CALL = auto()
    LIST = auto(); MAP = auto()


@dataclass
class Expr:
    kind: ExprKind
    value: Any = None
    op: str = ""             # operator for unary/binary
    left: Optional["Expr"] = None
    right: Optional["Expr"] = None
    condition: Optional["Expr"] = None  # for ternary
    args: list["Expr"] = field(default_factory=list)
    entries: list[tuple["Expr", "Expr"]] = field(default_factory=list)  # map entries


# ── Parser ──────────────────────────────────────────────────────────

class Parser:
    """Recursive descent CEL parser.

    Grammar (subset matching Superscript-iOS):
      expr       → conditional
      conditional→ or_expr ("?" or_expr ":" conditional)?
      or_expr    → and_expr ("||" and_expr)*
      and_expr   → equality ("&&" equality)*
      equality   → relational (("==" | "!=") relational)*
      relational → additive (("<" | "<=" | ">" | ">=") additive)*
      additive   → multiplicative (("+" | "-") multiplicative)*
      multi      → unary (("*" | "/" | "%") unary)*
      unary      → ("!" | "-") unary | member
      member     → primary ("." IDENT | "[" expr "]" | "(" args ")")*
      primary    → INT | FLOAT | STRING | IDENT | "(" expr ")"
                 | "[" list_elems "]" | "{" map_entries "}"
    """

    def __init__(self, source: str):
        self.lexer = Lexer(source)
        self.token: Token = self.lexer.next_token()

    def _eat(self, *types: TokenType) -> Token:
        t = self.token
        if t.type not in types:
            expected = " | ".join(t.name for t in types)
            raise SyntaxError(
                f"Expected {expected}, got {t.type.name} ({t.value}) at pos {t.pos}"
            )
        self.token = self.lexer.next_token()
        return t

    def parse(self) -> Expr:
        expr = self._conditional()
        if self.token.type != TokenType.EOF:
            raise SyntaxError(
                f"Unexpected token {self.token.type.name} at pos {self.token.pos}"
            )
        return expr

    def _conditional(self) -> Expr:
        expr = self._or_expr()
        if self.token.type == TokenType.QUESTION:
            self._eat(TokenType.QUESTION)
            true_expr = self._or_expr()
            self._eat(TokenType.COLON)
            false_expr = self._conditional()
            expr = Expr(ExprKind.TERNARY, condition=expr, left=true_expr, right=false_expr)
        return expr

    def _or_expr(self) -> Expr:
        left = self._and_expr()
        while self.token.type == TokenType.OR:
            op = self._eat(TokenType.OR).value
            right = self._and_expr()
            left = Expr(ExprKind.BINARY, op="||", left=left, right=right)
        return left

    def _and_expr(self) -> Expr:
        left = self._equality()
        while self.token.type == TokenType.AND:
            op = self._eat(TokenType.AND).value
            right = self._equality()
            left = Expr(ExprKind.BINARY, op="&&", left=left, right=right)
        return left

    def _equality(self) -> Expr:
        left = self._relational()
        while self.token.type in (TokenType.EQ, TokenType.NEQ):
            op = "==" if self.token.type == TokenType.EQ else "!="
            self._eat(self.token.type)
            right = self._relational()
            left = Expr(ExprKind.BINARY, op=op, left=left, right=right)
        return left

    def _relational(self) -> Expr:
        left = self._additive()
        while self.token.type in (TokenType.LT, TokenType.LE, TokenType.GT, TokenType.GE):
            op_map = {
                TokenType.LT: "<", TokenType.LE: "<=",
                TokenType.GT: ">", TokenType.GE: ">=",
            }
            op = op_map[self.token.type]
            self._eat(self.token.type)
            right = self._additive()
            left = Expr(ExprKind.BINARY, op=op, left=left, right=right)
        return left

    def _additive(self) -> Expr:
        left = self._multiplicative()
        while self.token.type in (TokenType.PLUS, TokenType.MINUS):
            op = "+" if self.token.type == TokenType.PLUS else "-"
            self._eat(self.token.type)
            right = self._multiplicative()
            left = Expr(ExprKind.BINARY, op=op, left=left, right=right)
        return left

    def _multiplicative(self) -> Expr:
        left = self._unary()
        while self.token.type in (TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            op = {TokenType.STAR: "*", TokenType.SLASH: "/", TokenType.PERCENT: "%"}[
                self.token.type
            ]
            self._eat(self.token.type)
            right = self._unary()
            left = Expr(ExprKind.BINARY, op=op, left=left, right=right)
        return left

    def _unary(self) -> Expr:
        if self.token.type in (TokenType.NOT, TokenType.MINUS):
            op = "!" if self.token.type == TokenType.NOT else "-"
            self._eat(self.token.type)
            expr = self._unary()
            return Expr(ExprKind.UNARY, op=op, left=expr)
        return self._member()

    def _member(self) -> Expr:
        expr = self._primary()
        while True:
            if self.token.type == TokenType.DOT:
                self._eat(TokenType.DOT)
                name = self._eat(TokenType.IDENT).value
                expr = Expr(ExprKind.MEMBER, left=expr, right=Expr(ExprKind.LITERAL, name))
            elif self.token.type == TokenType.LBRACKET:
                self._eat(TokenType.LBRACKET)
                idx = self.parse()  # parse full expression as index
                self._eat(TokenType.RBRACKET)
                expr = Expr(ExprKind.INDEX, left=expr, right=idx)
            elif self.token.type == TokenType.LPAREN:
                expr = self._parse_call(expr)
            else:
                break
        return expr

    def _parse_call(self, callee: Expr) -> Expr:
        self._eat(TokenType.LPAREN)
        args = []
        if self.token.type != TokenType.RPAREN:
            args.append(self._conditional())
            while self.token.type == TokenType.COMMA:
                self._eat(TokenType.COMMA)
                args.append(self._conditional())
        self._eat(TokenType.RPAREN)
        return Expr(ExprKind.CALL, left=callee, args=args)

    def _primary(self) -> Expr:
        tok = self.token
        if tok.type == TokenType.INT:
            self._eat(TokenType.INT)
            return Expr(ExprKind.LITERAL, tok.value)
        if tok.type == TokenType.FLOAT:
            self._eat(TokenType.FLOAT)
            return Expr(ExprKind.LITERAL, tok.value)
        if tok.type == TokenType.STRING:
            self._eat(TokenType.STRING)
            return Expr(ExprKind.LITERAL, tok.value)
        if tok.type == TokenType.IDENT:
            self._eat(TokenType.IDENT)
            return Expr(ExprKind.IDENT, tok.value)
        if tok.type == TokenType.LPAREN:
            self._eat(TokenType.LPAREN)
            expr = self.parse()
            self._eat(TokenType.RPAREN)
            return expr
        if tok.type == TokenType.LBRACKET:
            return self._parse_list()
        if tok.type == TokenType.LBRACE:
            return self._parse_map()
        raise SyntaxError(f"Unexpected token {tok.type.name} at pos {tok.pos}")

    def _parse_list(self) -> Expr:
        self._eat(TokenType.LBRACKET)
        items = []
        if self.token.type != TokenType.RBRACKET:
            items.append(self._conditional())
            while self.token.type == TokenType.COMMA:
                self._eat(TokenType.COMMA)
                items.append(self._conditional())
        self._eat(TokenType.RBRACKET)
        return Expr(ExprKind.LIST, args=items)

    def _parse_map(self) -> Expr:
        self._eat(TokenType.LBRACE)
        entries: list[tuple[Expr, Expr]] = []
        if self.token.type != TokenType.RBRACE:
            key = self._conditional()
            self._eat(TokenType.COLON)
            val = self._conditional()
            entries.append((key, val))
            while self.token.type == TokenType.COMMA:
                self._eat(TokenType.COMMA)
                key = self._conditional()
                self._eat(TokenType.COLON)
                val = self._conditional()
                entries.append((key, val))
        self._eat(TokenType.RBRACE)
        return Expr(ExprKind.MAP, entries=entries)


def parse(source: str) -> Expr:
    """Parse a CEL expression string into an AST."""
    return Parser(source).parse()
