package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// A C type as written in the header: `WGPU_NULLABLE WGPUFoo const * const *`.
C_Type :: struct {
	name:     string,
	pointers: int,
	is_const: bool,
	nullable: bool,
}

Param :: struct {
	name: string,
	type: C_Type,
}

Constant :: struct {
	name:  string,
	value: []Token,
}

// A primitive typedef such as `typedef uint64_t WGPUFlags;`.
Alias :: struct {
	name: string,
	type: string,
}

Enum_Entry :: struct {
	name:  string, // Without the `WGPUType_` prefix.
	value: u64,
	text:  string, // The value as written, e.g. `0x00000001`.
}

Enum :: struct {
	name:    string,
	entries: [dynamic]Enum_Entry,
}

Struct :: struct {
	name:   string,
	fields: [dynamic]Param,
}

// A callback typedef or an exported function.
Proc :: struct {
	name:   string,
	ret:    C_Type,
	params: [dynamic]Param,
}

Init_Expr :: struct {
	// For a nested `_wgpu_MAKE_INIT_STRUCT(T, {...})`, `struct_name` is T and `fields` holds its values.
	// Otherwise `atom` is the token (`NULL`, `1`, `WGPU_FOO_INIT`, ...) and `arg` the argument of
	// `_wgpu_ENUM_ZERO_INIT(T)`.
	atom:        string,
	arg:         string,
	struct_name: string,
	fields:      [dynamic]Init_Field,
}

Init_Field :: struct {
	name:  string,
	value: Init_Expr,
}

// A `#define WGPU_FOO_INIT _wgpu_MAKE_INIT_STRUCT(WGPUFoo, {...})` default value.
Init :: struct {
	name:  string,
	value: Init_Expr,
}

Type_Kind :: enum {
	None,
	Alias,
	Handle,
	Enum,
	Bitflag,
	Callback,
	Struct,
}

IR :: struct {
	constants: [dynamic]Constant,
	aliases:   [dynamic]Alias,
	handles:   [dynamic]string,
	enums:     [dynamic]Enum,
	bitflags:  [dynamic]Enum,
	callbacks: [dynamic]Proc,
	structs:   [dynamic]Struct,
	inits:     [dynamic]Init,
	functions: [dynamic]Proc,
	kinds:     map[string]Type_Kind,
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
	ir:     ^IR,
	err:    string,
}

// Preprocessor conditions whose content is not part of the C API.
SKIPPED_CONDITIONS :: [?]string{"__cplusplus", "WGPU_SKIP_PROCS", "__EMSCRIPTEN__", "WGPU_SHARED_LIBRARY"}

// Macros that expand to nothing in the C API.
IGNORED_IDENTS :: [?]string{
	"WGPU_OBJECT_ATTRIBUTE",
	"WGPU_ENUM_ATTRIBUTE",
	"WGPU_STRUCTURE_ATTRIBUTE",
	"WGPU_FUNCTION_ATTRIBUTE",
}

parse :: proc(src: string) -> (ir: ^IR, err: string) {
	ir = new(IR)
	p := Parser{tokens = lex(src), ir = ir}
	if !parse_file(&p) {
		return ir, p.err
	}
	return ir, ""
}

@(private = "file")
peek :: proc(p: ^Parser, offset := 0) -> Token {
	return p.tokens[min(p.pos + offset, len(p.tokens) - 1)]
}

@(private = "file")
next :: proc(p: ^Parser) -> Token {
	t := peek(p)
	p.pos = min(p.pos + 1, len(p.tokens) - 1)
	return t
}

@(private = "file")
fail :: proc(p: ^Parser, format: string, args: ..any) -> bool {
	if p.err == "" {
		t := peek(p)
		p.err = fmt.aprintf("line %d near '%s': %s", t.line, t.text, fmt.aprintf(format, ..args))
	}
	return false
}

@(private = "file")
accept :: proc(p: ^Parser, text: string) -> bool {
	if peek(p).kind != .Directive && peek(p).text == text {
		next(p)
		return true
	}
	return false
}

@(private = "file")
expect :: proc(p: ^Parser, text: string) -> bool {
	if !accept(p, text) {
		return fail(p, "expected '%s'", text)
	}
	return true
}

@(private = "file")
expect_ident :: proc(p: ^Parser) -> (string, bool) {
	t := peek(p)
	if t.kind != .Ident {
		return "", fail(p, "expected an identifier")
	}
	next(p)
	return t.text, true
}

@(private = "file")
skip_attributes :: proc(p: ^Parser) {
	outer: for {
		t := peek(p)
		for ignored in IGNORED_IDENTS {
			if t.kind == .Ident && t.text == ignored {
				next(p)
				continue outer
			}
		}
		return
	}
}

