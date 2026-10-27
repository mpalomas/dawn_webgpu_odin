package main

import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

HEADER_PATH :: #directory + "../../dawn/include/dawn/webgpu.h"
VERSION_PATH :: #directory + "../../dawn/include/dawn/dawn_version.h"
GENERATED_PATH :: #directory + "../../wgpu/wgpu_generated.odin"

// The declarations most snippets need.
PRELUDE :: `
typedef uint64_t WGPUFlags;
typedef uint32_t WGPUBool;
typedef enum WGPUSType {
    WGPUSType_ShaderSourceWGSL = 0x00000002,
} WGPUSType WGPU_ENUM_ATTRIBUTE;
typedef struct WGPUChainedStruct {
    struct WGPUChainedStruct * next;
    WGPUSType sType;
} WGPUChainedStruct WGPU_STRUCTURE_ATTRIBUTE;
`

// Generates Odin from a C snippet and checks that `want` appears in the output.
@(private = "file")
expect_output :: proc(t: ^testing.T, src: string, want: ..string, loc := #caller_location) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	out, err := generate(src, "test.h", "")
	if !testing.expectf(t, err == "", "generate failed: %s", err, loc = loc) {
		return
	}
	for w in want {
		testing.expectf(t, strings.contains(out, w), "missing:\n%s\nin output:\n%s", w, out, loc = loc)
	}
}

@(private = "file")
expect_error :: proc(t: ^testing.T, src: string, want: string, loc := #caller_location) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	_, err := generate(src, "test.h", "")
	testing.expectf(t, strings.contains(err, want), "want error containing '%s', got '%s'", want, err, loc = loc)
}

@(test)
test_lexer :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tokens := lex("// comment\n#define A \\\n  1\nint /* x */ b = 0x1F; /*.field=*/ 2.f")
	kinds := [?]Token_Kind{.Directive, .Ident, .Ident, .Punct, .Number, .Punct, .Designator, .Number, .EOF}
	texts := [?]string{"#define A \\\n  1", "int", "b", "=", "0x1F", ";", "field", "2.f", ""}
	if !testing.expect_value(t, len(tokens), len(kinds)) {
		return
	}
	for tok, i in tokens {
		testing.expect_value(t, tok.kind, kinds[i])
		testing.expect_value(t, tok.text, texts[i])
	}
	testing.expect_value(t, tokens[1].line, 4)
}

@(test)
test_constants :: proc(t: ^testing.T) {
	expect_output(t, `
#define WGPU_TRUE (UINT32_C(1))
#define WGPU_WHOLE_SIZE (UINT64_MAX)
#define WGPU_LIMIT_U32_UNDEFINED (UINT32_MAX)
#define WGPU_WHOLE_MAP_SIZE (SIZE_MAX)
#define WGPU_DEPTH_CLEAR_VALUE_UNDEFINED (NAN)
#define WGPU_STRLEN (SIZE_MAX)
#define WGPU_NULLABLE
`,
		"WHOLE_SIZE :: max(u64)\n",
		"LIMIT_U32_UNDEFINED :: max(u32)\n",
		"WHOLE_MAP_SIZE :: max(uint)\n",
		"DEPTH_CLEAR_VALUE_UNDEFINED :: f32(0h7FC0_0000)\n",
		"STRLEN :: transmute(int)(max(uint))\n",
	)
}

@(test)
test_aliases_and_handles :: proc(t: ^testing.T) {
	expect_output(t, PRELUDE + `
typedef struct WGPUAdapterImpl* WGPUAdapter WGPU_OBJECT_ATTRIBUTE;
`,
		"Flags :: u64\n",
		"Bool :: b32\n",
		"StringView :: string\n",
		"Adapter :: distinct rawptr\n",
	)
}

@(test)
test_enum :: proc(t: ^testing.T) {
	expect_output(t, `
typedef enum WGPUTextureDimension {
    WGPUTextureDimension_Undefined = 0x00000000,
    WGPUTextureDimension_2D = 0x00000002,
    WGPUTextureDimension_Force32 = 0x7FFFFFFF
} WGPUTextureDimension WGPU_ENUM_ATTRIBUTE;
`,
		"TextureDimension :: enum i32 {\n\tUndefined = 0x00000000,\n\t_2D = 0x00000002,\n}\n",
	)
}

@(test)
test_bitflags :: proc(t: ^testing.T) {
	expect_output(t, PRELUDE + `
typedef WGPUFlags WGPUColorWriteMask;
static const WGPUColorWriteMask WGPUColorWriteMask_None = 0x0000000000000000;
static const WGPUColorWriteMask WGPUColorWriteMask_Red = 0x0000000000000001;
static const WGPUColorWriteMask WGPUColorWriteMask_Blue = 0x0000000000000004;
static const WGPUColorWriteMask WGPUColorWriteMask_All = 0x0000000000000005;
`,
		"ColorWriteMask :: enum i32 {\n\tRed = 0,\n\tBlue = 2,\n}\n",
		"ColorWriteMaskFlags :: bit_set[ColorWriteMask; Flags]\n",
		"ColorWriteMaskFlags_All :: ColorWriteMaskFlags{.Red, .Blue}\n",
	)
}

