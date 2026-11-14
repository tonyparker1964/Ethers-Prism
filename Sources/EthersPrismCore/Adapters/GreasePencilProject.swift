import Foundation

/// Starts an editable project from Blender's own 2D Animation template.
public enum GreasePencilProject {
    public static func arguments(for project: URL, script: URL, reference: URL?, movie: URL) -> [String] {
        ["--factory-startup", "--app-template", "2D_Animation", "--python-exit-code", "1",
         "--python", script.path, "--", project.path, reference?.path ?? "", movie.path]
    }

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
