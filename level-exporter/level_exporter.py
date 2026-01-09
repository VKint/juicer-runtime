import struct
import sys
import os
import shutil

import bpy
import bmesh
from bpy.types import PointLight, SpotLight, SunLight, ShaderNodeTexImage

# =============================================================================
# CONSTANTS & MAPPINGS
# =============================================================================

FILTER_MAP = {
    "Closest": 0,  # Nearest
    "Linear": 1,  # Linear
    "Cubic": 1,  # Fallback to Linear for now
    "Smart": 1,  # Fallback
}

WRAP_MAP = {
    "REPEAT": 0,  # Repeat
    "EXTEND": 1,  # Clamp to Edge
    "CLIP": 2,  # Clamp to Border (or Edge)
    "MIRROR": 0,  # Mirror (Fallback to Repeat if not supported)
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================


def get_material_info(mesh, mat_idx):
    """
    Extracts texture/sampler info AND normal map info.
    Returns: (base_color_path, base_color_sampler, normal_path, normal_sampler)
    """
    if mat_idx < 0 or mat_idx >= len(mesh.materials):
        return None, None, None, None

    mat = mesh.materials[mat_idx]
    if not mat or not mat.use_nodes:
        return None, None, None, None

    bsdf = None
    for node in mat.node_tree.nodes:
        if node.type == "BSDF_PRINCIPLED":
            bsdf = node
            break
    if not bsdf:
        return None, None, None, None

    # --- Helper to extract info from a socket ---
    def extract_from_socket(socket_name):
        socket = bsdf.inputs.get(socket_name)
        if not socket or not socket.links:
            return None, None

        # Walk up the chain to find the Image Texture
        # (Handle Normal Map nodes which sit between texture and BSDF)
        node = socket.links[0].from_node

        if node.type == "NORMAL_MAP":
            if not node.inputs["Color"].links:
                return None, None
            node = node.inputs["Color"].links[0].from_node

        if not isinstance(node, ShaderNodeTexImage) or not node.image:
            return None, None

        if not node.image.filepath:
            return None, None

        abs_path = bpy.path.abspath(node.image.filepath)
        if not os.path.exists(abs_path):
            print(f"WARNING: Texture missing: {abs_path}")
            return None, None

        interp = node.interpolation
        ext = node.extension

        # Force Normal Maps to Linear (Non-Color Data) usually,
        # but Blender nodes usually handle this setting.
        # We'll trust the node settings for now.

        min_f = FILTER_MAP.get(interp, 1)
        mag_f = FILTER_MAP.get(interp, 1)
        w_u = WRAP_MAP.get(ext, 0)
        w_v = WRAP_MAP.get(ext, 0)

        return abs_path, (min_f, mag_f, w_u, w_v)

    # 1. Base Color
    bc_path, bc_samp = extract_from_socket("Base Color")

    # 2. Normal
    norm_path, norm_samp = extract_from_socket("Normal")

    return bc_path, bc_samp, norm_path, norm_samp


def write_scene(filepath):
    # ... (Setup code remains same) ...
    out_dir = os.path.dirname(os.path.abspath(filepath))
    tex_dir = os.path.join(out_dir, "textures")
    if not os.path.exists(tex_dir):
        os.makedirs(tex_dir)

    unique_textures = []
    unique_samplers = []
    texture_map = {}
    sampler_map = {}

    def get_tex_id(path):
        if not path:
            return -1
        if path not in texture_map:
            texture_map[path] = len(unique_textures)
            unique_textures.append(path)
        return texture_map[path]

    def get_samp_id(conf):
        if not conf:
            return -1
        if conf not in sampler_map:
            sampler_map[conf] = len(unique_samplers)
            unique_samplers.append(conf)
        return sampler_map[conf]

    print(f"Exporting scene to {filepath}...")

    with open(filepath, "wb") as f:
        # 1. HEADER (32 bytes)
        f.write(struct.pack("<I", 0xB00BFACE))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 48))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 0))

        # 2. OBJECTS
        mesh_map = {mesh.name: i for i, mesh in enumerate(bpy.data.meshes)}
        light_map = {light.name: i for i, light in enumerate(bpy.data.lights)}

        for obj in bpy.context.scene.objects:
            pos = obj.location
            rot = obj.matrix_world.to_quaternion()
            sca = obj.scale
            f.write(struct.pack("<fff", pos.x, pos.z, pos.y))
            f.write(struct.pack("<ffff", rot.w, rot.x, rot.z, rot.y))
            f.write(struct.pack("<fff", sca.x, -sca.z, -sca.y))

            t_idx, d_idx = 0, 0
            if obj.type == "MESH":
                t_idx, d_idx = 1, mesh_map.get(obj.data.name, 0)
            elif obj.type == "LIGHT":
                t_idx, d_idx = 2, light_map.get(obj.data.name, 0)
            f.write(struct.pack("<II", t_idx, d_idx))

        # 3. MESHES
        for original_mesh in bpy.data.meshes:
            # COPY & TRIANGULATE
            mesh = original_mesh.copy()
            bm = bmesh.new()
            bm.from_mesh(mesh)
            bmesh.ops.triangulate(
                bm, faces=list(bm.faces), quad_method="BEAUTY", ngon_method="BEAUTY"
            )
            bm.to_mesh(mesh)
            bm.free()

            # CALCULATE TANGENTS
            mesh.calc_loop_triangles()
            has_tangents = False
            if mesh.uv_layers:
                try:
                    mesh.calc_tangents(uvmap=mesh.uv_layers[0].name)
                    has_tangents = True
                except Exception as e:
                    print(f"Warning: Tangents failed for {mesh.name}: {e}")

            buckets = {}
            if not mesh.loop_triangles:
                bpy.data.meshes.remove(mesh)
                f.write(struct.pack("<I", 0))
                continue

            for tri in mesh.loop_triangles:
                m_idx = tri.material_index
                if m_idx not in buckets:
                    buckets[m_idx] = []
                buckets[m_idx].append(tri)

            f.write(struct.pack("<I", len(buckets)))

            uv_layer = mesh.uv_layers[0].data if mesh.uv_layers else None

            for m_idx, triangles in buckets.items():
                bc_path, bc_samp, nm_path, nm_samp = get_material_info(mesh, m_idx)

                # Resolve Indices
                bc_tex_id = get_tex_id(bc_path)
                bc_samp_id = get_samp_id(bc_samp)
                nm_tex_id = get_tex_id(nm_path)
                nm_samp_id = get_samp_id(nm_samp)

                vert_count = len(triangles) * 3

                # Primitive Header: Verts, BC_Tex, BC_Samp, NM_Tex, NM_Samp (New!)
                # Structure: <Iiiii (20 bytes)
                f.write(
                    struct.pack(
                        "<Iiiii",
                        vert_count,
                        bc_tex_id,
                        bc_samp_id,
                        nm_tex_id,
                        nm_samp_id,
                    )
                )

                for tri in triangles:
                    for loop_idx in tri.loops:
                        loop = mesh.loops[loop_idx]
                        vert = mesh.vertices[loop.vertex_index]
                        norm = loop.normal
                        uv = uv_layer[loop_idx].uv if uv_layer else [0.0, 0.0]

                        # Tangent (4 floats)
                        tangent = [1.0, 0.0, 0.0, 1.0]
                        if has_tangents:
                            t = loop.tangent
                            tangent = [
                                t.x,
                                t.z,
                                t.y,
                                loop.bitangent_sign,
                            ]  # Swap Y/Z for coordinate system

                        # WRITE VERTEX (48 Bytes)
                        # Pos
                        f.write(struct.pack("<fff", vert.co.x, vert.co.z, vert.co.y))
                        # UV
                        f.write(struct.pack("<ff", uv[0], 1.0 - uv[1]))
                        # Normal
                        f.write(struct.pack("<fff", norm.x, norm.z, norm.y))
                        # Tangent
                        f.write(
                            struct.pack(
                                "<ffff", tangent[0], tangent[1], tangent[2], tangent[3]
                            )
                        )

            # Clean up temp mesh
            bpy.data.meshes.remove(mesh)

        # 4. LIGHTS (Unchanged)
        for light in bpy.data.lights:
            # ... (Copied logic from before for brevity, assumed standard lights) ...
            match light.type:
                case "SUN":
                    l: SunLight = light  # type: ignore
                    f.write(struct.pack("<ffff", 1, l.use_shadow, 0, 0))
                    f.write(struct.pack("<ffff", 0, 0, 0, 1000.0))
                    f.write(
                        struct.pack("<ffff", l.color.r, l.color.g, l.color.b, l.energy)
                    )
                case "POINT":
                    l: PointLight = light  # type: ignore
                    f.write(struct.pack("<ffff", 2, l.use_shadow, 0, 0))
                    f.write(struct.pack("<ffff", 0, 0, 0, l.cutoff_distance))
                    f.write(
                        struct.pack(
                            "<ffff", l.color.r, l.color.g, l.color.b, l.energy * 8
                        )
                    )
                case "SPOT":
                    l: SpotLight = light  # type: ignore
                    f.write(struct.pack("<ffff", 3, l.use_shadow, 0, 0))
                    f.write(struct.pack("<ffff", 0, 0, 0, l.cutoff_distance))
                    f.write(
                        struct.pack(
                            "<ffff", l.color.r, l.color.g, l.color.b, l.energy * 8
                        )
                    )
                case _:
                    f.write(struct.pack("<ffff", 0, 0, 0, 0))
                    f.write(struct.pack("<ffff", 0, 0, 0, 0))
                    f.write(struct.pack("<ffff", 0, 0, 0, 0))

        # 5. SAMPLERS
        for s in unique_samplers:
            f.write(struct.pack("<BBBB", s[0], s[1], s[2], s[3]))

        # 6. TEXTURES
        print(f"Writing {len(unique_textures)} Textures...")
        for abs_path in unique_textures:
            filename = os.path.basename(abs_path)
            src_ext = os.path.splitext(filename)[1].lower()

            # Target filename (force PNG for unsupported types like EXR)
            is_supported = src_ext in [".png", ".jpg", ".jpeg", ".tga", ".bmp"]
            if not is_supported:
                filename = os.path.splitext(filename)[0] + ".png"

            path_bytes = filename.encode("utf-8")
            f.write(struct.pack("<I", len(path_bytes)))
            f.write(path_bytes)

            dst_path = os.path.join(tex_dir, filename)

            if is_supported:
                # Direct Copy
                try:
                    shutil.copy2(abs_path, dst_path)
                except shutil.SameFileError:
                    pass
                except Exception as e:
                    print(f"Error copying texture {filename}: {e}")
            else:
                # Convert via Blender
                print(f"Converting {src_ext} to PNG: {filename}")
                try:
                    # Find the image block
                    img = next(
                        (
                            i
                            for i in bpy.data.images
                            if bpy.path.abspath(i.filepath) == abs_path
                        ),
                        None,
                    )
                    if img:
                        # Save current state
                        old_path = img.filepath
                        old_format = img.file_format

                        # Configure for export
                        img.filepath_raw = dst_path
                        img.file_format = "PNG"
                        img.save()

                        # Restore state
                        img.filepath = old_path
                        img.file_format = old_format
                    else:
                        print(f"ERROR: Could not find loaded image for {abs_path}")
                except Exception as e:
                    print(f"Error converting texture {filename}: {e}")

        # 7. FINAL HEADER
        f.seek(0)
        f.write(struct.pack("<I", 0xB00BFACE))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", len(bpy.context.scene.objects)))
        f.write(struct.pack("<I", 48))
        f.write(struct.pack("<I", len(bpy.data.meshes)))
        f.write(struct.pack("<I", len(bpy.data.lights)))
        f.write(struct.pack("<I", len(unique_textures)))
        f.write(struct.pack("<I", len(unique_samplers)))

        print(
            f"Export Complete. {len(unique_textures)} Textures, {len(unique_samplers)} Samplers."
        )


if __name__ == "__main__":
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]

    output_path = "scene.bin"
    if argv:
        output_path = argv[0]

    write_scene(output_path)