@(test)
test_struct :: proc(t: ^testing.T) {
	expect_output(t, PRELUDE + `
typedef struct WGPUTextureViewImpl* WGPUTextureView WGPU_OBJECT_ATTRIBUTE;
typedef WGPUFlags WGPUBufferUsage;
static const WGPUBufferUsage WGPUBufferUsage_MapRead = 0x0000000000000001;
typedef struct WGPUColorAttachment {
    WGPUChainedStruct * nextInChain;
    WGPU_NULLABLE WGPUTextureView view;
    WGPUBufferUsage usage;
    WGPUBool enabled;
    WGPUStringView label;
    size_t formatCount;
    WGPUTextureView const * formats;
    size_t toggleCount;
    const char* const * toggles;
    void const * data;
    char const * name;
} WGPUColorAttachment WGPU_STRUCTURE_ATTRIBUTE;
typedef struct WGPUExtension {
    WGPUChainedStruct chain;
    uint32_t context;
} WGPUExtension WGPU_STRUCTURE_ATTRIBUTE;
`,
		`ColorAttachment :: struct {
	nextInChain: ^ChainedStruct,
	/* NULLABLE */ view: TextureView,
	usage: BufferUsageFlags,
	enabled: Bool,
	label: StringView,
	formatCount: uint,
	formats: [^]TextureView,
	toggleCount: uint,
	toggles: [^]cstring,
	data: rawptr,
	name: cstring,
}
`,
		"Extension :: struct {\n\tusing chain: ChainedStruct,\n\tcontext_: u32,\n}\n",
	)
}

@(test)
test_callback :: proc(t: ^testing.T) {
	expect_output(t, `
typedef void (*WGPUProc)(void) WGPU_FUNCTION_ATTRIBUTE;
typedef size_t (*WGPULoadCallback)(size_t keySize, uint8_t const * key, WGPU_NULLABLE void* userdata1) WGPU_FUNCTION_ATTRIBUTE;
`,
		"Proc :: #type proc \"c\" ()\n",
		"LoadCallback :: #type proc \"c\" (keySize: uint, key: [^]u8, /* NULLABLE */ userdata1: rawptr) -> uint\n",
	)
}

@(test)
test_functions :: proc(t: ^testing.T) {
	expect_output(t, `
typedef struct WGPUQueueImpl* WGPUQueue WGPU_OBJECT_ATTRIBUTE;
typedef struct WGPUCommandBufferImpl* WGPUCommandBuffer WGPU_OBJECT_ATTRIBUTE;
typedef struct WGPUFenceInfo { uint32_t unused; } WGPUFenceInfo WGPU_STRUCTURE_ATTRIBUTE;
#if !defined(WGPU_SKIP_PROCS)
typedef void (*WGPUProcQueueSubmit)(WGPUQueue queue) WGPU_FUNCTION_ATTRIBUTE;
#endif
#if !defined(WGPU_SKIP_DECLARATIONS)
WGPU_EXPORT void wgpuQueueSubmit(WGPUQueue queue, size_t commandCount, WGPUCommandBuffer const * commands) WGPU_FUNCTION_ATTRIBUTE;
WGPU_EXPORT WGPUQueue wgpuCreateQueue(WGPU_NULLABLE WGPUFenceInfo const * info) WGPU_FUNCTION_ATTRIBUTE;
WGPU_EXPORT void wgpuFenceInfo(WGPUQueue queue) WGPU_FUNCTION_ATTRIBUTE;
WGPU_EXPORT void wgpuQueueWrite(WGPUQueue queue, size_t dataSize, WGPUFenceInfo const * dataLayout, size_t codeSize, uint32_t const * code) WGPU_FUNCTION_ATTRIBUTE;
#endif
`,
		"foreign import lib {",
		// Wrapped in wgpu.odin.
		"\t@(link_name = \"wgpuQueueSubmit\")\n\tRawQueueSubmit :: proc(queue: Queue, commandCount: uint, commands: [^]CommandBuffer) ---\n",
		"\tCreateQueue :: proc(/* NULLABLE */ info: ^FenceInfo = nil) -> Queue ---\n",
		"\tQueueWrite :: proc(queue: Queue, dataSize: uint, dataLayout: ^FenceInfo, codeSize: uint, code: [^]u32) ---\n",
		"\t@(link_name = \"wgpuFenceInfo\")\n\tFenceInfo_ :: proc(queue: Queue) ---\n",
	)
	// The proc typedefs of WGPU_SKIP_PROCS are not bindings.
	expect_error(t, "#if !defined(WGPU_SKIP_PROCS)\ngarbage\n#endif\nmore garbage", "line 4")
}

