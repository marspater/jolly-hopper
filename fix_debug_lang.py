import re

filepath = 'Siphon/Views/DebugLogView.swift'
with open(filepath, 'r') as f:
    content = f.read()

content = content.replace('.accessibilityLabel(LanguageService.shared.s("close"))', '.accessibilityLabel("Close")')

with open(filepath, 'w') as f:
    f.write(content)
