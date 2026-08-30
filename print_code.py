import sys
filepath = sys.argv[1]
line_num = int(sys.argv[2])
with open(filepath, 'r') as f:
    lines = f.read().split('\n')
    start = max(0, line_num - 1 - 5)
    end = min(len(lines), line_num - 1 + 20)
    for i in range(start, end):
        print(f"{i+1}: {lines[i]}")
