import re
import glob

def find_buttons_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'Button {' in line or 'Button(action:' in line:
            start = i
            end = min(len(lines), i + 25)
            context = "\n".join(lines[start:end])

            # Check if this button is icon-only:
            # Has Image, but no Text, no Label, no .accessibilityLabel
            if 'Image(' in context and 'Text(' not in context and 'Label(' not in context and '.accessibilityLabel' not in context and '.help' not in context:
                print(f"Match in {filepath} at line {i+1}:")
                for j in range(start, end):
                    print(lines[j])
                print("-" * 40)

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_without_a11y(f)
