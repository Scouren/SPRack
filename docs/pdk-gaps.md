# Gaps found on a proprietary model library

SPRack was run on a commercial HSPICE model library, on the machine where it
is installed. Nothing from that library is in this repository. Each gap below
is reproduced by a synthetic deck in `src/tests.zig` (tests named `gap: ...`,
skipped until fixed).

1. An unquoted function call as a `.param` value (`a=agauss(0,1,3)`).
2. Coupling written `K1 L1 L2 k=value`.
3. Several function definitions in one `.param`, or definitions next to values.
4. A `$` comment after a `\`-continued expression.
5. ngspice `.func` with several arguments needs commas.
6. Spectre user functions from HSPICE function definitions.
7. Binned models (`nch.1`, `nch.2`) must become one Spectre model group.
8. A subcircuit named like the model its transistor uses: Spectre resolves
   to the subcircuit; report it.
9. A parameter defined twice: accepted by HSPICE, refused by Spectre; report it.
10. `sprack project`: section names spelled differently across files, and
    Verilog-A sources not copied into the translated tree.
