// JUICER TODO:
// Implement dynamic shadows (a bool for lights indicating whether it emits shadows or not)
// Support for normal maps
// (Blender) playing the current scene directly from Blender (F5 -> export scene -> odin run . --scene "level.bin")
// (Blender) ^ need an actual addon called Juicer doing all of this

// (optional) File watcher for the level file (first load - interpret spawn locations, etc. reload - reimport geometry, preserve game state)
// (optional) Shading for more PBR properties (roughness, metalness, sheen, SSS, etc.)
// (optional) Support for baked lightmaps (just hardcode it into UV[1])

// UPDATED TODO:
// fuck gltf
// we are literally balling

package main

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "vendor:sdl3"

window: ^sdl3.Window
device: ^sdl3.GPUDevice
event: sdl3.Event
keyboardEvent: sdl3.KeyboardEvent
render_pipeline: ^sdl3.GPUGraphicsPipeline

// PLACEHOLDER TEXTURE (for missing textures)
placeholder_gpu_texture: ^sdl3.GPUTexture
placeholder_gpu_sampler: ^sdl3.GPUSampler

gpu_textures: [dynamic]^sdl3.GPUTexture
gpu_primitives: [dynamic]GPUPrimitive
gpu_meshes: [dynamic]GPUMesh

main :: proc() {
	// Step 0. Application init & device
	window = sdl3.CreateWindow("My Window", 640, 480, {.MOUSE_GRABBED, .RESIZABLE})
	device = sdl3.CreateGPUDevice({.SPIRV}, true, nil)
	if !sdl3.ClaimWindowForGPUDevice(device, window) {
		fmt.println("FAILED TO CLAIM WINDOW FOR GPU!!!")
		return
	}

	// Step 1. Render initialization (placeholder texture, render pipeline)
	render_pipeline = render_init()

	// Step 2. Loading the .bin file as a scene
	scene := load_scene(device, "scene.bin")

	// Step 3. Upload scene data to the GPU
	// gpu_upload(&scene) // THIS STEP IS OBSOLETE NOW. load_scene() UPLOADS THE DATA TO THE GPU

	ok := sdl3.SetWindowRelativeMouseMode(window, true)

	// THE MAIN PROGRAM LOOP
	// =====================================================
	for window != nil {
		// INPUT POLLING
		// ==========================================================
		mouse_dx, mouse_dy: f32
		mouse_flags := sdl3.GetRelativeMouseState(&mouse_dx, &mouse_dy)
		main_camera.yaw += mouse_dx * 0.002
		main_camera.pitch += mouse_dy * 0.002
		main_camera.pitch = clamp(main_camera.pitch, -1.5, 1.5)

		keys := sdl3.GetKeyboardState(nil)

		move_forward := linalg.Vector3f32 {
			linalg.sin(main_camera.yaw),
			0,
			linalg.cos(main_camera.yaw),
		}
		move_right := linalg.Vector3f32 {
			linalg.cos(main_camera.yaw),
			0,
			-linalg.sin(main_camera.yaw),
		}

		speed: f32 = 0.02

		if keys[sdl3.Scancode.W] != false {
			main_camera.position -= move_forward * speed
		}
		if keys[sdl3.Scancode.S] != false {
			main_camera.position += move_forward * speed
		}
		if keys[sdl3.Scancode.A] != false {
			main_camera.position += move_right * speed
		}
		if keys[sdl3.Scancode.D] != false {
			main_camera.position -= move_right * speed
		}

		for sdl3.PollEvent(&event) {
			#partial switch event.type {
			case .KEY_DOWN:
				if event.key.key == sdl3.K_ESCAPE {
					sdl3.Quit()
					window = nil
				}
			case .WINDOW_RESIZED:
				w, h: c.int
				sdl3.GetWindowSize(window, &w, &h)

				// Recreate depth texture
				sdl3.ReleaseGPUTexture(device, depth_texture)
				depth_texture = sdl3.CreateGPUTexture(
					device,
					sdl3.GPUTextureCreateInfo {
						type = .D2,
						format = .D32_FLOAT,
						usage = {.DEPTH_STENCIL_TARGET},
						width = u32(w),
						height = u32(h),
						layer_count_or_depth = 1,
						num_levels = 1,
						sample_count = ._1,
						props = 0,
					},
				)

				// Update projection
				projection_matrix = linalg.matrix4_perspective_f32(
					linalg.to_radians(f32(72)),
					f32(w) / f32(h),
					0.1,
					1000.0,
					false,
				)
			}
		}
		// RENDER LOOP (step 4)
		// ===============================================
		render(scene)
	}
}
