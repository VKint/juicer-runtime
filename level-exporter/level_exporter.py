bl_info = {
    "name": "Juicer Exporter",
    "author": "VKInt",
    "version": (1, 2),
    "blender": (4, 0, 0),
    "location": "View3D > Sidebar > Juicer",
    "description": "Export level to Juicer Runtime format",
    "category": "Import-Export",
}

import struct
import sys
import os
import shutil
import subprocess
import datetime

import bpy
import bmesh
from bpy.types import PointLight, SpotLight, SunLight, ShaderNodeTexImage

# =============================================================================
# CONSTANTS & MAPPINGS
# =============================================================================

FILTER_MAP = {
    "Closest": 0,  # Nearest
    "Linear": 1,  # Linear
    "Cubic": 1,  # Fallback to Linear
    "Smart": 1,  # Fallback
}

WRAP_MAP = {
    "REPEAT": 0,  # Repeat
    "EXTEND": 1,  # Clamp to Edge
    "CLIP": 2,  # Clamp to Border
    "MIRROR": 0,  # Mirror
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================


def get_material_info(mesh, mat_idx):
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

    def extract_from_socket(socket_name):
        socket = bsdf.inputs.get(socket_name)
        if not socket or not socket.links:
            return None, None

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

        min_f = FILTER_MAP.get(interp, 1)
        mag_f = FILTER_MAP.get(interp, 1)
        w_u = WRAP_MAP.get(ext, 0)
        w_v = WRAP_MAP.get(ext, 0)

        return abs_path, (min_f, mag_f, w_u, w_v)

    bc_path, bc_samp = extract_from_socket("Base Color")
    norm_path, norm_samp = extract_from_socket("Normal")

    return bc_path, bc_samp, norm_path, norm_samp


def write_scene(
    filepath, export_scope="SCENE", export_textures=True, export_lights=True
):
    # Determine Objects to Export
    objects = []
    if export_scope == "SCENE":
        objects = bpy.context.scene.objects
    elif export_scope == "ACTIVE_COLLECTION":
        if bpy.context.collection:
            objects = bpy.context.collection.all_objects
        else:
            print("No active collection found.")
            return

    # Filter objects by type logic if needed (e.g. strict type checking)
    # For now we iterate all and check types in the loop.

    out_dir = os.path.dirname(os.path.abspath(filepath))
    tex_dir = os.path.join(out_dir, "textures")
    if export_textures and not os.path.exists(tex_dir):
        os.makedirs(tex_dir)

    unique_textures = []
    unique_samplers = []
    texture_map = {}
    sampler_map = {}

    def get_tex_id(path):
        if not path or not export_textures:
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
        f.write(struct.pack("<I", 0))  # Obj Count Placeholder
        f.write(struct.pack("<I", 48))
        f.write(struct.pack("<I", 0))  # Mesh Count Placeholder
        f.write(struct.pack("<I", 0))  # Light Count Placeholder
        f.write(struct.pack("<I", 0))  # Tex Count Placeholder
        f.write(struct.pack("<I", 0))  # Samp Count Placeholder

        # 2. OBJECTS
        # Collect referenced meshes and lights to only export what is used
        used_meshes = set()
        used_lights = set()

        valid_objects = []
        for obj in objects:
            if obj.type == "MESH":
                used_meshes.add(obj.data)
                valid_objects.append(obj)
            elif obj.type == "LIGHT" and export_lights:
                used_lights.add(obj.data)
                valid_objects.append(obj)
            elif obj.type == "EMPTY":
                valid_objects.append(obj)

        # Build Maps based on USED data only
        mesh_map = {mesh.name: i for i, mesh in enumerate(used_meshes)}
        light_map = {light.name: i for i, light in enumerate(used_lights)}

        for obj in valid_objects:
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
        for original_mesh in used_meshes:
            mesh = original_mesh.copy()
            bm = bmesh.new()
            bm.from_mesh(mesh)
            bmesh.ops.triangulate(
                bm, faces=list(bm.faces), quad_method="BEAUTY", ngon_method="BEAUTY"
            )
            bm.to_mesh(mesh)
            bm.free()

            mesh.calc_loop_triangles()
            has_tangents = False
            if mesh.uv_layers:
                try:
                    mesh.calc_tangents(uvmap=mesh.uv_layers[0].name)
                    has_tangents = True
                except:
                    pass

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

                bc_tex_id = get_tex_id(bc_path)
                bc_samp_id = get_samp_id(bc_samp)
                nm_tex_id = get_tex_id(nm_path)
                nm_samp_id = get_samp_id(nm_samp)

                vert_count = len(triangles) * 3
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

                        tangent = [1.0, 0.0, 0.0, 1.0]
                        if has_tangents:
                            t = loop.tangent
                            tangent = [t.x, t.z, t.y, loop.bitangent_sign]

                        f.write(struct.pack("<fff", vert.co.x, vert.co.z, vert.co.y))
                        f.write(struct.pack("<ff", uv[0], 1.0 - uv[1]))
                        f.write(struct.pack("<fff", norm.x, norm.z, norm.y))
                        f.write(
                            struct.pack(
                                "<ffff", tangent[0], tangent[1], tangent[2], tangent[3]
                            )
                        )

            bpy.data.meshes.remove(mesh)

        # 4. LIGHTS
        for light in used_lights:
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

            is_supported = src_ext in [".png", ".jpg", ".jpeg", ".tga", ".bmp"]
            if not is_supported:
                filename = os.path.splitext(filename)[0] + ".png"

            path_bytes = filename.encode("utf-8")
            f.write(struct.pack("<I", len(path_bytes)))
            f.write(path_bytes)

            if export_textures:
                dst_path = os.path.join(tex_dir, filename)
                if is_supported:
                    try:
                        shutil.copy2(abs_path, dst_path)
                    except shutil.SameFileError:
                        pass
                    except:
                        print(f"Error copying {filename}")
                else:
                    print(f"Converting {src_ext} to PNG: {filename}")
                    try:
                        img = next(
                            (
                                i
                                for i in bpy.data.images
                                if bpy.path.abspath(i.filepath) == abs_path
                            ),
                            None,
                        )
                        if img:
                            old_path = img.filepath
                            old_format = img.file_format
                            img.filepath_raw = dst_path
                            img.file_format = "PNG"
                            img.save()
                            img.filepath = old_path
                            img.file_format = old_format
                    except:
                        print(f"Error converting {filename}")

        # 7. FINAL HEADER
        f.seek(0)
        f.write(struct.pack("<I", 0xB00BFACE))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", len(valid_objects)))
        f.write(struct.pack("<I", 48))
        f.write(struct.pack("<I", len(used_meshes)))
        f.write(struct.pack("<I", len(used_lights)))
        f.write(struct.pack("<I", len(unique_textures)))
        f.write(struct.pack("<I", len(unique_samplers)))

        print(f"Export Complete. {len(valid_objects)} Objects.")


# =============================================================================
# BLENDER UI INTEGRATION
# =============================================================================


class JuicerExportSettings(bpy.types.PropertyGroup):
    export_path: bpy.props.StringProperty(
        name="Export Path",
        subtype="FILE_PATH",
        default="//scene.bin",
        description="Path to export the .bin file",
    )  # type: ignore

    juicer_runtime_path: bpy.props.StringProperty(
        name="Runtime Executable",
        subtype="FILE_PATH",
        default="",
        description="Path to the juicer executable (e.g. debug_build/game)",
    )  # type: ignore

    export_scope: bpy.props.EnumProperty(
        name="Scope",
        items=[
            ("SCENE", "Whole Scene", "Export all objects in the scene"),
            (
                "ACTIVE_COLLECTION",
                "Active Collection",
                "Export objects in the active collection",
            ),
        ],
        default="SCENE",
    )  # type: ignore

    export_textures: bpy.props.BoolProperty(name="Export Textures", default=True)  # type: ignore
    export_lights: bpy.props.BoolProperty(name="Export Lights", default=True)  # type: ignore
    export_animations: bpy.props.BoolProperty(name="Export Animations", default=False)  # type: ignore
    export_rigs: bpy.props.BoolProperty(name="Export Rigs", default=False)  # type: ignore


class JUICER_OT_export_level(bpy.types.Operator):
    bl_idname = "juicer.export_level"
    bl_label = "Export Level"
    bl_description = "Export geometry and data to Juicer .bin format"

    def execute(self, context):
        settings = context.scene.juicer_settings # type: ignore
        path = bpy.path.abspath(settings.export_path)

        try:
            write_scene(
                path,
                export_scope=settings.export_scope,
                export_textures=settings.export_textures,
                export_lights=settings.export_lights,
            )
            self.report({"INFO"}, f"Exported to {path}")
        except Exception as e:
            self.report({"ERROR"}, f"Export Failed: {str(e)}")
            return {"CANCELLED"}

        return {"FINISHED"}


class JUICER_OT_export_and_run(bpy.types.Operator):
    bl_idname = "juicer.export_and_run"
    bl_label = "Export & Run"
    bl_description = "Export level and launch Juicer Runtime"

    mode: bpy.props.EnumProperty(
        items=[("NORMAL", "Normal", ""), ("LOGGING", "With Logging", "")],
        default="NORMAL",
    )  # type: ignore

    def execute(self, context):
        # 1. Export
        bpy.ops.juicer.export_level() # type: ignore

        # 2. Run
        settings = context.scene.juicer_settings # type: ignore
        runtime_path = bpy.path.abspath(settings.juicer_runtime_path)
        scene_path = bpy.path.abspath(settings.export_path)

        if not os.path.exists(runtime_path):
            self.report({"ERROR"}, f"Runtime not found: {runtime_path}")
            return {"CANCELLED"}

        try:
            cwd = os.path.dirname(runtime_path)

            if self.mode == "NORMAL":
                # Normal Mode: Launch quietly, no terminal, no logs
                subprocess.Popen([runtime_path, scene_path], cwd=cwd)
                self.report({"INFO"}, "Juicer Runtime Launched")

            elif self.mode == "LOGGING":
                # Logging Mode: Timestamped log + Terminal + Tee
                timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
                log_filename = f"game_{timestamp}.log"
                log_path = os.path.join(cwd, log_filename)

                # Command: game scene 2>&1 | tee log; read
                # Use sh -c. Quote paths nicely.
                cmd_str = f"'{runtime_path}' '{scene_path}' 2>&1 | tee '{log_path}'; echo ''; echo 'Log saved to {log_filename}'; read -p 'Press Enter to close...'"

                try:
                    subprocess.Popen(["alacritty", "-e", "sh", "-c", cmd_str], cwd=cwd)
                    self.report({"INFO"}, f"Launched with logging: {log_filename}")
                except FileNotFoundError:
                    # Fallback
                    with open(log_path, "w") as f:
                        subprocess.Popen(
                            [runtime_path, scene_path],
                            stdout=f,
                            stderr=subprocess.STDOUT,
                            cwd=cwd,
                        )
                    self.report(
                        {"WARNING"},
                        f"Alacritty not found. Logs written to {log_filename}",
                    )

        except Exception as e:
            self.report({"ERROR"}, f"Launch Failed: {str(e)}")

        return {"FINISHED"}


class JUICER_PT_main_panel(bpy.types.Panel):
    bl_label = "Juicer Exporter"
    bl_idname = "JUICER_PT_main_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Juicer"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.juicer_settings # type: ignore

        # Config
        box = layout.box()
        box.prop(settings, "export_path")
        box.prop(settings, "juicer_runtime_path")

        # Scope
        layout.separator()
        layout.prop(settings, "export_scope")

        # Toggles
        layout.separator()
        col = layout.column(align=True)
        col.prop(settings, "export_textures")
        col.prop(settings, "export_lights")

        # Grayed out for now
        sub = col.column(align=True)
        sub.enabled = False
        sub.prop(settings, "export_animations")
        sub.prop(settings, "export_rigs")

        # Buttons
        layout.separator()
        layout.operator("juicer.export_level", icon="EXPORT")

        row = layout.row(align=True)
        row.operator("juicer.export_and_run", icon="PLAY", text="Run").mode = "NORMAL"
        row.operator(
            "juicer.export_and_run", icon="FILE_TEXT", text="Run (Log)"
        ).mode = "LOGGING"


classes = (
    JuicerExportSettings,
    JUICER_OT_export_level,
    JUICER_OT_export_and_run,
    JUICER_PT_main_panel,
)

addon_keymaps = []


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.juicer_settings = bpy.props.PointerProperty( # type: ignore
        type=JuicerExportSettings
    )

    # Add Keymaps
    wm = bpy.context.window_manager
    kc = wm.keyconfigs.addon
    if kc:
        km = kc.keymaps.new(name="3D View", space_type="VIEW_3D")

        # F4: Export Only
        kmi = km.keymap_items.new("juicer.export_level", "F4", "PRESS")
        addon_keymaps.append((km, kmi))

        # F5: Run Normal
        kmi = km.keymap_items.new("juicer.export_and_run", "F5", "PRESS")
        kmi.properties.mode = "NORMAL"
        addon_keymaps.append((km, kmi))

        # F6: Run Logging
        kmi = km.keymap_items.new("juicer.export_and_run", "F6", "PRESS")
        kmi.properties.mode = "LOGGING"
        addon_keymaps.append((km, kmi))


def unregister():
    # Remove Keymap
    for km, kmi in addon_keymaps:
        km.keymap_items.remove(kmi)
    addon_keymaps.clear()

    del bpy.types.Scene.juicer_settings # type: ignore
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    # CLI Support fallback
    # If running in background mode with arguments
    if bpy.app.background:
        argv = sys.argv
        if "--" in argv:
            argv = argv[argv.index("--") + 1 :]

        output_path = "scene.bin"
        if argv:
            output_path = argv[0]

        write_scene(output_path)
