import re
import glob

def process_file(filepath):
    with open(filepath, 'r') as f:
        lines = f.read().split('\n')

    modified = False

    i = 0
    while i < len(lines):
        line = lines[i]

        match = re.search(r'^\s*\.help\((.*)\)', line)
        if match:
            # Let's see if the next line is .accessibilityLabel
            if i + 1 < len(lines) and '.accessibilityLabel' not in lines[i+1]:
                indent = line[:len(line) - len(line.lstrip())]
                new_line = f'{indent}.accessibilityLabel({match.group(1)})'
                lines.insert(i + 1, new_line)
                modified = True
                i += 1
        i += 1

    if modified:
        with open(filepath, 'w') as f:
            f.write('\n'.join(lines))
        print(f"Fixed missing accessibility labels in {filepath}")

for f in glob.glob('Siphon/Views/**/*.swift', recursive=True):
    process_file(f)
