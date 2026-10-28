"""Draw the original T02 Studio icon and all platform sizes (requires Pillow)."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1] / 'apps/t02_demo'
image = Image.new('RGB', (1024, 1024), '#202922')
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((304, 186, 720, 464), radius=24, fill='#f5f3ec')
draw.rounded_rectangle((170, 357, 854, 712), radius=92, fill='#72977c')
draw.ellipse((745, 420, 779, 454), fill='#f5f3ec')
draw.rounded_rectangle((280, 560, 744, 610), radius=20, fill='#202922')
draw.polygon([(307, 584), (717, 584), (717, 844), (676, 819), (635, 844), (594, 819), (553, 844), (512, 819), (471, 844), (430, 819), (389, 844), (348, 819), (307, 844)], fill='#f5f3ec')
for y, end in [(655, 650), (711, 600), (767, 650)]:
    draw.rounded_rectangle((370, y, end, y+15), radius=7, fill='#202922')
for platform in ('ios', 'macos'):
    folder = root/platform/'Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((folder/'Contents.json').read_text())['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        image.resize((size, size), Image.Resampling.LANCZOS).save(folder/entry['filename'])
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    image.resize((size, size), Image.Resampling.LANCZOS).save(root/'android/app/src/main/res'/f'mipmap-{density}'/'ic_launcher.png')
