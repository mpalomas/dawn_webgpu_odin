package main

import "core:strings"

Token_Kind :: enum {
	EOF,
	Ident,
	Number,
	String,
	Punct,
	// A whole preprocessor line, continuation lines included. The parser lexes its text again when needed.
	Directive,
	// A `/*.field=*/` comment, which Dawn's `_INIT` macros use to name each value.
	Designator,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	line: int,
}

is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// Splits C source into tokens. Comments are dropped, except designator comments.
// Backslashes are treated as whitespace, so the body of a multi-line macro lexes like ordinary code.
lex :: proc(src: string, allocator := context.allocator) -> []Token {
	tokens := make([dynamic]Token, allocator)
	i := 0
	line := 1
	line_start := true

	for i < len(src) {
		c := src[i]
		switch {
		case c == '\n':
			line += 1
			line_start = true
			i += 1
		case c == ' ' || c == '\t' || c == '\r' || c == '\\':
			i += 1
		case c == '#' && line_start:
			start := i
			for i < len(src) && !(src[i] == '\n' && src[i - 1] != '\\') {
				if src[i] == '\n' {
					line += 1
				}
				i += 1
			}
			append(&tokens, Token{.Directive, src[start:i], line})
		case c == '/' && i + 1 < len(src) && src[i + 1] == '/':
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
		case c == '/' && i + 1 < len(src) && src[i + 1] == '*':
			end := strings.index(src[i + 2:], "*/")
			body := src[i + 2:] if end < 0 else src[i + 2:][:end]
			if strings.has_prefix(body, ".") && strings.has_suffix(body, "=") {
				append(&tokens, Token{.Designator, body[1:len(body) - 1], line})
			}
			line += strings.count(body, "\n")
			i = len(src) if end < 0 else i + 2 + end + 2
			line_start = false
		case is_ident_start(c):
			start := i
			for i < len(src) && is_ident_char(src[i]) {
				i += 1
			}
			append(&tokens, Token{.Ident, src[start:i], line})
			line_start = false
		case is_digit(c) || (c == '.' && i + 1 < len(src) && is_digit(src[i + 1])):
			start := i
			for i < len(src) && (is_ident_char(src[i]) || src[i] == '.') {
				i += 1
			}
			append(&tokens, Token{.Number, src[start:i], line})
			line_start = false
		case c == '"':
			start := i
			i += 1
			for i < len(src) && src[i] != '"' {
				i += 2 if src[i] == '\\' else 1
			}
			i = min(i + 1, len(src))
			append(&tokens, Token{.String, src[start:i], line})
			line_start = false
		case:
			append(&tokens, Token{.Punct, src[i:i + 1], line})
			i += 1
			line_start = false
		}
	}
	append(&tokens, Token{.EOF, "", line})
	return tokens[:]
}
