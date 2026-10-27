// Creates a WebGPU surface for a GLFW window, on Wayland or X11.
package wgpu_glfw_glue

import "vendor:glfw"
import wgpu ".."

GetSurface :: proc(instance: wgpu.Instance, window: glfw.WindowHandle) -> wgpu.Surface {
	switch glfw.GetPlatform() {
	case glfw.PLATFORM_WAYLAND:
		source := wgpu.SurfaceSourceWaylandSurface {
			chain = {sType = .SurfaceSourceWaylandSurface},
			display = glfw.GetWaylandDisplay(),
			surface = glfw.GetWaylandWindow(window),
		}
		return wgpu.InstanceCreateSurface(instance, &wgpu.SurfaceDescriptor{nextInChain = &source})
	case glfw.PLATFORM_X11:
		source := wgpu.SurfaceSourceXlibWindow {
			chain = {sType = .SurfaceSourceXlibWindow},
			display = glfw.GetX11Display(),
			window = u64(glfw.GetX11Window(window)),
		}
		return wgpu.InstanceCreateSurface(instance, &wgpu.SurfaceDescriptor{nextInChain = &source})
	}
	panic("webgpu glfw glue: unsupported platform, expected Wayland or X11")
}
