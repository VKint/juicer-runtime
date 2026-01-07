import struct
import sys

import bpy

# LEVEL DATA HEADER CHEAT SHEET
# 0 = Magic number (b00bface), u32
# 4 = version number (currently 0), u32 (could be 1 byte, but padded to 4 for alignment)
# 8 = number of objects, u32
# 12 = number of object properties, u32 (48, might change with custom properties)

# After that:
# Object pos (12) + object rot (16) + object sca (12) + type (4) + index (4) = 48 * number of objects
# ^ THIS IS THE SLICE FOR ALL OBJECTS IN THE SCENE!!!

# After that:
# Mesh data! Yaaaaay
# Each mesh has its own header, including:
# vertex length (u32, 4 bytes) # so the total vertex stride is 32 (bytes needed for all vertex data) * vertex len
# index buffer is removed for simplicity's sake for now
# More will be added later once I figure out the other needs
# So maybeee
# So far, after the lengths, we gotta pack the verts and indices
# They will be variables lengths, that's the tricky part
# But the lengths will be included in the headers so it's ok LOL!

def write_level(filepath):
    with open(filepath, "wb") as levelbin:
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
        magic = struct.pack('<I', 0xB00BFACE) # btw i would totally just skip hexdumping this for testing. Read directly in odin
        # btw instead of hexdumping, i should be using od. like:
        # od -t x4 -An level.bin | head -n 50

        # write the magic number first
        levelbin.write(magic) # 4 bytes
        levelbin.write(b"\x00\x00\x00\x00") # version numbah (4 bytes)

        # total number of objects
        levelbin.write(struct.pack('<I', len(bpy.context.scene.objects))) # u32, 4 bytes

        # total length of a single object's properties
        levelbin.write(struct.pack('<I', 48)) # right now it's ~~12~~ 48 lol

        # enumerating meshes and lights
        mesh_map = {mesh.name: i for i, mesh in enumerate(bpy.data.meshes)}
        light_map = {light.name: i for i, light in enumerate(bpy.data.lights)}

        # individual objects first
        for obj in bpy.context.scene.objects: # 48 bytes total (should remain that way until i introduce custom properties)
            pos = obj.location
            rot = obj.matrix_world.to_quaternion()
            sca = obj.scale
            levelbin.write(struct.pack("<fff", pos.x, pos.y, pos.z)) # 12 bytes
            print(pos.x, pos.y, pos.z)
            levelbin.write(struct.pack("<ffff", rot.w, rot.x, rot.y, rot.z)) # 16 bytes
            print(rot.w, rot.x, rot.y, rot.z)
            levelbin.write(struct.pack("<fff", sca.x, sca.y, sca.z)) # 12 bytes
            print(sca.x, sca.y, sca.z)
            match obj.type:
                case "EMPTY":
                    levelbin.write(struct.pack("<I", 0)) # type index
                    levelbin.write(struct.pack("<I", 0)) # data index (0 for no type by default)
                case "MESH":
                    levelbin.write(struct.pack("<I", 1)) # type index
                    levelbin.write(struct.pack("<I", mesh_map[obj.data.name])) # data index
                    # print("Mesh index for " + obj.name + ": " + str(mesh_map[obj.data.name]))
                case "LIGHT":
                    levelbin.write(struct.pack("<I", 2)) # type index
                    levelbin.write(struct.pack("<I", light_map[obj.data.name])) # data index
                    # print("Light index for " + obj.name + ": " + str(light_map[obj.data.name]))

        # now, i need to extract meshes
        # MESH STRIDE
        # header + header = 8 bytes
        # after that - vertex data (32 bytes each)
        # we don't be writing indices for now
        for mesh in bpy.data.meshes:
            mesh.calc_loop_triangles()

            # write the headers first
            vert_len = len(mesh.loop_triangles) * 3 # length * 3 cuz we're doing a flat array of vertices for now
            levelbin.write(struct.pack("<I", vert_len)) # 4 bytes
            # idx_len = len(indices) # mesh header #2, 4 bytes
            # levelbin.write(struct.pack("<I", idx_len))

            uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None

            for tri in mesh.loop_triangles: # iterate through polygons instead, not verts

                # init the index struct first
                # indices = []
                # indices.append(tri.vertices[0])
                # indices.append(tri.vertices[1])
                # indices.append(tri.vertices[2]) # lol whatever man, it works

                for loop_index in tri.loops: # loop to write vertex data
                    loop = mesh.loops[loop_index] # this grabs the current loop. A loop is actually the point that the GPU will consume
                    # this is some wacky for looping that I'm not used to, but let's keep going

                    vert = mesh.vertices[loop.vertex_index]
                    uv = uv_layer[loop_index].uv
                    norm = loop.normal

                    # write the vertex data next
                    levelbin.write(struct.pack("<fff", vert.co.x, vert.co.y, vert.co.z))
                    levelbin.write(struct.pack("<ff", uv[0], uv[1]))
                    levelbin.write(struct.pack("<fff", norm.x, norm.y, norm.z))

                # Then finally, DON'T write the index data (yet)
                # levelbin.write(struct.pack("<fff", indices[0], indices[1], indices[2]))


if __name__ == "__main__":
    # Blender arguments are separated from script arguments by '--'
    # Example: blender file.blend --background --python script.py -- --output level.bin

    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]  # get all args after "--"

    # Simple argument parsing
    output_path = "level.bin"  # Default
    if argv:
        output_path = argv[0]

    print(f"Exporting level to {output_path}...")
    write_level(output_path)
    print("Export complete.")
