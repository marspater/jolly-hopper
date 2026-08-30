import re
import glob

def find_buttons_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'Image(systemName:' in line:
            start = max(0, i - 15)
            end = min(len(lines), i + 15)
            context = "\n".join(lines[start:end])

            # If there is a Button but no .help and no .accessibilityLabel
            if 'Button' in context and '.help' not in context and '.accessibilityLabel' not in context:
                # also ensure it's not a Label inside a Button where text is visible.
                if 'Text(' not in context and 'Label(' not in context:
                    print(f"Match in {filepath} at line {i+1}:\n{line.strip()}\n")

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_without_a11y(f)
