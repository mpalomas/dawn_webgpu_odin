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
	stats:    Frame_Stats,
}

// Frame timing, measured between presents and printed once per second.
Frame_Stats :: struct {
	total_frames:   int,
	first_present:  f64,
	last_present:   f64,
	// The current one-second window.
	window_start:   f64,
	window_frames:  int,
	window_min:     f64,
	window_max:     f64,
}

STATS_INTERVAL :: 1.0

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
	s := &app.stats
	if s.total_frames > 1 {
		elapsed := s.last_present - s.first_present
		fmt.printfln("%d frames in %.2f s, average %.2f fps", s.total_frames, elapsed, f64(s.total_frames - 1) / elapsed)
	}
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

// Presents the frame acquired with `acquire`, and prints the frame rate once per second.
present :: proc(app: ^App) {
	wgpu.SurfacePresent(app.surface)

	s := &app.stats
	now := glfw.GetTime()
	if s.total_frames == 0 {
		s.first_present = now
		s.window_start = now
	} else {
		dt := now - s.last_present
		if s.window_frames == 0 {
			s.window_min, s.window_max = dt, dt
		}
		s.window_min = min(s.window_min, dt)
		s.window_max = max(s.window_max, dt)
		s.window_frames += 1
	}
	s.last_present = now
	s.total_frames += 1

	elapsed := now - s.window_start
	if elapsed >= STATS_INTERVAL && s.window_frames > 0 {
		fmt.printfln("fps: %.2f  frame: %.2f ms (min %.2f, max %.2f)",
			f64(s.window_frames) / elapsed, elapsed * 1000 / f64(s.window_frames), s.window_min * 1000, s.window_max * 1000)
		s.window_start = now
		s.window_frames = 0
	}
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
	// Dawn reports the Vulkan driver version through an extension struct.
	vk := wgpu.AdapterPropertiesVk{chain = {sType = .AdapterPropertiesVk}}
	has_vk := wgpu.AdapterHasFeature(adapter, .AdapterPropertiesVk)
	if has_vk {
		info.nextInChain = &vk
	}
	if wgpu.AdapterGetInfo(adapter, &info) != .Success {
		fmt.eprintln("wgpu.AdapterGetInfo failed")
		return
	}
	defer wgpu.AdapterInfoFreeMembers(info)

	fmt.println("adapter:")
	print_field("description", wgpu.string_from_view(info.description))
	print_field("device", fmt.tprintf("%s (0x%04x)", wgpu.string_from_view(info.device), info.deviceID))
	print_field("vendor", fmt.tprintf("%s (0x%04x)", wgpu.string_from_view(info.vendor), info.vendorID))
	print_field("architecture", wgpu.string_from_view(info.architecture))
	print_field("type", fmt.tprint(info.adapterType))
	print_field("backend", fmt.tprint(info.backendType))
	if has_vk {
		print_field("driver", vulkan_driver_version(vk.driverVersion, info.vendorID))
	}
}

@(private = "file")
print_field :: proc(name, value: string) {
	if value != "" {
		fmt.printfln("  %-13s %s", fmt.tprintf("%s:", name), value)
	}
}

// Vulkan driver versions are vendor-specific. NVIDIA packs 10.8.8.6 bits; Mesa and most others use
// VK_MAKE_VERSION's 10.10.12 bits.
@(private = "file")
vulkan_driver_version :: proc(v: u32, vendor_id: u32) -> string {
	if vendor_id == 0x10DE {
		return fmt.tprintf("%d.%d.%d.%d", v >> 22, (v >> 14) & 0xFF, (v >> 6) & 0xFF, v & 0x3F)
	}
	return fmt.tprintf("%d.%d.%d", v >> 22, (v >> 12) & 0x3FF, v & 0xFFF)
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
