// Window, device and surface setup shared by the examples.
package app

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "vendor:glfw"
import glue "../../glfwglue"
import wgpu "../../webgpu"

App :: struct {
	window:   glfw.WindowHandle,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	format:   wgpu.TextureFormat,
	width:    u32,
	height:   u32,
	// Set when the surface size changed since the last frame.
	resized:  bool,
	// From `--seconds=N`: close the window after N seconds, 0 to run until closed.
	seconds:  f64,
}

// Opens a window and creates a Dawn device that renders to it.
init :: proc(app: ^App, title: cstring, width, height: i32) -> bool {
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--seconds=") {
			app.seconds, _ = strconv.parse_f64(arg[len("--seconds="):])
		}
		if arg == "--x11" {
			glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11)
		}
	}
	if !glfw.Init() {
		fmt.eprintln("glfw.Init failed")
		return false
	}
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	app.window = glfw.CreateWindow(width, height, title, nil, nil)
	if app.window == nil {
		fmt.eprintln("glfw.CreateWindow failed")
		return false
	}

	// TimedWaitAny lets InstanceWaitAny block until a future completes.
	features := [?]wgpu.InstanceFeatureName{.TimedWaitAny}
	app.instance = wgpu.CreateInstance(&{requiredFeatureCount = len(features), requiredFeatures = &features[0]})
	if app.instance == nil {
		fmt.eprintln("wgpu.CreateInstance failed")
		return false
	}
	app.surface = glue.GetSurface(app.instance, app.window)

	adapter_options := wgpu.REQUEST_ADAPTER_OPTIONS_INIT
	adapter_options.compatibleSurface = app.surface
	adapter_options.powerPreference = .HighPerformance
	future := wgpu.InstanceRequestAdapter(app.instance, &adapter_options, {
		mode = .WaitAnyOnly,
		callback = on_adapter,
		userdata1 = &app.adapter,
	})
	if !wait(app, future) || app.adapter == nil {
		return false
	}
	print_adapter(app.adapter)

	device_desc := wgpu.DEVICE_DESCRIPTOR_INIT
	device_desc.label = "example device"
	device_desc.deviceLostCallbackInfo = {mode = .AllowSpontaneous, callback = on_device_lost}
	device_desc.uncapturedErrorCallbackInfo = {callback = on_uncaptured_error}
	future = wgpu.AdapterRequestDevice(app.adapter, &device_desc, {
		mode = .WaitAnyOnly,
		callback = on_device,
		userdata1 = &app.device,
	})
	if !wait(app, future) || app.device == nil {
		return false
	}
	app.queue = wgpu.DeviceGetQueue(app.device)

	caps: wgpu.SurfaceCapabilities
	if wgpu.SurfaceGetCapabilities(app.surface, app.adapter, &caps) != .Success || caps.formatCount == 0 {
		fmt.eprintln("wgpu.SurfaceGetCapabilities failed")
		return false
	}
	app.format = caps.formats[0]
	wgpu.SurfaceCapabilitiesFreeMembers(caps)
	fmt.println("surface format:", app.format)

	configure_surface(app)
	return true
}

shutdown :: proc(app: ^App) {
	wgpu.QueueRelease(app.queue)
	wgpu.DeviceRelease(app.device)
	wgpu.AdapterRelease(app.adapter)
	wgpu.SurfaceRelease(app.surface)
	wgpu.InstanceRelease(app.instance)
	glfw.DestroyWindow(app.window)
	glfw.Terminate()
}

// Polls window events. Returns false when the window should close (close button or Esc).
poll :: proc(app: ^App) -> bool {
	glfw.PollEvents()
	wgpu.InstanceProcessEvents(app.instance)
	if glfw.WindowShouldClose(app.window) || glfw.GetKey(app.window, glfw.KEY_ESCAPE) == glfw.PRESS {
		return false
	}
	if app.seconds > 0 && glfw.GetTime() >= app.seconds {
		return false
	}
	w, h := glfw.GetFramebufferSize(app.window)
	if (u32(w) != app.width || u32(h) != app.height) && w > 0 && h > 0 {
		configure_surface(app)
	}
	return true
}

configure_surface :: proc(app: ^App) {
	w, h := glfw.GetFramebufferSize(app.window)
	app.width, app.height = u32(max(w, 1)), u32(max(h, 1))
	config := wgpu.SURFACE_CONFIGURATION_INIT
	config.device = app.device
	config.format = app.format
	config.width = app.width
	config.height = app.height
	config.presentMode = .Fifo
	config.alphaMode = .Auto
	wgpu.SurfaceConfigure(app.surface, &config)
	app.resized = true
}

// Returns the texture to render the next frame to, or false when this frame must be skipped.
acquire :: proc(app: ^App) -> (wgpu.Texture, bool) {
	st: wgpu.SurfaceTexture
	wgpu.SurfaceGetCurrentTexture(app.surface, &st)
	switch st.status {
	case .SuccessOptimal, .SuccessSuboptimal:
		return st.texture, true
	case .Outdated, .Lost:
		if st.texture != nil {
			wgpu.TextureRelease(st.texture)
		}
		configure_surface(app)
	case .Timeout:
	case .Error:
		fmt.panicf("wgpu.SurfaceGetCurrentTexture failed: %v", st.status)
	}
	return nil, false
}

// Builds a shader module from WGSL source.
shader_module :: proc(device: wgpu.Device, label: string, code: string) -> wgpu.ShaderModule {
	wgsl := wgpu.SHADER_SOURCE_WGSL_INIT
	wgsl.code = code
	return wgpu.DeviceCreateShaderModule(device, &{nextInChain = &wgsl, label = label})
}

@(private = "file")
wait :: proc(app: ^App, future: wgpu.Future) -> bool {
	info := wgpu.FutureWaitInfo{future = future}
	status := wgpu.InstanceWaitAny(app.instance, 1, &info, max(u64))
	if status != .Success {
		fmt.eprintln("wgpu.InstanceWaitAny failed:", status)
		return false
	}
	return true
}

@(private = "file")
print_adapter :: proc(adapter: wgpu.Adapter) {
	info: wgpu.AdapterInfo
	if wgpu.AdapterGetInfo(adapter, &info) == .Success {
		fmt.printfln("adapter: %s (%v, %v)", wgpu.string_from_view(info.description), info.backendType, info.adapterType)
		wgpu.AdapterInfoFreeMembers(info)
	}
}

@(private = "file")
on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = runtime.default_context()
	if status != .Success {
		fmt.eprintfln("request adapter failed: %v: %s", status, wgpu.string_from_view(message))
		return
	}
	(^wgpu.Adapter)(userdata1)^ = adapter
}

@(private = "file")
on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = runtime.default_context()
	if status != .Success {
		fmt.eprintfln("request device failed: %v: %s", status, wgpu.string_from_view(message))
		return
	}
	(^wgpu.Device)(userdata1)^ = device
}

@(private = "file")
on_device_lost :: proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = runtime.default_context()
	if reason != .Destroyed && reason != .CallbackCancelled {
		fmt.eprintfln("device lost: %v: %s", reason, wgpu.string_from_view(message))
	}
}

@(private = "file")
on_uncaptured_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = runtime.default_context()
	fmt.eprintfln("webgpu error: %v: %s", type, wgpu.string_from_view(message))
}
