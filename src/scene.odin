package main

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
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
}

RawMesh :: struct {
	primitives: []RawPrimitive,
}

RawPrimitive :: struct {
	vertices:      []RawVertex,
	indices:       []u32,
	vertex_buffer: ^sdl3.GPUBuffer,
	vertex_count:  u32,
	texture_index: i32, // -1 = no texture, use placeholder
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
	vertex_buffer: ^sdl3.GPUBuffer,
	index_buffer:  ^sdl3.GPUBuffer,
	index_count:   u32,
	texture_index: i32,
}

GPUMesh :: struct {
	primitives: []GPUPrimitive,
}


Object :: struct {
	transform:   linalg.Matrix4f32,
	mesh_index:  i32,
	light_index: i32,
	// children:   [dynamic]^Node, // not yet
	// parent pointer maybe later, not now
}

Scene :: struct {
	objects:  []Object,
	meshes:   []RawMesh,
	textures: []RawTexture,
	samplers: []RawSampler,
	lights:   []RawLight,
}

LevelHeader :: struct #packed {
	magic:        u32,
	version:      u32,
	object_count: u32,
	stride:       u32,
	// texture_count:   u32,
	// light_count:     u32,
	// object_offset:   u32,
	// meshes_offset:   u32,
	// textures_offset: u32,
	// lights_offset:   u32,
}

PackedObject :: struct #packed {
	pos:   [3]f32,
	rot:   quaternion128,
	sca:   [3]f32,
	type:  i32,
	index: i32,
}

// STEPS
// 1. Load the binary file into memory
// 2. recognize slices (probably the metadata within the binary file itself)
// 3. Probably just directly use the loaded binary's data for level rendering

load_scene :: proc(device: ^sdl3.GPUDevice, filepath: string) -> Scene {
	data, err := os.read_entire_file_from_filename_or_err(filepath)
	if err != nil {
		fmt.println("FAILED TO READ FILE!")
		os.exit(1)
	}

	fmt.printf("SIZEOF VERT: %v\n", size_of(RawVertex))

	header := (cast(^LevelHeader)&data[0])^ // it's lowkey kinda cool how you can just cast this to a level header and it just works

	fmt.printf("Magic: %04x\n", header.magic)
	fmt.printf("Version: %d\n", header.version)
	fmt.printf("Objects: %d\n", header.object_count)
	fmt.printf("Stride: %d\n", header.stride)

	objects_ptr := cast(^PackedObject)&data[16]
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


	scene.meshes = make([]RawMesh, 17) // TODO: this is currently hardcoded to only contain 17 meshes. this is information that will have to be baked into the header later

	total_v_bytes: int
	temp_offset := 16 + (int(header.object_count) * 48)

	for i in 0 ..< 17 {
		v_count := (cast(^u32)&data[temp_offset])^
		total_v_bytes += int(v_count) * size_of(RawVertex)
		temp_offset += 4 + (int(v_count) * size_of(RawVertex)) // don't forget to change this to 8 when we introduce more data to the mesh header
	}

	master_staging := sdl3.CreateGPUTransferBuffer(device, {.UPLOAD, u32(total_v_bytes), 0})
	staging_ptr := sdl3.MapGPUTransferBuffer(device, master_staging, false)


	cmd := sdl3.AcquireGPUCommandBuffer(device)
	copy_pass := sdl3.BeginGPUCopyPass(cmd)

	current_file_offset := 16 + (int(header.object_count) * 48)
	current_staging_offset: int = 0

	for i in 0 ..< 17 {
		v_count := (cast(^u32)&data[current_file_offset])^
		current_file_offset += 4 // don't forget to change this to 8 when we introduce more data to the mesh header
		v_size := int(v_count) * size_of(RawVertex)

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

		current_file_offset += v_size
		current_staging_offset += v_size

	}

	sdl3.EndGPUCopyPass(copy_pass)
	sdl3.UnmapGPUTransferBuffer(device, master_staging)
	ok := sdl3.SubmitGPUCommandBuffer(cmd)
	if !ok {
		fmt.println("FAILED TO SUBMIT COMMAND BUFFER! EXITING!")
		os.exit(1)
	}
	sdl3.ReleaseGPUTransferBuffer(device, master_staging)


	return scene
}