@(private = "file")
add_kind :: proc(p: ^Parser, name: string, kind: Type_Kind) {
	p.ir.kinds[name] = kind
}

@(private = "file")
parse_file :: proc(p: ^Parser) -> bool {
	// One entry per open #if: whether its content is skipped.
	skip_stack := make([dynamic]bool)
	skipping :: proc(stack: [dynamic]bool) -> bool {
		for s in stack {
			if s {
				return true
			}
		}
		return false
	}

	for peek(p).kind != .EOF {
		t := peek(p)
		if t.kind == .Directive {
			next(p)
			directive := strings.trim_space(t.text[1:])
			word := directive
			if i := strings.index_any(directive, " \t("); i >= 0 {
				word = directive[:i]
			}
			switch word {
			case "if", "ifdef", "ifndef":
				skip := false
				for cond in SKIPPED_CONDITIONS {
					skip ||= strings.contains(directive, cond)
				}
				append(&skip_stack, skip)
			case "else":
				if len(skip_stack) > 0 {
					skip_stack[len(skip_stack) - 1] = !skip_stack[len(skip_stack) - 1]
				}
			case "endif":
				if len(skip_stack) > 0 {
					pop(&skip_stack)
				}
			case "define":
				if !skipping(skip_stack) {
					parse_define(p, t) or_return
				}
			}
			continue
		}
		if skipping(skip_stack) {
			next(p)
			continue
		}
		parse_declaration(p) or_return
	}
	return true
}

// `#define WGPU_NAME value` constants and `#define WGPU_NAME_INIT ...` defaults. Other defines are ignored.
@(private = "file")
parse_define :: proc(p: ^Parser, directive: Token) -> bool {
	tokens := lex(directive.text[1:])
	// tokens: `define`, name, value..., EOF
	if len(tokens) < 3 || tokens[1].kind != .Ident {
		return true
	}
	name := tokens[1].text
	value := tokens[2:len(tokens) - 1]
	if !strings.has_prefix(name, "WGPU_") || len(value) == 0 || name == "WGPU_EXPORT" {
		return true
	}
	if strings.has_suffix(name, "_INIT") {
		sub := Parser{tokens = tokens[2:], ir = p.ir}
		expr, ok := parse_init_expr(&sub)
		if !ok {
			p.err = fmt.aprintf("line %d: in %s: %s", directive.line, name, sub.err)
			return false
		}
		append(&p.ir.inits, Init{name, expr})
		return true
	}
	append(&p.ir.constants, Constant{name, value})
	return true
}

@(private = "file")
parse_init_expr :: proc(p: ^Parser) -> (expr: Init_Expr, ok: bool) {
	t := next(p)
	if t.kind != .Ident && t.kind != .Number {
		return {}, fail(p, "unexpected token in an _INIT macro")
	}
	switch t.text {
	case "_wgpu_MAKE_INIT_STRUCT":
		expect(p, "(") or_return
		expr.struct_name = expect_ident(p) or_return
		expect(p, ",") or_return
		expect(p, "{") or_return
		for !accept(p, "}") {
			d := next(p)
			if d.kind != .Designator {
				return {}, fail(p, "expected a /*.field=*/ designator")
			}
			value := parse_init_expr(p) or_return
			append(&expr.fields, Init_Field{d.text, value})
			accept(p, "_wgpu_COMMA")
		}
		expect(p, ")") or_return
	case "_wgpu_ENUM_ZERO_INIT":
		expect(p, "(") or_return
		expr.atom = t.text
		expr.arg = expect_ident(p) or_return
		expect(p, ")") or_return
	case:
		expr.atom = t.text
	}
	return expr, true
}

@(private = "file")
parse_declaration :: proc(p: ^Parser) -> bool {
	switch {
	case accept(p, "typedef"):
		return parse_typedef(p)
	case accept(p, "struct"):
		// Forward declaration: `struct WGPUFoo;`
		expect_ident(p) or_return
		return expect(p, ";")
	case accept(p, "static"):
		return parse_flag_value(p)
	case accept(p, "WGPU_EXPORT"):
		return parse_function(p)
	}
	return fail(p, "unknown declaration")
}

