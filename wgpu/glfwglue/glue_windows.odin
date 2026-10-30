// Creates a WebGPU surface for a GLFW window, from its HWND.
package wgpu_glfw_glue

import win "core:sys/windows"
import "vendor:glfw"
import wgpu ".."

GetSurface :: proc(instance: wgpu.Instance, window: glfw.WindowHandle) -> wgpu.Surface {
	source := wgpu.SurfaceSourceWindowsHWND {
		chain = {sType = .SurfaceSourceWindowsHWND},
		hinstance = rawptr(win.GetModuleHandleW(nil)),
		hwnd = rawptr(glfw.GetWin32Window(window)),
	}
	return wgpu.InstanceCreateSurface(instance, &wgpu.SurfaceDescriptor{nextInChain = &source})
}
