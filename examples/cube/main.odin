// A rotating cube with a checkerboard texture, tinted with one color per face. Space pauses, Esc quits.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "vendor:glfw"
import "../app"
import wgpu "../../webgpu"

SHADER :: `
struct Uniforms {
    mvp: mat4x4f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var checker: texture_2d<f32>;
@group(0) @binding(2) var checker_sampler: sampler;

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) tint: vec3f,
}

@vertex
fn vs_main(@location(0) position: vec3f, @location(1) uv: vec2f, @location(2) tint: vec3f) -> VertexOut {
    var out: VertexOut;
    out.position = u.mvp * vec4f(position, 1.0);
    out.uv = uv;
    out.tint = tint;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return vec4f(textureSample(checker, checker_sampler, in.uv).rgb * in.tint, 1.0);
}
`

Vertex :: struct {
	position: [3]f32,
	uv:       [2]f32,
	tint:     [3]f32,
}

DEPTH_FORMAT :: wgpu.TextureFormat.Depth24Plus
TEXTURE_SIZE :: 64
CHECKER_CELLS :: 8

// Each face: normal, then the u and v axes in texture space. u × v = normal, so faces wind counter-clockwise.
FACES := [6][3][3]f32{
	{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
	{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
	{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
	{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
	{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
	{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
}

FACE_TINTS := [6][3]f32{
	{1.0, 0.3, 0.3},
	{0.3, 1.0, 0.3},
	{0.3, 0.5, 1.0},
	{1.0, 0.9, 0.3},
	{1.0, 0.4, 1.0},
	{0.3, 1.0, 1.0},
}

cube_mesh :: proc() -> (vertices: [24]Vertex, indices: [36]u16) {
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for face, f in FACES {
		n, u, v := face[0], face[1], face[2]
		for c, i in corners {
			vertices[f * 4 + i] = {
				position = n + c.x * u + c.y * v,
				uv       = {(c.x + 1) / 2, (1 - c.y) / 2},
				tint     = FACE_TINTS[f],
			}
		}
		base := u16(f * 4)
		for index, i in ([6]u16{0, 1, 2, 0, 2, 3}) {
			indices[f * 6 + i] = base + index
		}
	}
	return
}

checkerboard :: proc() -> (pixels: [TEXTURE_SIZE * TEXTURE_SIZE][4]u8) {
	cell :: TEXTURE_SIZE / CHECKER_CELLS
	for y in 0 ..< TEXTURE_SIZE {
		for x in 0 ..< TEXTURE_SIZE {
			light := (x / cell + y / cell) % 2 == 0
			pixels[y * TEXTURE_SIZE + x] = {255, 255, 255, 255} if light else {70, 70, 70, 255}
		}
	}
	return
}

// Right-handed perspective projection with WebGPU's 0..1 depth range.
perspective :: proc(fovy, aspect, near, far: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(fovy / 2)
	return {
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, far / (near - far), near * far / (near - far),
		0, 0, -1, 0,
	}
}

create_depth_view :: proc(a: ^app.App) -> (wgpu.Texture, wgpu.TextureView) {
	desc := wgpu.TEXTURE_DESCRIPTOR_INIT
	desc.label = "depth"
	desc.usage = {.RenderAttachment}
	desc.dimension = ._2D
	desc.size = {a.width, a.height, 1}
	desc.format = DEPTH_FORMAT
	texture := wgpu.DeviceCreateTexture(a.device, &desc)
	return texture, wgpu.TextureCreateView(texture)
}

main :: proc() {
	a: app.App
	if !app.init(&a, "dawn_webgpu_odin: cube", 800, 600) {
		os.exit(1)
	}
	defer app.shutdown(&a)

	// Geometry
	vertices, indices := cube_mesh()
	vertex_buffer := wgpu.DeviceCreateBuffer(a.device, &{label = "cube vertices", usage = {.Vertex, .CopyDst}, size = size_of(vertices)})
	defer wgpu.BufferRelease(vertex_buffer)
	wgpu.QueueWriteBuffer(a.queue, vertex_buffer, 0, &vertices, size_of(vertices))
	index_buffer := wgpu.DeviceCreateBuffer(a.device, &{label = "cube indices", usage = {.Index, .CopyDst}, size = size_of(indices)})
	defer wgpu.BufferRelease(index_buffer)
	wgpu.QueueWriteBuffer(a.queue, index_buffer, 0, &indices, size_of(indices))

	uniform_buffer := wgpu.DeviceCreateBuffer(a.device, &{label = "uniforms", usage = {.Uniform, .CopyDst}, size = size_of(matrix[4, 4]f32)})
	defer wgpu.BufferRelease(uniform_buffer)

	// Checkerboard texture
	texture_desc := wgpu.TEXTURE_DESCRIPTOR_INIT
	texture_desc.label = "checkerboard"
	texture_desc.usage = {.TextureBinding, .CopyDst}
	texture_desc.dimension = ._2D
	texture_desc.size = {TEXTURE_SIZE, TEXTURE_SIZE, 1}
	texture_desc.format = .RGBA8Unorm
	texture := wgpu.DeviceCreateTexture(a.device, &texture_desc)
	defer wgpu.TextureRelease(texture)
	pixels := checkerboard()
	destination := wgpu.TEXEL_COPY_TEXTURE_INFO_INIT
	destination.texture = texture
	data_layout := wgpu.TexelCopyBufferLayout{bytesPerRow = TEXTURE_SIZE * 4, rowsPerImage = TEXTURE_SIZE}
	wgpu.QueueWriteTexture(a.queue, &destination, &pixels, size_of(pixels), &data_layout, &{TEXTURE_SIZE, TEXTURE_SIZE, 1})
	texture_view := wgpu.TextureCreateView(texture)
	defer wgpu.TextureViewRelease(texture_view)

	sampler_desc := wgpu.SAMPLER_DESCRIPTOR_INIT
	sampler_desc.magFilter = .Nearest
	sampler_desc.minFilter = .Linear
	sampler := wgpu.DeviceCreateSampler(a.device, &sampler_desc)
	defer wgpu.SamplerRelease(sampler)

	// Pipeline
	module := app.shader_module(a.device, "cube shader", SHADER)
	defer wgpu.ShaderModuleRelease(module)

	attributes := [?]wgpu.VertexAttribute{
		{format = .Float32x3, offset = u64(offset_of(Vertex, position)), shaderLocation = 0},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 1},
		{format = .Float32x3, offset = u64(offset_of(Vertex, tint)), shaderLocation = 2},
	}
	buffers := [?]wgpu.VertexBufferLayout{{
		stepMode = .Vertex,
		arrayStride = size_of(Vertex),
		attributeCount = len(attributes),
		attributes = &attributes[0],
	}}
	targets := [?]wgpu.ColorTargetState{wgpu.COLOR_TARGET_STATE_INIT}
	targets[0].format = a.format
	fragment := wgpu.FRAGMENT_STATE_INIT
	fragment.module = module
	fragment.entryPoint = "fs_main"
	fragment.targetCount = len(targets)
	fragment.targets = &targets[0]
	depth_stencil := wgpu.DEPTH_STENCIL_STATE_INIT
	depth_stencil.format = DEPTH_FORMAT
	depth_stencil.depthWriteEnabled = .True
	depth_stencil.depthCompare = .Less

	pipeline_desc := wgpu.RENDER_PIPELINE_DESCRIPTOR_INIT
	pipeline_desc.label = "cube pipeline"
	pipeline_desc.vertex.module = module
	pipeline_desc.vertex.entryPoint = "vs_main"
	pipeline_desc.vertex.bufferCount = len(buffers)
	pipeline_desc.vertex.buffers = &buffers[0]
	pipeline_desc.primitive.topology = .TriangleList
	pipeline_desc.primitive.frontFace = .CCW
	pipeline_desc.primitive.cullMode = .Back
	pipeline_desc.depthStencil = &depth_stencil
	pipeline_desc.fragment = &fragment
	pipeline := wgpu.DeviceCreateRenderPipeline(a.device, &pipeline_desc)
	defer wgpu.RenderPipelineRelease(pipeline)

	layout := wgpu.RenderPipelineGetBindGroupLayout(pipeline, 0)
	defer wgpu.BindGroupLayoutRelease(layout)
	entries := [?]wgpu.BindGroupEntry{
		{binding = 0, buffer = uniform_buffer, size = wgpu.WHOLE_SIZE},
		{binding = 1, textureView = texture_view},
		{binding = 2, sampler = sampler},
	}
	bind_group := wgpu.DeviceCreateBindGroup(a.device, &{layout = layout, entryCount = len(entries), entries = &entries[0]})
	defer wgpu.BindGroupRelease(bind_group)

	depth_texture, depth_view := create_depth_view(&a)
	defer {
		wgpu.TextureViewRelease(depth_view)
		wgpu.TextureRelease(depth_texture)
	}
	a.resized = false

	paused := false
	space_was_down := false
	angle: f32
	last := glfw.GetTime()
	frames := 0

	for app.poll(&a) {
		now := glfw.GetTime()
		space_down := glfw.GetKey(a.window, glfw.KEY_SPACE) == glfw.PRESS
		if space_down && !space_was_down {
			paused = !paused
		}
		space_was_down = space_down
		if !paused {
			angle += f32(now - last)
		}
		last = now

		frame_texture, ok := app.acquire(&a)
		if !ok {
			continue
		}
		if a.resized {
			wgpu.TextureViewRelease(depth_view)
			wgpu.TextureRelease(depth_texture)
			depth_texture, depth_view = create_depth_view(&a)
			a.resized = false
		}

		projection := perspective(math.to_radians(f32(60)), f32(a.width) / f32(a.height), 0.1, 100)
		view_matrix := linalg.matrix4_translate_f32({0, 0, -5})
		model := linalg.matrix4_rotate_f32(angle, linalg.normalize([3]f32{1, 1, 0.3}))
		mvp := projection * view_matrix * model
		wgpu.QueueWriteBuffer(a.queue, uniform_buffer, 0, &mvp, size_of(mvp))

		view := wgpu.TextureCreateView(frame_texture)
		encoder := wgpu.DeviceCreateCommandEncoder(a.device)

		color := wgpu.RENDER_PASS_COLOR_ATTACHMENT_INIT
		color.view = view
		color.loadOp = .Clear
		color.storeOp = .Store
		color.clearValue = {0.05, 0.05, 0.08, 1}
		depth := wgpu.RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT
		depth.view = depth_view
		depth.depthLoadOp = .Clear
		depth.depthStoreOp = .Discard
		depth.depthClearValue = 1
		pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
			colorAttachmentCount = 1,
			colorAttachments = &color,
			depthStencilAttachment = &depth,
		})
		wgpu.RenderPassEncoderSetPipeline(pass, pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, nil)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, vertex_buffer, 0, size_of(vertices))
		wgpu.RenderPassEncoderSetIndexBuffer(pass, index_buffer, .Uint16, 0, size_of(indices))
		wgpu.RenderPassEncoderDrawIndexed(pass, len(indices), 1, 0, 0, 0)
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)

		commands := wgpu.CommandEncoderFinish(encoder)
		wgpu.QueueSubmit(a.queue, 1, &commands)
		wgpu.SurfacePresent(a.surface)

		wgpu.CommandBufferRelease(commands)
		wgpu.CommandEncoderRelease(encoder)
		wgpu.TextureViewRelease(view)
		wgpu.TextureRelease(frame_texture)

		frames += 1
	}
	fmt.println("frames:", frames)
}
