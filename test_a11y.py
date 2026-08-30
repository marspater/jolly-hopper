import os
import glob

def check_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    for i in range(len(lines)):
        # Look for Button without Text but with Image
        if "Button {" in lines[i] or "Button(action:" in lines[i]:
            start = i
            end = min(i + 25, len(lines))
            chunk = "\n".join(lines[start:end])

            # Simple heuristic:
            if "Image(systemName:" in chunk and "Text(" not in chunk:
                if ".accessibilityLabel" not in chunk:
                    print(f"File {filepath} line {i+1} has an icon-only button without .accessibilityLabel")

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    check_file(f)
