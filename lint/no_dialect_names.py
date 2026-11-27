"""The engine knows no dialect: no source file names one in a string.

    python3 -I lint/no_dialect_names.py <grammars-dir> <file.zig or directory>...

A dialect is a `grammars/<name>.spgrammar` file, and what one simulator
means and another does not is a line of its grammar. A string literal that
is a dialect's name, in code that is not a test, is a special case written
in Zig: it is refused here. Tests name dialects freely: a `test` block, a
file named `tests.zig`, or a line marked `// tidy: allow(dialect-name) reason`.
"""

import os
import re
import sys

STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def dialects(directory):
    return {name[: -len(".spgrammar")] for name in os.listdir(directory) if name.endswith(".spgrammar")}


def findings(path, names):
    in_test = False
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            if re.match(r"test\b", line):
                in_test = True
            elif in_test and line.startswith("}"):
                in_test = False
                continue
            code = line.split("//")[0]
            if in_test or "tidy: allow(dialect-name)" in line:
                continue
            for text in STRING.findall(code):
                if text.lower() in names:
                    yield number, text


def sources(paths):
    for path in paths:
        if not os.path.isdir(path):
            yield path
            continue
        for directory, _, files in sorted(os.walk(path)):
            for name in sorted(files):
                if name.endswith(".zig") and name != "tests.zig":
                    yield os.path.join(directory, name)


def main():
    names = dialects(sys.argv[1])
    bad = 0
    for path in sources(sys.argv[2:]):
        for number, text in findings(path, names):
            print(f'{path}:{number}: error: [dialect-name] "{text}" names a dialect: '
                  "say what it means in its grammar, and read that here")
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
