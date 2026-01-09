package main

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "vendor:sdl3"
import sdl_image "vendor:sdl3/image"

Camera3D :: struct {
	position: linalg.Vector3f32,
	yaw:      f32, // horizontal
	pitch:    f32, // vertical
	// no roll (upgrading to a quaternion later is trivial)
}

CameraUniform :: struct {
	mvp:   linalg.Matrix4f32,
	model: linalg.Matrix4f32,
}

MAX_LIGHTS :: 16

// Packed for std140 layout: vec4s only, no alignment issues
LightData :: struct {
	header:          [4]f32, // x = type, y = uses shadows, zw = unused for now
	position_range:  [4]f32, // xyz = position, w = range
	color_intensity: [4]f32, // xyz = color, w = intensity
}

LightsUniform :: struct {
	lights:      [MAX_LIGHTS]LightData,
	light_count: i32,
	_pad:        [3]i32,
}

main_camera := Camera3D {
	position = linalg.Vector3f32{0, 2, 5},
	yaw      = 0,
	pitch    = 0,
}
projection_matrix: linalg.Matrix4f32 // make it globally available for now

depth_texture: ^sdl3.GPUTexture
default_normal_texture: ^sdl3.GPUTexture // NEW

render_init :: proc() -> ^sdl3.GPUGraphicsPipeline {
	// Placeholder texture (Base Color)
	surface := sdl_image.Load("placeholder.png")
	if surface == nil {
		fmt.println("FAILED TO LOAD THE PLACEHOLDER TEXTURE!")
		os.exit(1)
	}
	rgba_surface := sdl3.ConvertSurface(surface, .RGBA32)
	sdl3.DestroySurface(surface)
	width := rgba_surface.w
	height := rgba_surface.h
	placeholder_pixels := rgba_surface.pixels

	// Camera proj matrix initialization
	w, h: c.int
	sdl3.GetWindowSize(window, &w, &h)
	projection_matrix = linalg.matrix4_perspective_f32(
		linalg.to_radians(f32(72)),
		f32(w) / f32(h),
		0.1,
		1000.0,
		false,
	)

	// Create Base Color Placeholder
	placeholder_gpu_texture = sdl3.CreateGPUTexture(
		device,
		sdl3.GPUTextureCreateInfo {
			.D2,
			.R8G8B8A8_UNORM,
			{.SAMPLER},
			u32(width),
			u32(height),
			1,
			1,
			._1,
			0,
		},
	)

	// Create Normal Map Placeholder (Flat Normal: 0.5, 0.5, 1.0)
	// In bytes: 128, 128, 255, 255
	flat_normal_pixels := [4]u8{128, 128, 255, 255}
	default_normal_texture = sdl3.CreateGPUTexture(
		device,
		sdl3.GPUTextureCreateInfo {
			.D2,
			.R8G8B8A8_UNORM,
			{.SAMPLER},
			1,
			1,
			1,
			1,
			._1,
			0,
		},
	)

	// Create Sampler
	placeholder_gpu_sampler = sdl3.CreateGPUSampler(
		device,
		sdl3.GPUSamplerCreateInfo {
			.NEAREST,
			.NEAREST,
			.NEAREST,
			.REPEAT,
			.REPEAT,
			.REPEAT,
			{},
			{},
			{},
			{},
			{},
			{},
			{},
			{},
			{},
			{},
		},
	)

	// Transfer Buffer for both placeholders
	// Size = (width * height * 4) + (1 * 1 * 4)
	total_size := u32(width * height * 4) + 4
	transfer_buffer := sdl3.CreateGPUTransferBuffer(
		device,
		sdl3.GPUTransferBufferCreateInfo{.UPLOAD, total_size, 0},
	)

	transfer_ptr := sdl3.MapGPUTransferBuffer(device, transfer_buffer, false)

	// Copy Base Color
	mem.copy(transfer_ptr, placeholder_pixels, int(width * height * 4))

	// Copy Normal (Offset by base color size)
	normal_offset := uintptr(width * height * 4)
	mem.copy(cast(rawptr)(uintptr(transfer_ptr) + normal_offset), &flat_normal_pixels, 4)

	sdl3.UnmapGPUTransferBuffer(device, transfer_buffer)

	cmd := sdl3.AcquireGPUCommandBuffer(device)
	copy_pass := sdl3.BeginGPUCopyPass(cmd)

	// Upload Base Color
	sdl3.UploadToGPUTexture(
		copy_pass,
		sdl3.GPUTextureTransferInfo {
			transfer_buffer = transfer_buffer,
			pixels_per_row = u32(width),
			rows_per_layer = u32(height),
		},
		sdl3.GPUTextureRegion {
			texture = placeholder_gpu_texture,
			w = u32(width),
			h = u32(height),
			d = 1,
		},
		false,
	)

	// Upload Normal
	sdl3.UploadToGPUTexture(
		copy_pass,
		sdl3.GPUTextureTransferInfo {
			transfer_buffer = transfer_buffer,
			offset = u32(normal_offset),
			pixels_per_row = 1,
			rows_per_layer = 1,
		},
		sdl3.GPUTextureRegion {
			texture = default_normal_texture,
			w = 1,
			h = 1,
			d = 1,
		},
		false,
	)

	sdl3.EndGPUCopyPass(copy_pass)
	submit_ok_init := sdl3.SubmitGPUCommandBuffer(cmd)
	if !submit_ok_init {
		fmt.println("FAILED TO SUBMIT INIT COMMAND BUFFER!")
	}
	sdl3.ReleaseGPUTransferBuffer(device, transfer_buffer)

	// SHADER STUFF
	format := sdl3.GetGPUSwapchainTextureFormat(device, window)

	vert_data, vert_ok := os.read_entire_file("shaders/compiled/triangle.vert.spv")
	if !vert_ok {
		fmt.println("VERT SHADER FAILED TO IMPORT!")
		os.exit(1)
	}
	frag_data, frag_ok := os.read_entire_file("shaders/compiled/triangle.frag.spv")
	if !frag_ok {
		fmt.println("FRAG SHADER FAILED TO IMPORT!")
		os.exit(1)
	}
	vertex_info := sdl3.GPUShaderCreateInfo {
		len(vert_data),
		raw_data(vert_data),
		"main",
		{.SPIRV},
		.VERTEX,
		0,
		0,
		0,
		1,
		0,
	}

	fragment_info := sdl3.GPUShaderCreateInfo {
		len(frag_data),
		raw_data(frag_data),
		"main",
		{.SPIRV},
		.FRAGMENT,
		2, // Changed to 2 samplers
		0,
		0,
		1,
		0,
	}

	vertex_shader := sdl3.CreateGPUShader(device, vertex_info)
	fragment_shader := sdl3.CreateGPUShader(device, fragment_info)

	// Depth texture
	depth_texture = sdl3.CreateGPUTexture(
	device,
	sdl3.GPUTextureCreateInfo {
		type                 = .D2,
		format               = .D32_FLOAT, // or D24_UNORM_S8_UINT if I want stencil
		usage                = {.DEPTH_STENCIL_TARGET},
		width                = u32(w),
		height               = u32(h),
		layer_count_or_depth = 1,
		num_levels           = 1,
		sample_count         = ._1,
		props                = 0,
	},
	)

	depth_stencil_state := sdl3.GPUDepthStencilState {
		compare_op         = .LESS,
		enable_depth_test  = true,
		enable_depth_write = true,
	}

	render_pipeline_info := sdl3.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		vertex_input_state = sdl3.GPUVertexInputState {
			vertex_buffer_descriptions = &sdl3.GPUVertexBufferDescription {
				slot = 0,
				pitch = size_of(RawVertex), // Now 48 bytes
				input_rate = .VERTEX,
				instance_step_rate = 0,
			},
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(
				[]sdl3.GPUVertexAttribute {
					{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0}, // position
					{location = 1, buffer_slot = 0, format = .FLOAT2, offset = 12}, // uv (3*4)
					{location = 2, buffer_slot = 0, format = .FLOAT3, offset = 20}, // normal (3*4 + 2*4)
					{location = 3, buffer_slot = 0, format = .FLOAT4, offset = 32}, // tangent (NEW)
				},
			),
			num_vertex_attributes      = 4,
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = sdl3.GPURasterizerState {
			cull_mode = .BACK,
			front_face = .COUNTER_CLOCKWISE,
		},
		multisample_state = {},
		depth_stencil_state = depth_stencil_state,
		target_info = sdl3.GPUGraphicsPipelineTargetInfo {
			color_target_descriptions = &sdl3.GPUColorTargetDescription{format = format},
			num_color_targets = 1,
			has_depth_stencil_target = true,
			depth_stencil_format = .D32_FLOAT,
		},
		props = 0,
	}


	return sdl3.CreateGPUGraphicsPipeline(device, render_pipeline_info)
}

