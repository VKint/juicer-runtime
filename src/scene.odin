package main

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:sdl3"
import sdl_image "vendor:sdl3/image"

RawTexture :: struct {
	bytes:  []u8,
	width:  u32,
	height: u32,
	pitch:  u32, // bytes per row (may include padding)
}

RawSampler :: struct {
	minFilter: u8,
	magFilter: u8,
	wrapT:     u8,
	wrapS:     u8,
}

RawVertex :: struct {
	position: linalg.Vector3f32,
	uv:       linalg.Vector2f32,
	normal:   linalg.Vector3f32,
	tangent:  linalg.Vector4f32, // NEW
}

RawMesh :: struct {
	primitives: []RawPrimitive,
}

RawPrimitive :: struct {
	vertices:             []RawVertex,
	indices:              []u32,
	vertex_buffer:        ^sdl3.GPUBuffer,
	vertex_count:         u32,
	texture_index:        i32,
	sampler_index:        i32,
	normal_texture_index: i32, // NEW
	normal_sampler_index: i32, // NEW
}

LightType :: enum {
	INVALID,
	DIRECTIONAL,
	POINT,
	SPOT,
}

RawLight :: struct {
	type:        LightType,
	color:       [3]f32,
	intensity:   f32,
	range:       f32,
	use_shadows: u8,
}


GPUPrimitive :: struct {
	vertex_buffer:        ^sdl3.GPUBuffer,
	index_buffer:         ^sdl3.GPUBuffer,
	index_count:          u32,
	texture_index:        i32,
	normal_texture_index: i32, // NEW
	// Sampler indices are usually coupled with texture indices or fixed, 
	// but we store them in the RawPrimitive for the render loop to pick up.
	// Wait, we need to pass these to the renderer.
	// The renderer iterates `scene.meshes[i].primitives`.
	// `scene.meshes` is []RawMesh. 
	// So we need to ensure RawPrimitive has everything we need.
	// Ah, I see `GPUPrimitive` struct above. That's for the old code?
	// Actually `scene.meshes` is `[]RawMesh`.
	// Let's check `Scene` struct.
	// `meshes: []RawMesh`
	// Okay.
}

// I see `GPUPrimitive` definition on line 61 but it is NOT used in `Scene` struct (line 83 uses `RawMesh`).
// Wait, line 68 `GPUMesh` uses `GPUPrimitive`.
// But `Scene` uses `RawMesh`.
// It seems `GPUPrimitive` and `GPUMesh` are vestigial or I missed where they are used.
// Ah, `main.odin` defined `gpu_meshes: [dynamic]GPUMesh`.
// But `scene.odin` defines `Scene` using `RawMesh`.
// And `render` function takes `Scene`.
// So `RawMesh` is the one that matters.

Object :: struct {
	transform:   linalg.Matrix4f32,
	mesh_index:  i32,
	light_index: i32,
}

Scene :: struct {
	objects:  []Object,
	meshes:   []RawMesh,
	textures: []^sdl3.GPUTexture,
	samplers: []^sdl3.GPUSampler,
	lights:   []RawLight,
}

SceneHeader :: struct #packed {
	magic:         u32,
	version:       u32,
	object_count:  u32,
	stride:        u32,
	mesh_count:    u32,
	light_count:   u32,
	texture_count: u32,
	sampler_count: u32,
}

PackedObject :: struct #packed {
	pos:   [3]f32,
	rot:   quaternion128,
	sca:   [3]f32,
	type:  i32,
	index: i32,
}

PackedLight :: struct #packed {
	type:        f32,
	use_shadows: f32,
	_pad1:       f32,
	_pad2:       f32,
	pos_x:       f32,
	pos_y:       f32,
	pos_z:       f32,
	range:       f32,
	r:           f32,
	g:           f32,
	b:           f32,
	intensity:   f32,
}

PackedPrimitiveHeader :: struct #packed {
	vertex_count:         u32,
	texture_index:        i32,
	sampler_index:        i32,
	normal_texture_index: i32, // NEW
	normal_sampler_index: i32, // NEW
}