// ALSO, TODO2: MAKE SURE TO SUBMIT EVERYTHING WITH JUST ONE COMMAND BUFFER INSTEAD OF... WHATEVER THE FUCK I AM DOING RIGHT NOW
// gpu_upload :: proc(scene: ^Scene) {
// 	// TEXTURE UPLOAD
// 	for &tex in scene.textures {
// 		size: u32 = tex.width * tex.height * 4
// 		gpu_texture := sdl3.CreateGPUTexture(
// 			device,
// 			sdl3.GPUTextureCreateInfo {
// 				type = .D2,
// 				format = .R8G8B8A8_UNORM,
// 				usage = {.SAMPLER},
// 				width = tex.width,
// 				height = tex.height,
// 				layer_count_or_depth = 1,
// 				num_levels = 1,
// 				sample_count = ._1,
// 				props = 0,
// 			},
// 		)
// 		append(&gpu_textures, gpu_texture)
// 		transfer_buffer := sdl3.CreateGPUTransferBuffer(
// 			device,
// 			sdl3.GPUTransferBufferCreateInfo{.UPLOAD, size, 0},
// 		)
// 		transfer_ptr := sdl3.MapGPUTransferBuffer(device, transfer_buffer, false)
// 		if transfer_ptr == nil {
// 			fmt.println("TRANSFER BUFFER MAP FAILED!")
// 			continue
// 		}
// 		mem.copy(transfer_ptr, raw_data(tex.bytes), int(size))
// 		sdl3.UnmapGPUTransferBuffer(device, transfer_buffer)
//
// 		cmd := sdl3.AcquireGPUCommandBuffer(device)
// 		copy_pass := sdl3.BeginGPUCopyPass(cmd)
// 		sdl3.UploadToGPUTexture(
// 			copy_pass,
// 			sdl3.GPUTextureTransferInfo {
// 				transfer_buffer = transfer_buffer,
// 				offset = 0,
// 				pixels_per_row = tex.width,
// 				rows_per_layer = tex.height,
// 			},
// 			sdl3.GPUTextureRegion {
// 				texture = gpu_texture,
// 				mip_level = 0,
// 				layer = 0,
// 				x = 0,
// 				y = 0,
// 				z = 0,
// 				w = tex.width,
// 				h = tex.height,
// 				d = 1,
// 			},
// 			false,
// 		)
// 		sdl3.EndGPUCopyPass(copy_pass)
// 		submit_ok := sdl3.SubmitGPUCommandBuffer(cmd)
// 		if !submit_ok {
// 			fmt.println("FAILED TO SUBMIT THE GPU COMMAND BUFFER! SOMETHING WENT WRONG!!!")
// 			continue
// 		}
// 		sdl3.ReleaseGPUTransferBuffer(device, transfer_buffer)
// 	}
//
// 	// MESH UPLOAD
// 	for &mesh in scene.meshes {
// 		gpu_prims: [dynamic]GPUPrimitive
//
// 		for &prim in mesh.primitives {
// 			vertex_size := len(prim.vertices) * size_of(RawVertex)
// 			index_size := len(prim.indices) * size_of(u32)
//
// 			// Vertex buffer
// 			vertex_buffer := sdl3.CreateGPUBuffer(
// 				device,
// 				sdl3.GPUBufferCreateInfo{{.VERTEX}, u32(vertex_size), 0},
// 			)
// 			transfer_buffer_v := sdl3.CreateGPUTransferBuffer(
// 				device,
// 				sdl3.GPUTransferBufferCreateInfo{.UPLOAD, u32(vertex_size), 0},
// 			)
// 			transfer_ptr_v := sdl3.MapGPUTransferBuffer(device, transfer_buffer_v, false)
// 			mem.copy(transfer_ptr_v, raw_data(prim.vertices), vertex_size)
// 			sdl3.UnmapGPUTransferBuffer(device, transfer_buffer_v)
//
// 			// Index buffer
// 			index_buffer := sdl3.CreateGPUBuffer(
// 				device,
// 				sdl3.GPUBufferCreateInfo{{.INDEX}, u32(index_size), 0},
// 			)
// 			transfer_buffer_i := sdl3.CreateGPUTransferBuffer(
// 				device,
// 				sdl3.GPUTransferBufferCreateInfo{.UPLOAD, u32(index_size), 0},
// 			)
// 			transfer_ptr_i := sdl3.MapGPUTransferBuffer(device, transfer_buffer_i, false)
// 			mem.copy(transfer_ptr_i, raw_data(prim.indices), index_size)
// 			sdl3.UnmapGPUTransferBuffer(device, transfer_buffer_i)
//
// 			// Copy pass
// 			cmd := sdl3.AcquireGPUCommandBuffer(device)
// 			copy_pass := sdl3.BeginGPUCopyPass(cmd)
// 			sdl3.UploadToGPUBuffer(
// 				copy_pass,
// 				sdl3.GPUTransferBufferLocation{transfer_buffer = transfer_buffer_v, offset = 0},
// 				sdl3.GPUBufferRegion{buffer = vertex_buffer, offset = 0, size = u32(vertex_size)},
// 				false,
// 			)
// 			sdl3.UploadToGPUBuffer(
// 				copy_pass,
// 				sdl3.GPUTransferBufferLocation{transfer_buffer = transfer_buffer_i, offset = 0},
// 				sdl3.GPUBufferRegion{buffer = index_buffer, offset = 0, size = u32(index_size)},
// 				false,
// 			)
// 			sdl3.EndGPUCopyPass(copy_pass)
// 			ok := sdl3.SubmitGPUCommandBuffer(cmd)
// 			sdl3.ReleaseGPUTransferBuffer(device, transfer_buffer_v)
// 			sdl3.ReleaseGPUTransferBuffer(device, transfer_buffer_i)
//
// 			append(
// 				&gpu_prims,
// 				GPUPrimitive {
// 					vertex_buffer,
// 					index_buffer,
// 					u32(len(prim.indices)),
// 					prim.texture_index,
// 				},
// 			)
// 		}
//
// 		append(&gpu_meshes, GPUMesh{primitives = gpu_prims[:]})
// 	}
// }
