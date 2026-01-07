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

SceneHeader :: struct #packed {
	magic:        u32,
	version:      u32,
	object_count: u32,
	stride:       u32,
	mesh_count:   u32,
	light_count:  u32,
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

	header := (cast(^SceneHeader)&data[0])^ // it's lowkey kinda cool how you can just cast this to a level header and it just works

	fmt.printf("Magic: %04x\n", header.magic)
	fmt.printf("Version: %d\n", header.version)
	fmt.printf("Objects: %d\n", header.object_count)
	fmt.printf("Stride: %d\n", header.stride)
	fmt.printf("Meshes: %d\n", header.mesh_count)
	fmt.printf("Lights: %d\n", header.light_count)

	objects_ptr := cast(^PackedObject)&data[24] // 24 now because of the light count header
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
	temp_offset := 24 + (int(header.object_count) * 48)

	for i in 0 ..< int(header.mesh_count) {
		v_count := (cast(^u32)&data[temp_offset])^
		total_v_bytes += int(v_count) * size_of(RawVertex)
		temp_offset += 4 + (int(v_count) * size_of(RawVertex)) // don't forget to change this to 8 when we introduce more data to the mesh header
	}

	master_staging := sdl3.CreateGPUTransferBuffer(device, {.UPLOAD, u32(total_v_bytes), 0})
	staging_ptr := sdl3.MapGPUTransferBuffer(device, master_staging, false)


	cmd := sdl3.AcquireGPUCommandBuffer(device)
	copy_pass := sdl3.BeginGPUCopyPass(cmd)

	current_file_offset := 24 + (int(header.object_count) * 48)
	current_staging_offset: int = 0

	for i in 0 ..< int(header.mesh_count) {
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

		scene.meshes[i].primitives = make([]RawPrimitive, 1)
		scene.meshes[i].primitives[0] = RawPrimitive {
			vertex_buffer = v_buffer,
			vertex_count  = v_count,
			texture_index = -1,
		}

		current_file_offset += v_size
		current_staging_offset += v_size

	}

	// Parsing Lights
	scene.lights = make([]RawLight, header.light_count)

	// Offset is now at the end of the last mesh data
	// The binary format appends lights immediately after meshes
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