load_scene :: proc(device: ^sdl3.GPUDevice, filepath: string) -> Scene {
	data, err := os.read_entire_file_from_filename_or_err(filepath)
	if err != nil {
		fmt.println("FAILED TO READ FILE!")
		os.exit(1)
	}

	fmt.printf("SIZEOF VERT: %v\n", size_of(RawVertex))

	header := (cast(^SceneHeader)&data[0])^

	fmt.printf("Magic: %04x\n", header.magic)
	fmt.printf("Version: %d\n", header.version)
	fmt.printf("Objects: %d\n", header.object_count)
	fmt.printf("Stride: %d\n", header.stride)
	fmt.printf("Meshes: %d\n", header.mesh_count)
	fmt.printf("Lights: %d\n", header.light_count)
	fmt.printf("Textures: %d\n", header.texture_count)
	fmt.printf("Samplers: %d\n", header.sampler_count)

	objects_ptr := cast(^PackedObject)&data[32]
	packed_objects := mem.slice_ptr(objects_ptr, int(header.object_count))

	scene: Scene
	scene.objects = make([]Object, header.object_count)

	for i in 0 ..< int(header.object_count) {
		p := packed_objects[i]

		m := linalg.matrix4_from_trs_f32(
			linalg.Vector3f32{p.pos[0], p.pos[1], p.pos[2]},
			p.rot,
			linalg.Vector3f32{p.sca[0], p.sca[1], p.sca[2]},
		)

		scene.objects[i] = Object {
			transform   = m,
			mesh_index  = p.type == 1 ? p.index : -1,
			light_index = p.type == 2 ? p.index : -1,
		}
	}


	scene.meshes = make([]RawMesh, header.mesh_count)

	total_v_bytes: int
	temp_offset := 32 + (int(header.object_count) * 48)

	for i in 0 ..< int(header.mesh_count) {
		prim_count := (cast(^u32)&data[temp_offset])^
		temp_offset += 4

		for p in 0 ..< int(prim_count) {
			prim_header := (cast(^PackedPrimitiveHeader)&data[temp_offset])^
			temp_offset += size_of(PackedPrimitiveHeader)
			total_v_bytes += int(prim_header.vertex_count) * size_of(RawVertex)
			temp_offset += int(prim_header.vertex_count) * size_of(RawVertex)
		}
	}

	master_staging := sdl3.CreateGPUTransferBuffer(device, {.UPLOAD, u32(total_v_bytes), 0})
	staging_ptr := sdl3.MapGPUTransferBuffer(device, master_staging, false)


	cmd := sdl3.AcquireGPUCommandBuffer(device)
	copy_pass := sdl3.BeginGPUCopyPass(cmd)

	current_file_offset := 32 + (int(header.object_count) * 48)
	current_staging_offset: int = 0

	for i in 0 ..< int(header.mesh_count) {
		prim_count := (cast(^u32)&data[current_file_offset])^
		current_file_offset += 4

		scene.meshes[i].primitives = make([]RawPrimitive, prim_count)

		for p in 0 ..< int(prim_count) {
			prim_header := (cast(^PackedPrimitiveHeader)&data[current_file_offset])^
			current_file_offset += size_of(PackedPrimitiveHeader)

			v_size := int(prim_header.vertex_count) * size_of(RawVertex)

			mem.copy(
				cast(rawptr)(uintptr(staging_ptr) + uintptr(current_staging_offset)),
				&data[current_file_offset],
				v_size,
			)

			v_buffer := sdl3.CreateGPUBuffer(device, {{.VERTEX}, u32(v_size), 0})

			sdl3.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = master_staging, offset = u32(current_staging_offset)},
				{buffer = v_buffer, offset = 0, size = u32(v_size)},
				false,
			)

			scene.meshes[i].primitives[p] = RawPrimitive {
				vertex_buffer        = v_buffer,
				vertex_count         = prim_header.vertex_count,
				texture_index        = prim_header.texture_index,
				sampler_index        = prim_header.sampler_index,
				normal_texture_index = prim_header.normal_texture_index, // NEW
				normal_sampler_index = prim_header.normal_sampler_index, // NEW
			}

			current_file_offset += v_size
			current_staging_offset += v_size
		}
	}

	// Parsing Lights
	scene.lights = make([]RawLight, header.light_count)
	current_light_offset := current_file_offset

	for i in 0 ..< int(header.light_count) {
		pl := (cast(^PackedLight)&data[current_light_offset])^
		
		scene.lights[i] = RawLight {
			type        = LightType(int(pl.type)),
			color       = {pl.r, pl.g, pl.b},
			intensity   = pl.intensity,
			range       = pl.range,
			use_shadows = u8(pl.use_shadows),
		}

		current_light_offset += size_of(PackedLight)
	}
	current_file_offset = current_light_offset

	sdl3.EndGPUCopyPass(copy_pass)
	sdl3.UnmapGPUTransferBuffer(device, master_staging)
	ok := sdl3.SubmitGPUCommandBuffer(cmd)
	if !ok {
		fmt.println("FAILED TO SUBMIT VERTEX COMMAND BUFFER! EXITING!")
		os.exit(1)
	}
	sdl3.ReleaseGPUTransferBuffer(device, master_staging)

	// Parsing Samplers
	scene.samplers = make([]^sdl3.GPUSampler, header.sampler_count)
	for i in 0 ..< int(header.sampler_count) {
		min_f := data[current_file_offset]
		mag_f := data[current_file_offset+1]
		wrap_u := data[current_file_offset+2]
		wrap_v := data[current_file_offset+3]
		current_file_offset += 4

		info := sdl3.GPUSamplerCreateInfo {
			min_filter = min_f == 0 ? .NEAREST : .LINEAR,
			mag_filter = mag_f == 0 ? .NEAREST : .LINEAR,
			mipmap_mode = .NEAREST, // No mips for now
			address_mode_u = wrap_u == 0 ? .REPEAT : (wrap_u == 1 ? .CLAMP_TO_EDGE : .REPEAT),
			address_mode_v = wrap_v == 0 ? .REPEAT : (wrap_v == 1 ? .CLAMP_TO_EDGE : .REPEAT),
			address_mode_w = .REPEAT,
		}
		scene.samplers[i] = sdl3.CreateGPUSampler(device, info)
	}

	// Parsing Textures
	scene.textures = make([]^sdl3.GPUTexture, header.texture_count)
	
	tex_cmd := sdl3.AcquireGPUCommandBuffer(device)
	tex_copy_pass := sdl3.BeginGPUCopyPass(tex_cmd)
	
	transfer_buffers := make([dynamic]^sdl3.GPUTransferBuffer, 0, header.texture_count)
	defer delete(transfer_buffers)

	for i in 0 ..< int(header.texture_count) {
		path_len := (cast(^u32)&data[current_file_offset])^
		current_file_offset += 4
		
		path_str := string(data[current_file_offset : current_file_offset + int(path_len)])
		current_file_offset += int(path_len)
		
		full_path := fmt.tprintf("textures/%s", path_str)
		c_path := strings.clone_to_cstring(full_path, context.temp_allocator)

		surface := sdl_image.Load(c_path)
		if surface == nil {
			fmt.printf("FAILED TO LOAD TEXTURE: %s\n", full_path)
			// Fallback to avoid crash
			scene.textures[i] = placeholder_gpu_texture
			continue
		}
		
		rgba_surf := sdl3.ConvertSurface(surface, .RGBA32)
		sdl3.DestroySurface(surface)
		
		w := rgba_surf.w
		h := rgba_surf.h
		
		tex_info := sdl3.GPUTextureCreateInfo {
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(w),
			height = u32(h),
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		}
		gpu_tex := sdl3.CreateGPUTexture(device, tex_info)
		scene.textures[i] = gpu_tex

		buffer_size := u32(w * h * 4)
		tb := sdl3.CreateGPUTransferBuffer(device, {.UPLOAD, buffer_size, 0})
		append(&transfer_buffers, tb)
		
		map_ptr := sdl3.MapGPUTransferBuffer(device, tb, false)
		mem.copy(map_ptr, rgba_surf.pixels, int(buffer_size))
		sdl3.UnmapGPUTransferBuffer(device, tb)
		
		sdl3.UploadToGPUTexture(
			tex_copy_pass,
			{transfer_buffer = tb, offset = 0},
			{texture = gpu_tex, w = u32(w), h = u32(h), d = 1},
			false,
		)
		
		sdl3.DestroySurface(rgba_surf)
	}

	sdl3.EndGPUCopyPass(tex_copy_pass)
	tex_ok := sdl3.SubmitGPUCommandBuffer(tex_cmd)
	if !tex_ok {
		fmt.println("TEXTURE UPLOAD FAILED")
	}

	for tb in transfer_buffers {
		sdl3.ReleaseGPUTransferBuffer(device, tb)
	}

	return scene
}
