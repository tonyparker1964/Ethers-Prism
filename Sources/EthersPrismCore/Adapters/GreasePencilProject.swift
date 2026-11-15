import Foundation

/// Starts an editable project from Blender's own 2D Animation template.
public enum GreasePencilProject {
    public static func arguments(for project: URL, script: URL, reference: URL?, movie: URL) -> [String] {
        ["--factory-startup", "--app-template", "2D_Animation", "--python-exit-code", "1",
         "--python", script.path, "--", project.path, reference?.path ?? "", movie.path]
    }

    public static func walkScript(poses: [URL]) throws -> String {
        let paths = try JSONEncoder().encode(poses.map(\.path)).base64EncodedString()
        let payload = "import base64, json\nposes = json.loads(base64.b64decode('\(paths)'))\n"
        return payload + setupScript.replacingOccurrences(
            of: "bpy.ops.wm.save_as_mainfile(filepath=project)", with: walkAnimation + "\nbpy.ops.wm.save_as_mainfile(filepath=project)")
    }

    private static let walkAnimation = #"""
# Align all poses to one camera-facing plane and preserve their shared canvas.
if not camera or camera.data.type != 'ORTHO':
    raise ValueError("An orthographic 2D Animation camera is required.")
bounds = camera.data.view_frame(scene=scene)
width = max(v.x for v in bounds) - min(v.x for v in bounds)
height = max(v.y for v in bounds) - min(v.y for v in bounds)
distance = (camera.location - scene.cursor.location).length
root = bpy.data.objects.new("Walk Across", None)
scene.collection.objects.link(root)
root.matrix_world = camera.matrix_world.copy()
root.location = camera.matrix_world @ Vector((0, 0, -distance))
images = [bpy.data.images.load(path) for path in poses]
if any(tuple(image.size) != tuple(images[0].size) for image in images):
    raise ValueError("All walk poses must have the same canvas size.")
aspect = images[0].size[0] / images[0].size[1]
half_width = min(width * 0.18, height * 0.28 * aspect)
half_height = half_width / aspect
objects = []
for index, image in enumerate(images):
    image.pack()
    name = f"Pose {index + 1:02d}"
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(-half_width, -half_height, 0), (half_width, -half_height, 0),
                      (half_width, half_height, 0), (-half_width, half_height, 0)], [], [(0, 1, 2, 3)])
    for loop, uv in zip(mesh.uv_layers.new().data, [(0, 0), (1, 0), (1, 1), (0, 1)]):
        loop.uv = uv
    pose = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(pose)
    pose.parent = root
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    mesh.materials.append(material)
    nodes, links = material.node_tree.nodes, material.node_tree.links
    texture = nodes.new('ShaderNodeTexImage')
    texture.image = image
    emission = nodes.new('ShaderNodeEmission')
    links.new(texture.outputs['Color'], emission.inputs['Color'])
    mix = nodes.new('ShaderNodeMixShader')
    links.new(texture.outputs['Alpha'], mix.inputs[0])
    links.new(nodes.new('ShaderNodeBsdfTransparent').outputs[0], mix.inputs[1])
    links.new(emission.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], nodes.get('Material Output').inputs['Surface'])
    objects.append(pose)

render.fps = 24
render.fps_base = 1
scene.frame_start, scene.frame_end = 1, 96
axis = camera.matrix_world.to_quaternion() @ Vector((1, 0, 0))
center = root.location.copy()
for frame in range(1, 97):
    progress = (frame - 1) / 95
    root.location = center + axis * ((progress - 0.5) * width * 0.6)
    root.keyframe_insert('location', frame=frame)
    visible = ((frame - 1) // 3) % len(objects)
    for index, pose in enumerate(objects):
        pose.hide_render = pose.hide_viewport = index != visible
        pose.keyframe_insert('hide_render', frame=frame)
        pose.keyframe_insert('hide_viewport', frame=frame)
scene.frame_set(1)
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == 'VIEW_3D':
            area.spaces.active.region_3d.view_perspective = 'CAMERA'
            area.spaces.active.shading.type = 'MATERIAL'
"""#

    public static let setupScript = #"""
import bpy
import sys
from mathutils import Vector

project, reference, movie = sys.argv[sys.argv.index('--') + 1:]
scene = bpy.context.scene
camera = scene.camera

if reference:
    image = bpy.data.images.load(reference, check_existing=True)
    image.pack()
    # Display the reference in the drawing viewport, behind the drawing.
    guide = bpy.data.objects.new("Drawing Reference", None)
    guide.empty_display_type = 'IMAGE'
    guide.data = image
    guide.empty_image_depth = 'BACK'
    guide.color[3] = 0.5
    guide.use_empty_image_alpha = True
    scene.collection.objects.link(guide)
    guide.rotation_euler = camera.rotation_euler
    distance = (camera.location - scene.cursor.location).length
    guide.location = camera.matrix_world @ Vector((0, 0, -distance))
    bounds = camera.data.view_frame(scene=scene)
    frame_width = max(v.x for v in bounds) - min(v.x for v in bounds)
    frame_height = max(v.y for v in bounds) - min(v.y for v in bounds)
    ratio = image.size[0] / max(image.size[1], 1)
    guide.empty_display_size = min(max(frame_width, frame_height), frame_width * max(1, 1 / ratio),
                                   frame_height * max(1, ratio))
    guide.hide_select = True

render = scene.render
render.filepath = movie
if hasattr(render.image_settings, 'media_type'):
    render.image_settings.media_type = 'VIDEO'
render.image_settings.file_format = 'FFMPEG'
render.ffmpeg.format = 'MPEG4'
render.ffmpeg.codec = 'H264'
bpy.ops.wm.save_as_mainfile(filepath=project)
"""#
}
