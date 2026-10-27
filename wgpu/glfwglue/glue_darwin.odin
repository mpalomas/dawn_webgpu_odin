// Creates a WebGPU surface for a GLFW window, backed by a CAMetalLayer.
package wgpu_glfw_glue

import "vendor:glfw"
import CA "vendor:darwin/QuartzCore"
import wgpu ".."

GetSurface :: proc(instance: wgpu.Instance, window: glfw.WindowHandle) -> wgpu.Surface {
	ns_window := glfw.GetCocoaWindow(window)
	view := ns_window->contentView()
	view->setWantsLayer(true)
	layer := CA.MetalLayer.layer()
	view->setLayer(layer)
	source := wgpu.SurfaceSourceMetalLayer {
		chain = {sType = .SurfaceSourceMetalLayer},
		layer = rawptr(layer),
	}
	return wgpu.InstanceCreateSurface(instance, &wgpu.SurfaceDescriptor{nextInChain = &source})
}
