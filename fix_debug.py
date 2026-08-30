import re

filepath = 'Siphon/Views/DebugLogView.swift'
with open(filepath, 'r') as f:
    lines = f.read().split('\n')

for i in range(len(lines)):
    if 'Image(systemName: "xmark")' in lines[i]:
        # we need to insert .accessibilityLabel
        for j in range(i, i+15):
            if '.keyboardShortcut' in lines[j]:
                lines.insert(j, '                .accessibilityLabel("Close")')
                break
        break

with open(filepath, 'w') as f:
    f.write('\n'.join(lines))
