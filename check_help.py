import re
import glob

def find_buttons_with_help_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # We want to find `.help("...")` applied to an Image or Button, but no `.accessibilityLabel("...")`
    # Let's search for `.help`

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if '.help(' in line:
            start = max(0, i - 15)
            end = min(len(lines), i + 15)
            context = "\n".join(lines[start:end])

            if '.accessibilityLabel' not in context and 'Image(' in context:
                print(f"File: {filepath}, Line: {i+1}")
                print(f"{context}")
                print("-" * 40)

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_with_help_without_a11y(f)