@(test)
test_init_macros :: proc(t: ^testing.T) {
	expect_output(t, PRELUDE + `
#define WGPU_DEPTH_SLICE_UNDEFINED (UINT32_MAX)
typedef enum WGPULoadOp {
    WGPULoadOp_Undefined = 0x00000000,
    WGPULoadOp_Clear = 0x00000002,
} WGPULoadOp WGPU_ENUM_ATTRIBUTE;
typedef struct WGPUColor { double r; } WGPUColor WGPU_STRUCTURE_ATTRIBUTE;
#define WGPU_COLOR_INIT _wgpu_MAKE_INIT_STRUCT(WGPUColor, { \
    /*.r=*/0. _wgpu_COMMA \
})
typedef struct WGPUAttachment {
    WGPUChainedStruct * nextInChain;
    WGPUStringView label;
    uint32_t depthSlice;
    WGPULoadOp loadOp;
    WGPULoadOp storeOp;
    float lodMaxClamp;
    WGPUBool enabled;
    WGPUColor clearValue;
} WGPUAttachment WGPU_STRUCTURE_ATTRIBUTE;
#define WGPU_ATTACHMENT_INIT _wgpu_MAKE_INIT_STRUCT(WGPUAttachment, { \
    /*.nextInChain=*/NULL _wgpu_COMMA \
    /*.label=*/WGPU_STRING_VIEW_INIT _wgpu_COMMA \
    /*.depthSlice=*/WGPU_DEPTH_SLICE_UNDEFINED _wgpu_COMMA \
    /*.loadOp=*/WGPULoadOp_Undefined _wgpu_COMMA \
    /*.storeOp=*/WGPULoadOp_Clear _wgpu_COMMA \
    /*.lodMaxClamp=*/32.f _wgpu_COMMA \
    /*.enabled=*/WGPU_TRUE _wgpu_COMMA \
    /*.clearValue=*/WGPU_COLOR_INIT _wgpu_COMMA \
})
typedef struct WGPUShaderSourceWGSL {
    WGPUChainedStruct chain;
    WGPUStringView code;
} WGPUShaderSourceWGSL WGPU_STRUCTURE_ATTRIBUTE;
#define WGPU_SHADER_SOURCE_WGSL_INIT _wgpu_MAKE_INIT_STRUCT(WGPUShaderSourceWGSL, { \
    /*.chain=*/_wgpu_MAKE_INIT_STRUCT(WGPUChainedStruct, { \
        /*.next=*/NULL _wgpu_COMMA \
        /*.sType=*/WGPUSType_ShaderSourceWGSL _wgpu_COMMA \
    }) _wgpu_COMMA \
    /*.code=*/WGPU_STRING_VIEW_INIT _wgpu_COMMA \
})
`,
		"COLOR_INIT :: Color{}\n",
		"ATTACHMENT_INIT :: Attachment{depthSlice = DEPTH_SLICE_UNDEFINED, storeOp = .Clear, lodMaxClamp = 32.0, enabled = true, clearValue = COLOR_INIT}\n",
		"SHADER_SOURCE_WGSL_INIT :: ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}}\n",
	)
}

@(test)
test_errors :: proc(t: ^testing.T) {
	expect_error(t, "typedef struct WGPUFoo { WGPUUnknown x; } WGPUFoo;", "unknown C type 'WGPUUnknown'")
	expect_error(t, "int x;", "unknown declaration")
	expect_error(t, "typedef enum WGPUFoo { WGPUBar_A = 0x1 } WGPUFoo;", "prefix")
	expect_error(t, "static const WGPUFoo WGPUFoo_A = 0x1;", "unknown flag type")
}

@(test)
test_dawn_version :: proc(t: ^testing.T) {
	src := "#define DAWN_MAJOR_VERSION 1\n#define DAWN_MINOR_VERSION 2026101200\n"
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	testing.expect_value(t, parse_dawn_version(src), "1.2026101200")
}

// The committed bindings must match what the generator produces from the committed header.
@(test)
test_generated_is_up_to_date :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	header, err1 := os.read_entire_file(HEADER_PATH, context.allocator)
	version, err2 := os.read_entire_file(VERSION_PATH, context.allocator)
	generated, err3 := os.read_entire_file(GENERATED_PATH, context.allocator)
	if !testing.expect(t, err1 == nil && err2 == nil && err3 == nil, "cannot read the header or the generated file") {
		return
	}
	out, err := generate(string(header), "dawn/include/dawn/webgpu.h", parse_dawn_version(string(version)))
	if !testing.expectf(t, err == "", "generate failed: %s", err) {
		return
	}
	testing.expect(t, out == string(generated), "wgpu/wgpu_generated.odin is stale: run tools/update_dawn.sh or tools/gen")
}
