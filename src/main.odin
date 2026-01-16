// JUICER TODO:
// Implement dynamic shadows (a bool for lights indicating whether it emits shadows or not)
// Implement a physics library and add collider extraction to the Juicer addon

// (SUPER optional) File watcher for the level file (first load - interpret spawn locations, etc. reload - reimport geometry, preserve game state)
// ^ this one is now "SUPER optional" because we effectively have hot reloading by launching the game directly from Blender. But preserving game state may prove to be useful later
// (optional) Shading for more PBR properties (roughness, metalness, AO)
// (SUPER optional) shading for tertiary and situational PBR properties (sheen, SSS, etc.)
// (optional) Support for baked lightmaps (just hardcode it into UV[1])

// NOTE: I sped through a lot of the plumbing with AI. Sorry, don't feel like writing 200 lines of normal map boilerplate
// But the architecture is still mine

package main

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import "core:mem"


window: ^sdl3.Window
device: ^sdl3.GPUDevice
event: sdl3.Event
keyboardEvent: sdl3.KeyboardEvent
render_pipeline: ^sdl3.GPUGraphicsPipeline

// PLACEHOLDER TEXTURE (for missing textures)
placeholder_gpu_texture: ^sdl3.GPUTexture
placeholder_gpu_sampler: ^sdl3.GPUSampler

// TEXT RENDERING GLOBALS
text_state: TextPipelineState
text: ttf.Text

main :: proc() {
	// Step 0. Application init & device
	window = sdl3.CreateWindow("My Window", 640, 480, {.MOUSE_GRABBED, .RESIZABLE})
	device = sdl3.CreateGPUDevice({.SPIRV}, true, nil)
	if !sdl3.ClaimWindowForGPUDevice(device, window) {
		fmt.println("FAILED TO CLAIM WINDOW FOR GPU!!!")
		return
	}

	// Step 1. Render initialization (placeholder texture, render pipeline)
	render_pipeline, text_state = render_init()

	// Step 2. Loading the .bin file as a scene
	args := os.args
	filepath := "scene.bin"

	// Iterate args to find first non-flag argument as filepath
	for i in 1 ..< len(args) {
		arg := args[i]
		if !strings.has_prefix(arg, "-") {
			filepath = arg
			break
		}
	}

	scene := load_scene(device, filepath)

	// Step 3. Upload scene data to the GPU
	// gpu_upload(&scene) // THIS STEP IS OBSOLETE NOW. load_scene() UPLOADS THE DATA TO THE GPU

	ok := sdl3.SetWindowRelativeMouseMode(window, true)

	// Debug UI init
	ttf.Init()
	defer ttf.Quit()
	font := ttf.OpenFont("font.ttf", 24)
	defer ttf.CloseFont(font)
	engine := ttf.CreateGPUTextEngine(device)
	defer ttf.DestroyGPUTextEngine(engine)
	text := ttf.CreateText(engine, font, cstring("Hello world"), 11)
	defer ttf.DestroyText(text)

	// THE MAIN PROGRAM LOOP
	// =====================================================
	for window != nil {
		// INPUT POLLING
		// ==========================================================
		mouse_dx, mouse_dy: f32 // mouse
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

		pos_str := fmt.tprintf("Pos: %.2f, %.2f, %.2f",
    main_camera.position.x, main_camera.position.y, main_camera.position.z)
		// Make null-terminated version
		cstr := make([]u8, len(pos_str) + 1)
		mem.copy(raw_data(cstr), raw_data(pos_str), len(pos_str))
		cstr[len(pos_str)] = 0
		ttf.SetTextString(text, cstring(raw_data(cstr)), uint(len(pos_str)))
		// RENDER LOOP (step 4)
		// ===============================================
		render(scene, text, text_state)
	}
}
