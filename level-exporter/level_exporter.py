import struct
import sys

import os
import shutil

import bpy
from bpy.types import PointLight, SpotLight, SunLight

# scene DATA HEADER CHEAT SHEET
# 0 = Magic number (b00bface), u32
# 4 = version number (currently 0), u32 (could be 1 byte, but padded to 4 for alignment)
# 8 = number of objects, u32 (current number of objects in the SCENE)
# 12 = number of object properties, u32 (48, might change with custom properties)
# 16 = mesh count (total number of meshes in the data)
# 20 = primitive count (a mesh is just a collection of primitives)
# 24 = light count (total number of lights in the data)
# 28 = texture count (total number of textures in the data)
# 32 = sampler count (total number of samplers in the data; exported dynamically through texnode properties)


# 36 = OBJECTS BEGIN


FILTER_MAP = { 'NEAREST': 0, 'LINEAR': 1 }
WRAP_MAP = { 'REPEAT': 0, 'MIRRORED_REPEAT': 1, 'CLAMP_TO_EDGE': 2, }


def write_scene(filepath):
    with open(filepath, "wb") as scenebin:
        print(
            "Total objects: " + str(len(bpy.context.scene.objects))
        )  # bpy.context.scene = stuff within the blender scene
        print(
            "Total mesh variants: " + str(len(bpy.data.meshes))
        )  # bpy.data = stuff available globally in the blender file
        print("Total light variants: " + str(len(bpy.data.lights)))

        # magic = b"\xB0\x0B\xFA\xCE"
        # or
        # magic = bytes.fromhex("B00BFACE")
        # OR (best if you want to specify endianess)
        magic = struct.pack(
            "<I", 0xB00BFACE
        )  # btw i would totally just skip hexdumping this for testing. Read directly in odin
        # btw instead of hexdumping, i should be using od. like:
        # od -t x4 -An scene.bin | head -n 50

        # write the magic number first
        scenebin.write(magic)  # 4 bytes
        scenebin.write(b"\x00\x00\x00\x00")  # version numbah (4 bytes)

        # total number of objects
        scenebin.write(
            struct.pack("<I", len(bpy.context.scene.objects))
        )  # u32, 4 bytes

        # total length of a single object's properties
        scenebin.write(struct.pack("<I", 48))  # right now it's ~~12~~ 48 lol

        # total number of meshes
        scenebin.write(struct.pack("<I", len(bpy.data.meshes)))  # u32, 4 bytes

        # total number of lights
        scenebin.write(struct.pack("<I", len(bpy.data.lights))) # u32, 4 bytes

        # enumerating meshes and lights
        mesh_map = {mesh.name: i for i, mesh in enumerate(bpy.data.meshes)}
        light_map = {light.name: i for i, light in enumerate(bpy.data.lights)}

        # individual objects first
        for obj in bpy.context.scene.objects:  # 48 bytes total (should remain that way until i introduce custom properties)
            pos = obj.location
            rot = obj.matrix_world.to_quaternion()
            sca = obj.scale

            # Z-up (Blender) to Y-up (Odin/OpenGL) conversion
            # Position: (x, y, z) -> (x, z, y)
            scenebin.write(struct.pack("<fff", pos.x, pos.z, pos.y))  # 12 bytes
            print(pos.x, pos.z, pos.y)

            # Rotation: (w, x, y, z) -> (w, x, z, y)
            scenebin.write(struct.pack("<ffff", rot.w, rot.x, rot.z, rot.y))  # 16 bytes
            print(rot.w, rot.x, rot.z, rot.y)

            # Scale: (x, y, z) -> (x, -z, -y)
            scenebin.write(struct.pack("<fff", sca.x, -sca.z, -sca.y))  # 12 bytes
            print(sca.x, sca.z, sca.y)

            match obj.type:
                case "EMPTY":
                    scenebin.write(struct.pack("<I", 0))  # type index
                    scenebin.write(
                        struct.pack("<I", 0)
                    )  # data index (0 for no type by default)
                case "MESH":
                    scenebin.write(struct.pack("<I", 1))  # type index
                    scenebin.write(
                        struct.pack("<I", mesh_map[obj.data.name])
                    )  # data index
                case "LIGHT":
                    scenebin.write(struct.pack("<I", 2))  # type index
                    scenebin.write(
                        struct.pack("<I", light_map[obj.data.name])
                    )  # data index

        # MESH STRIDE
        # header + header = 8 bytes
        # after that - vertex data (32 bytes each)
        # we won't be writing indices for now
        for mesh in bpy.data.meshes:
            mesh.calc_loop_triangles()

            # write the headers first
            vert_len = (
                len(mesh.loop_triangles) * 3
            )  # length * 3 cuz we're doing a flat array of vertices for now
            scenebin.write(struct.pack("<I", vert_len))  # 4 bytes
            # idx_len = len(indices) # mesh header #2, 4 bytes
            # scenebin.write(struct.pack("<I", idx_len))

            # Force using the first UV layer (index 0) for now
            uv_layer = mesh.uv_layers[0].data if len(mesh.uv_layers) > 0 else None
            # Old way: uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None

            for tri in mesh.loop_triangles:  # iterate through polygons instead, not verts
                # init the index struct first
                # indices = []
                # indices.append(tri.vertices[0])
                # indices.append(tri.vertices[1])
                # indices.append(tri.vertices[2]) # lol whatever man, it works

                for loop_index in tri.loops:  # loop to write vertex data
                    loop = mesh.loops[
                        loop_index
                    ]  # this grabs the current loop. A loop is actually the point that the GPU will consume
                    # this is some wacky for looping that I'm not used to, but let's keep going
                    # eventually i think i want to consolidate identical loops to save storage memory

                    vert = mesh.vertices[loop.vertex_index]
                    uv = uv_layer[loop_index].uv
                    norm = loop.normal

                    # write the vertex data next
                    # Z-up to Y-up conversion for geometry
                    scenebin.write(struct.pack("<fff", vert.co.x, vert.co.z, vert.co.y))
                    # Flip V coordinate (1.0 - V) for correct texture orientation
                    scenebin.write(struct.pack("<ff", uv[0], 1.0 - uv[1]))
                    scenebin.write(struct.pack("<fff", norm.x, norm.z, norm.y))

                # Then finally, DON'T write the index data (yet)
                # scenebin.write(struct.pack("<fff", indices[0], indices[1], indices[2]))

        # now i will extract the lights
        # they will need to be offset by the total size of all meshes
        # or... can't i just write it directly to the binary after the mesh loop? LOL! only READING cares about offsets,
        for light in bpy.data.lights:
            # zeroed out positions because these positions are set by the objects themselves. These zeroes are just placeholders

            match light.type:
                case "SUN":
                    sun_light: SunLight = light #type: ignore

                    scenebin.write(struct.pack("<ffff", 1, sun_light.use_shadow, 0.0, 0.0)) # header - 0.0s are for padding
                    scenebin.write(struct.pack("<ffff", 0.0, 0.0, 0.0, sun_light.cutoff_distance))
                    scenebin.write(struct.pack("<ffff", point_light.color.r, sun_light.color.g, sun_light.color.b, sun_light.energy * 8))

                case "POINT":
                    point_light: PointLight = light #type: ignore

                    scenebin.write(struct.pack("<ffff", 2, point_light.use_shadow, 0.0, 0.0)) # header - 0.0s are for padding
                    scenebin.write(struct.pack("<ffff", 0.0, 0.0, 0.0, point_light.cutoff_distance))
                    scenebin.write(struct.pack("<ffff", point_light.color.r, point_light.color.g, point_light.color.b, point_light.energy * 8))

                case "SPOT":
                    spot_light: SpotLight = light #type: ignore

                    scenebin.write(struct.pack("<ffff", 3, light.use_shadow, 0.0, 0.0))
                    scenebin.write(struct.pack("<ffff", 0.0, 0.0, 0.0, spot_light.cutoff_distance))
                    scenebin.write(struct.pack("<ffff", spot_light.color.r, spot_light.color.g, spot_light.color.b, spot_light.energy * 8))

            # the light struct in my fragment shader (though i think this will be redesigned a little bit
            # vec4 positionRange;    // xyz = position, w = range
            # vec4 colorIntensity;   // xyz = color, w = intensity
            # vec4 properties; // x = uses shadows, yzw = unassigned for now (maybe later these can be packed better into shadow properties)




if __name__ == "__main__":
    # Blender arguments are separated from script arguments by '--'
    # Example: blender file.blend --background --python script.py -- --output scene.bin

    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]  # get all args after "--"

    # Simple argument parsing
    output_path = "scene.bin"  # Default
    if argv:
        output_path = argv[0]

    print(f"Exporting scene to {output_path}...")
    write_scene(output_path)
    print("Export complete.")
