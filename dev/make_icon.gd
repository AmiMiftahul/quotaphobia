extends SceneTree
## Rebuilds every icon size from assets/icon/icon.svg. Run from the project folder:
## tools/Godot.app/Contents/MacOS/Godot --headless --script dev/make_icon.gd -- <iconset folder> <preview.png>


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var root := OS.get_environment("PWD")
	var svg := FileAccess.get_file_as_string(root.path_join("assets/icon/icon.svg"))
	render(svg, 256).save_png(root.path_join("assets/icon/icon.png"))
	var iconset: String = args[0]
	DirAccess.make_dir_recursive_absolute(iconset)
	var sizes := {
		"icon_16x16": 16, "icon_16x16@2x": 32, "icon_32x32": 32, "icon_32x32@2x": 64,
		"icon_128x128": 128, "icon_128x128@2x": 256, "icon_256x256": 256, "icon_256x256@2x": 512,
		"icon_512x512": 512, "icon_512x512@2x": 1024,
	}
	for file_name: String in sizes:
		render(svg, sizes[file_name]).save_png(iconset.path_join(file_name + ".png"))
	# A sheet showing each size at actual pixels, on light and dark, to judge small sizes.
	var sheet := Image.create(1000, 640, false, Image.FORMAT_RGBA8)
	sheet.fill_rect(Rect2i(0, 0, 1000, 320), Color(0.92, 0.92, 0.94))
	sheet.fill_rect(Rect2i(0, 320, 1000, 320), Color(0.12, 0.12, 0.14))
	for row in 2:
		var x := 20
		for size: int in [256, 128, 64, 48, 32, 24, 16]:
			sheet.blend_rect(render(svg, size), Rect2i(0, 0, size, size), Vector2i(x, row * 320 + 32))
			x += size + 24
	sheet.save_png(args[1])
	quit()


func render(svg: String, size: int) -> Image:
	var image := Image.new()
	image.load_svg_from_string(svg, size / 1024.0)
	image.convert(Image.FORMAT_RGBA8)
	return image
