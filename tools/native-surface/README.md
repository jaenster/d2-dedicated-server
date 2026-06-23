# native-surface

Static call-graph tooling to scope the native port: which 1.14d engine functions
a headless GS actually needs. Results + writeup live in
`docs/architecture/native-surface/`.

Parses the reconstruction's `*.cpp.map` JSON sidecars (authoritative
`address` / `namespace` / `calledFunctions`), recovers the indirect-dispatch
edges Ghidra misses (skill/missile/AI/object/qserver function-pointer tables, via
`&Func` address-taken refs in the `.cpp`), seeds the closure on the `SCMD_0x*`
handlers ∪ address-taken server functions, BFS's with client/render/sound as a
cut boundary, and emits the subsystem tree + DOT.

```sh
zig build run -- --recon "$D2_RECON_SRC" --out <out-dir> [--edge-min 30]
```

- `--recon` (or `$D2_RECON_SRC`, see `.env.example`) — reconstructed source dir.
- `--out` — where outputs land: `server_tree.txt` (every fn by subsystem),
  `server_worklist.md`, `server.dot` (graph), and `server_holes.md` (referenced-
  but-absent externals / client-boundary stubs / ambiguous gaps / type surface).
- `--edge-min N` — min inter-subsystem edge weight drawn in the DOT (default 14).

Render the graph with graphviz: `dot -Tpng <out>/server.dot -o <out>/server.png`.
See the docs README for method, results, and caveats.
