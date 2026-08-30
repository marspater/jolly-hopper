import re
import glob

def find_buttons_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Look for Button { ... } or Button(action: ...) { ... }
    # Let's just find "Image(systemName:"

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'Image(systemName:' in line:
            # check backwards for Button
            start = max(0, i - 15)
            end = min(len(lines), i + 15)
            context = "\n".join(lines[start:end])

            if 'Button' in context and '.accessibilityLabel' not in context:
                print(f"Match in {filepath} at line {i+1}:\n{line.strip()}\n")

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_without_a11y(f)
