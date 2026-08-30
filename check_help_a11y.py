import re
import glob

def find_buttons_with_help_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if '.help(' in line:
            # Let's see the context
            start = max(0, i - 15)
            end = min(len(lines), i + 15)
            context = "\n".join(lines[start:end])

            # if we find .help but no .accessibilityLabel in the surrounding context
            if '.accessibilityLabel' not in context:
                print(f"File: {filepath}, Line: {i+1}")
                print(f"{context}")
                print("-" * 40)

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_with_help_without_a11y(f)
