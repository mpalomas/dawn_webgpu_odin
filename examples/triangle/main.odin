// A rotating triangle whose colors cycle over time. Space pauses, Esc quits.
package main

import "core:os"
import "vendor:glfw"
import "../shared"
import wgpu "../../webgpu"

SHADER :: `
struct Uniforms {
    time: f32,
    aspect: f32,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VertexOut {
    let corners = array(vec2f(0.0, 0.7), vec2f(-0.6, -0.4), vec2f(0.6, -0.4));
    let p = corners[i];
    let s = sin(u.time);
    let c = cos(u.time);
    var out: VertexOut;
    out.position = vec4f((p.x * c - p.y * s) / u.aspect, p.x * s + p.y * c, 0.0, 1.0);
    let phase = u.time * 0.7 + f32(i) / 3.0;
    out.color = 0.5 + 0.5 * cos(6.2831 * (phase + vec3f(0.0, 0.33, 0.67)));
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
}
`

Uniforms :: struct {
	time:   f32,
	aspect: f32,
	_:      [2]f32,
}

main :: proc() {
	a: shared.App
	if !shared.init(&a, "dawn_webgpu_odin: triangle", 800, 600) {
		os.exit(1)
	}
	defer shared.shutdown(&a)

	module := shared.shader_module(a.device, "triangle shader", SHADER)
	defer wgpu.ShaderModuleRelease(module)

	targets := [?]wgpu.ColorTargetState{wgpu.COLOR_TARGET_STATE_INIT}
	targets[0].format = a.format
	fragment := wgpu.FRAGMENT_STATE_INIT
	fragment.module = module
	fragment.entryPoint = "fs_main"
	fragment.targetCount = len(targets)
	fragment.targets = &targets[0]

	pipeline_desc := wgpu.RENDER_PIPELINE_DESCRIPTOR_INIT
	pipeline_desc.label = "triangle pipeline"
	pipeline_desc.vertex.module = module
	pipeline_desc.vertex.entryPoint = "vs_main"
	pipeline_desc.primitive.topology = .TriangleList
	pipeline_desc.fragment = &fragment
	pipeline := wgpu.DeviceCreateRenderPipeline(a.device, &pipeline_desc)
	defer wgpu.RenderPipelineRelease(pipeline)

	uniform_buffer := wgpu.DeviceCreateBuffer(a.device, &{
		label = "uniforms",
		usage = {.Uniform, .CopyDst},
		size = size_of(Uniforms),
	})
	defer wgpu.BufferRelease(uniform_buffer)

	layout := wgpu.RenderPipelineGetBindGroupLayout(pipeline, 0)
	defer wgpu.BindGroupLayoutRelease(layout)
	entries := [?]wgpu.BindGroupEntry{{binding = 0, buffer = uniform_buffer, size = size_of(Uniforms)}}
	bind_group := wgpu.DeviceCreateBindGroup(a.device, &{
		layout = layout,
		entryCount = len(entries),
		entries = &entries[0],
	})
	defer wgpu.BindGroupRelease(bind_group)

	paused := false
	space_was_down := false
	time: f32
	last := glfw.GetTime()

	for shared.poll(&a) {
		now := glfw.GetTime()
		space_down := glfw.GetKey(a.window, glfw.KEY_SPACE) == glfw.PRESS
		if space_down && !space_was_down {
			paused = !paused
		}
		space_was_down = space_down
		if !paused {
			time += f32(now - last)
		}
		last = now

		texture, ok := shared.acquire(&a)
		if !ok {
			continue
		}
		uniforms := Uniforms{time = time, aspect = f32(a.width) / f32(a.height)}
		wgpu.QueueWriteBuffer(a.queue, uniform_buffer, 0, &uniforms, size_of(uniforms))

		view := wgpu.TextureCreateView(texture)
		encoder := wgpu.DeviceCreateCommandEncoder(a.device)

		color := wgpu.RENDER_PASS_COLOR_ATTACHMENT_INIT
		color.view = view
		color.loadOp = .Clear
		color.storeOp = .Store
		color.clearValue = {0.05, 0.05, 0.08, 1}
		pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
		wgpu.RenderPassEncoderSetPipeline(pass, pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, nil)
		wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)

		commands := wgpu.CommandEncoderFinish(encoder)
		wgpu.QueueSubmit(a.queue, 1, &commands)
		shared.present(&a)

		wgpu.CommandBufferRelease(commands)
		wgpu.CommandEncoderRelease(encoder)
		wgpu.TextureViewRelease(view)
		wgpu.TextureRelease(texture)
	}
}
