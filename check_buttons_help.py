import re
import glob

def find_buttons_with_help_without_a11y(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    for i, line in enumerate(lines):
        if '.help(' in line:
            start = max(0, i - 15)
            end = min(len(lines), i + 15)
            context = "\n".join(lines[start:end])

            # check if it's an icon-only button (has Image but no Text)
            if 'Image(' in context and 'Text(' not in context and '.accessibilityLabel' not in context:
                # also ensure it's not a Label where Text is passed
                if 'Label(' not in context:
                    print(f"Match in {filepath} at line {i+1}:")
                    for j in range(max(0, i - 10), min(len(lines), i + 10)):
                        print(lines[j])
                    print("-" * 40)

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    find_buttons_with_help_without_a11y(f)
