// Generates Odin bindings from Dawn's webgpu.h.
//
// Usage: odin run tools/gen -- <webgpu.h> <output.odin> [dawn_version.h]
package main

import vmem "core:mem/virtual"
import "core:fmt"
import "core:os"

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	if len(os.args) < 3 {
		fmt.eprintln("usage: gen <webgpu.h> <output.odin> [dawn_version.h]")
		os.exit(2)
	}
	header_path, out_path := os.args[1], os.args[2]

	header, read_err := os.read_entire_file(header_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("gen: cannot read %s: %v", header_path, read_err)
		os.exit(1)
	}
	version := ""
	if len(os.args) > 3 {
		version_src, version_err := os.read_entire_file(os.args[3], context.allocator)
		if version_err != nil {
			fmt.eprintfln("gen: cannot read %s: %v", os.args[3], version_err)
			os.exit(1)
		}
		version = parse_dawn_version(string(version_src))
	}

	out, err := generate(string(header), header_path, version)
	if err != "" {
		fmt.eprintfln("gen: %s: %s", header_path, err)
		os.exit(1)
	}
	if write_err := os.write_entire_file(out_path, transmute([]u8)out); write_err != nil {
		fmt.eprintfln("gen: cannot write %s: %v", out_path, write_err)
		os.exit(1)
	}
}