@(private = "file")
parse_typedef :: proc(p: ^Parser) -> bool {
	switch {
	case accept(p, "enum"):
		name := expect_ident(p) or_return
		expect(p, "{") or_return
		e := Enum{name = name}
		prefix := fmt.aprintf("%s_", name)
		for !accept(p, "}") {
			entry := expect_ident(p) or_return
			if !strings.has_prefix(entry, prefix) {
				return fail(p, "enum entry without the '%s' prefix", prefix)
			}
			expect(p, "=") or_return
			value := next(p)
			v, ok := strconv.parse_u64(value.text)
			if value.kind != .Number || !ok {
				return fail(p, "expected a number")
			}
			if entry[len(prefix):] != "Force32" {
				append(&e.entries, Enum_Entry{entry[len(prefix):], v, value.text})
			}
			accept(p, ",")
		}
		expect(p, name) or_return
		skip_attributes(p)
		append(&p.ir.enums, e)
		add_kind(p, name, .Enum)
		return expect(p, ";")

	case peek(p).text == "struct" && peek(p, 2).text == "*":
		// Handle: `typedef struct WGPUFooImpl* WGPUFoo;`
		next(p)
		next(p)
		next(p)
		name := expect_ident(p) or_return
		skip_attributes(p)
		append(&p.ir.handles, name)
		add_kind(p, name, .Handle)
		return expect(p, ";")

	case accept(p, "struct"):
		name := expect_ident(p) or_return
		expect(p, "{") or_return
		s := Struct{name = name}
		for !accept(p, "}") {
			field := parse_param(p) or_return
			append(&s.fields, field)
			expect(p, ";") or_return
		}
		expect(p, name) or_return
		skip_attributes(p)
		append(&p.ir.structs, s)
		add_kind(p, name, .Struct)
		return expect(p, ";")
	}

	ret := parse_type(p) or_return
	if accept(p, "(") {
		// Callback: `typedef void (*WGPUFoo)(params);`
		expect(p, "*") or_return
		name := expect_ident(p) or_return
		expect(p, ")") or_return
		cb := Proc{name = name, ret = ret}
		parse_params(p, &cb.params) or_return
		skip_attributes(p)
		append(&p.ir.callbacks, cb)
		add_kind(p, name, .Callback)
		return expect(p, ";")
	}

	// `typedef WGPUFlags WGPUFoo;` declares a bitflag type, other typedefs are primitive aliases.
	name := expect_ident(p) or_return
	if ret.name == "WGPUFlags" {
		append(&p.ir.bitflags, Enum{name = name})
		add_kind(p, name, .Bitflag)
	} else {
		append(&p.ir.aliases, Alias{name, ret.name})
		add_kind(p, name, .Alias)
	}
	return expect(p, ";")
}

// `static const WGPUFoo WGPUFoo_Bar = 0x...;`
@(private = "file")
parse_flag_value :: proc(p: ^Parser) -> bool {
	expect(p, "const") or_return
	type := expect_ident(p) or_return
	name := expect_ident(p) or_return
	expect(p, "=") or_return
	value := next(p)
	v, ok := strconv.parse_u64(value.text)
	if value.kind != .Number || !ok {
		return fail(p, "expected a number")
	}
	expect(p, ";") or_return

	for &flags in p.ir.bitflags {
		if flags.name == type {
			prefix := fmt.aprintf("%s_", type)
			if !strings.has_prefix(name, prefix) {
				return fail(p, "flag value without the '%s' prefix", prefix)
			}
			append(&flags.entries, Enum_Entry{name[len(prefix):], v, value.text})
			return true
		}
	}
	return fail(p, "static const of unknown flag type '%s'", type)
}

@(private = "file")
parse_function :: proc(p: ^Parser) -> bool {
	f := Proc{}
	f.ret = parse_type(p) or_return
	f.name = expect_ident(p) or_return
	parse_params(p, &f.params) or_return
	skip_attributes(p)
	append(&p.ir.functions, f)
	return expect(p, ";")
}

@(private = "file")
parse_params :: proc(p: ^Parser, params: ^[dynamic]Param) -> bool {
	expect(p, "(") or_return
	if peek(p).text == "void" && peek(p, 1).text == ")" {
		next(p)
	}
	for !accept(p, ")") {
		param := parse_param(p) or_return
		append(params, param)
		accept(p, ",")
	}
	return true
}

@(private = "file")
parse_param :: proc(p: ^Parser) -> (param: Param, ok: bool) {
	param.type = parse_type(p) or_return
	param.name = expect_ident(p) or_return
	return param, true
}

@(private = "file")
parse_type :: proc(p: ^Parser) -> (t: C_Type, ok: bool) {
	if accept(p, "WGPU_NULLABLE") {
		t.nullable = true
	}
	if accept(p, "const") {
		t.is_const = true
	}
	accept(p, "struct")
	t.name = expect_ident(p) or_return
	for {
		switch {
		case accept(p, "const"):
			t.is_const = true
		case accept(p, "*"):
			t.pointers += 1
		case:
			return t, true
		}
	}
}