render :: proc(scene: Scene) {
	command_buffer := sdl3.AcquireGPUCommandBuffer(device)

	swapchain_texture: ^sdl3.GPUTexture
	if !sdl3.AcquireGPUSwapchainTexture(command_buffer, window, &swapchain_texture, nil, nil) {
		if !sdl3.SubmitGPUCommandBuffer(command_buffer) {
			fmt.println("FAILED TO SUBMIT GPU COMMAND BUFFER!")
		}
		return
	}

	color_target := sdl3.GPUColorTargetInfo {
		texture     = swapchain_texture,
		load_op     = .CLEAR,
		store_op    = .STORE,
		clear_color = {0.0, 0.0, 0.0, 1.0},
	}
	depth_target := sdl3.GPUDepthStencilTargetInfo {
		texture     = depth_texture,
		load_op     = .CLEAR,
		store_op    = .STORE,
		clear_depth = 1.0,
	}

	render_pass := sdl3.BeginGPURenderPass(command_buffer, &color_target, 1, &depth_target)
	sdl3.BindGPUGraphicsPipeline(render_pass, render_pipeline)

	// Calculate Lights
	lights_uniform := LightsUniform{}
	light_idx := 0

	for obj in scene.objects {
		if obj.light_index >= 0 && light_idx < MAX_LIGHTS {
			l := scene.lights[obj.light_index]
			pos := linalg.Vector3f32{
				obj.transform[3][0],
				obj.transform[3][1],
				obj.transform[3][2],
			}
			lights_uniform.lights[light_idx] = LightData {
				header = {f32(l.type), f32(l.use_shadows), 0, 0},
				position_range = {pos.x, pos.y, pos.z, l.range},
				color_intensity = {l.color.r, l.color.g, l.color.b, l.intensity},
			}
			light_idx += 1
		}
	}
	lights_uniform.light_count = i32(light_idx)
	sdl3.PushGPUFragmentUniformData(command_buffer, 0, &lights_uniform, size_of(lights_uniform))

	// VP Matrix
	forward := linalg.Vector3f32 {
		linalg.cos(main_camera.pitch) * linalg.sin(main_camera.yaw),
		linalg.sin(main_camera.pitch),
		linalg.cos(main_camera.pitch) * linalg.cos(main_camera.yaw),
	}
	view := linalg.matrix4_look_at_f32(
		main_camera.position,
		main_camera.position + forward,
		{0, 1, 0},
	)
	vp := projection_matrix * view

	for &obj in scene.objects {
		if obj.mesh_index < 0 || int(obj.mesh_index) >= len(scene.meshes) {
			continue
		}

		camera_data := CameraUniform {
			mvp   = vp * obj.transform,
			model = obj.transform,
		}
		sdl3.PushGPUVertexUniformData(command_buffer, 0, &camera_data, size_of(camera_data))

		gpu_mesh := scene.meshes[obj.mesh_index]

		for &prim in gpu_mesh.primitives {
			// Resolve Base Color
			tex := placeholder_gpu_texture
			samp := placeholder_gpu_sampler

			if prim.texture_index >= 0 && int(prim.texture_index) < len(scene.textures) {
				tex = scene.textures[prim.texture_index]
			}
			if prim.sampler_index >= 0 && int(prim.sampler_index) < len(scene.samplers) {
				samp = scene.samplers[prim.sampler_index]
			}

			// Resolve Normal Map
			norm_tex := default_normal_texture
			norm_samp := placeholder_gpu_sampler // Use default sampler for normal map too

			if prim.normal_texture_index >= 0 && int(prim.normal_texture_index) < len(scene.textures) {
				norm_tex = scene.textures[prim.normal_texture_index]
			}
			if prim.normal_sampler_index >= 0 && int(prim.normal_sampler_index) < len(scene.samplers) {
				norm_samp = scene.samplers[prim.normal_sampler_index]
			}

			// Bind Both Textures
			bindings := [2]sdl3.GPUTextureSamplerBinding{
				{texture = tex, sampler = samp},
				{texture = norm_tex, sampler = norm_samp},
			}
			sdl3.BindGPUFragmentSamplers(render_pass, 0, raw_data(bindings[:]), 2)

			buf_binding := sdl3.GPUBufferBinding {
				buffer = prim.vertex_buffer,
				offset = 0,
			}
			sdl3.BindGPUVertexBuffers(render_pass, 0, &buf_binding, 1)

			sdl3.DrawGPUPrimitives(render_pass, prim.vertex_count, 1, 0, 0)
		}
	}

	sdl3.EndGPURenderPass(render_pass)
	if !sdl3.SubmitGPUCommandBuffer(command_buffer) {
		fmt.println("FAILED TO SUBMIT COMMAND BUFFER!")
		os.exit(1)
	}
}
