#!/usr/bin/env python3
"""Bundle the web app into one self-contained HTML file (dist/therapist-copilot.html).
Useful for opening directly from disk on a computer, or dropping on any static host."""
import re, base64, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
html = (root / "index.html").read_text(encoding="utf-8")

def data_uri(path, mime):
    return "data:" + mime + ";base64," + base64.b64encode((root / path).read_bytes()).decode()

css = (root / "assets/app.css").read_text(encoding="utf-8")
html = re.sub(r'<link rel="stylesheet" href="\./assets/app\.css">', lambda m: "<style>\n" + css + "\n</style>", html)
html = html.replace('href="./assets/icons/icon-192.png"', 'href="' + data_uri("assets/icons/icon-192.png", "image/png") + '"')
html = html.replace('href="./assets/icons/apple-touch-icon.png"', 'href="' + data_uri("assets/icons/apple-touch-icon.png", "image/png") + '"')
html = re.sub(r'<link rel="manifest" href="\./manifest\.webmanifest">\n', "", html)

def inline_script(m):
    src = m.group(1)
    js = (root / src.lstrip("./")).read_text(encoding="utf-8").replace("</script", "<\\/script")
    return "<script>\n/* " + src + " */\n" + js + "\n</script>"
html = re.sub(r'<script src="(\./js/[a-z-]+\.js)"></script>', inline_script, html)
assert "src=\"./js/" not in html
out = root / "dist" / "therapist-copilot.html"
out.write_text(html, encoding="utf-8")
print("wrote", out, out.stat().st_size, "bytes")
