# Native GS vs wine GS — measured

Both game servers pass the same stress test. This is what they cost, measured on one host under
identical conditions.

## Where and how

Benchmark host: Synology `opslagbeest`, AMD Ryzen Embedded V1500B, 8 cores, 32 GB, kernel 4.4
(cgroup v1), Docker 24.0.2. x86_64 with 32-bit support, so **both** containers run natively —
neither side is emulated. On the arm64 developer Mac the comparison is impossible, so no number
here comes from that machine.

The realm stays on the Mac and both variants face the same path:

    clientless (Mac) -> realmd bnet :6222 (Mac) -> qqserver :4200 (Mac) -> GS :4000 (NAS)

The GS registers over gs-link to the Mac and advertises `10.24.1.141:4000`. Without
`D2GS_GS_ADDR` the native GS advertises `127.0.0.1:4000` — qqserver's own port — and every round
fails `MCP_CREATEGAME result=0x20`.

Workload: `run-stress.sh` at its default, 20 rounds x 2 clients, one game at a time.

Sampling, identical for both, from the container's cgroup so the whole process tree counts:

| what | source | interval |
|-|-|-|
| CPU | `cpuacct.usage` (ns), as `dcpu/dwall` = % of one core | 1 s |
| memory | `memory.stat` `total_rss` / `total_cache`, `memory.max_usage_in_bytes` | 1 s |
| processes / threads | `cgroup.procs` / `tasks` line count | 1 s |
| file descriptors | `/proc/<pid>/fd` via a privileged `--pid=host` helper | 2 snapshots |

Phases: 60 s idle, the full stress run, 60 s settle. Two independent passes per variant; both
passes are reported so the numbers can be challenged.

fds are snapshots, not a series — the ssh user cannot read root-owned `/proc`, so it needs a
helper container and that is too heavy to run every second.

## Result

Both variants: **20/20 rounds clean**, both passes.

| metric | native | wine |
|-|-|-|
| CPU idle (% of one core) | 0.22 / 0.22 | 0.64 / 0.64 |
| CPU during run | 0.73 / 0.73 | 1.52 / 1.52 |
| RSS idle | 21.9 / 21.6 MiB | 95.7 / 95.2 MiB |
| RSS peak during run | 23.1 / 22.8 MiB | 99.0 / 98.3 MiB |
| RSS after settle | 23.0 / 22.7 MiB | 96.5 / 95.7 MiB |
| processes | 1 | 10 |
| threads | 6 | 48 |
| file descriptors (idle / after) | 13 / 13 | 524 / 524 |
| stress wall clock | 84.0 / 85.7 s | 73.4 / 74.0 s |
| mean round | 4.15 / 4.20 s | 3.65 / 3.50 s |
| games hosted concurrently | 1 | 7 |

Native is ~2.1x cheaper on CPU under load, ~4.3x smaller resident, one process instead of ten,
and 40x fewer descriptors. Neither leaks: RSS and fds return to their starting values.

**Wine wins on latency.** It finishes the same 20 rounds 12-14% faster (3.5-3.65 s per round
against 4.15-4.20 s), reproducibly across both passes. Wine also hosts seven concurrent games
where the native build hosts exactly one — the Mac image's QSERVER has a single game pointer
(`QSERVER_GenerateGameToken` clamps its counter to 1), so that is architectural, not a tuning
knob. For a fleet, seven games on ~96 MiB beats one game on ~22 MiB per unit of capacity.

## Where the latency difference actually is

The round times above were taken with `date +%s`. A round is about four seconds, so every sample
was quantised by a quarter of itself and the 12-14% gap was mostly rounding. `run-stress.sh` now
times rounds in milliseconds.

It does not subtract the dwell, though the first version of this did. The dwell is not a floor the
round sits on: a client starts its dwell clock when it sends 0x6b, so the world arrives during it
— at `--dwell 0` the client leaves before the world does and every round fails — and a longer
dwell also gives the previous game more time to be reaped, which shortens the next create. On one
server "round minus dwell" was 2.05 s at `--dwell 1` and 1.40 s at `--dwell 3`. A quantity that
moves when you change what you subtract is not the server's time. Compare rounds, at one dwell.

Re-measured that way, both variants in Docker on one arm64 Mac — so both i386 images run under the
same `qemu-i386`, which is slower than either would be on real hardware but slower for both:

| metric | native | wine |
|-|-|-|
| rounds clean | 20/20 | 20/20 |
| mean round | 4.40 s | 3.64 s |
| median round | 4.35 s | 3.58 s |
| wall clock | 88.17 s | 72.85 s |
| container RSS idle | 21.3 MiB | 296.1 MiB |
| container RSS peak | 32.1 MiB | 300.0 MiB |

The wine RSS here is not comparable to the 96 MiB measured on the NAS — this container carries
Xvfb and a different base, and everything is under emulation. Only the two columns are comparable
to each other, and only within this table.

The native server logs how long each create waited for its one game slot. Over those 20 rounds:
min 4 ms, median 704 ms, mean 742 ms, max 1785 ms, **total 14.85 s** — and the whole run was
15.3 s slower than wine's. The gap is not general slowness; it is one queue.

It is a queue because this build hosts one game (see `max_games` in
`apps/d2gs-native/gslink.zig`). Round N+1's create arrives while round N's game still has clients,
so it blocks until the engine has counted them gone and destroyed the game. Wine has seven slots
and never queues. Two intervals make up the wait, and only the second is ours: the engine takes
~350 ms per departing client to notice the socket is gone, and 79 ms after that to free the slot
(measured, `engine freed the slot ...ms after the game emptied`).

The per-client notice is engine work, so `qemu-i386` inflates it — which means this local run
overstates the native side's disadvantage and the number to fix against is the NAS one. Nothing
here says the queue is not real; it says its size is not yet known on real hardware.

The queue belongs to the process, not to the design. With a second native container registered and
`--spread --clients 2`, the realm placed ten games on each: the first server still queued (median
714 ms) and the second barely did (median 14 ms, mean 21 ms), because its create arrived a moment
later in the round, by which time its own previous game was already gone. So the way to spend
21 MiB on more capacity is another process, and each one carries its own slot. Throughput could
not be compared here — two emulated servers on one Mac contend for the same cores, and the run was
slower than either alone.

## The two builds do not bind the same port

The wine GS moves the engine's QServer off :4000 to whatever `D2GS_GS_ADDR` advertises
(`gsport.apply(gs_public_port)` in `apps/d2gs/d2gs.zig`). The native GS always binds 4000 — the
Mac image has the port as an immediate in `QSERVER_CreateAndInit`, and nothing patches it.

So a container publishing `-p 14000:4000` is right for the native image and wrong for wine, which
is listening on 14000 inside. The failure does not look like a port problem: `docker-proxy`
accepts the connection first and only then fails to reach the container, so the client gets a
connection that closes without a byte, and every log in between says the game was created and the
join acked. That cost an hour; it is written down so it costs nobody else one.

`memory.usage_in_bytes` reaches 1370 MiB for wine on a warm container. That is page cache
(`total_cache` 1271 MiB) from reading the 614 MB prefix and the MPQs, not the server's memory —
after a restart the same figure is 101 MiB. RSS is the honest number.

Where wine's memory goes, per process at idle:

| process | RSS | fds | threads |
|-|-|-|-|
| Xvfb | 66.7 MB | 13 | 1 |
| Game.exe | 47.1 MB | 55 | 8 |
| explorer.exe | 22.3 MB | 21 | 3 |
| winedevice.exe (x2) | 20.6 + 16.1 MB | 37 + 29 | 8 + 6 |
| services.exe | 16.5 MB | 37 | 8 |
| plugplay.exe | 15.0 MB | 21 | 4 |
| rpcss.exe | 14.3 MB | 29 | 6 |
| svchost.exe | 9.9 MB | 17 | 3 |
| wineserver32 | 7.0 MB | 265 | 1 |

(Per-process RSS double-counts shared pages; the cgroup total of ~96 MiB is authoritative.) The
game itself is the second-largest item and is within 2x of the native process. Most of the
difference is scaffolding — a virtual X server and eight wine service processes — and
`wineserver32` alone holds half the descriptors.

## Image size

Two different numbers, both legitimate, and conflating them is what produced three contradictory
figures for the same image.

| image | platform | uncompressed on disk | compressed pull | re-gzipped |
|-|-|-|-|-|
| `d2gs-native` | linux/386 | 4.39 MB | 1.66 MB | 1.64 MB |
| `d2gs-wine` (CI / ghcr) | linux/amd64 | 1.04 GB | 370.7 MB | 367.9 MB |
| `d2gs-wine386` (local) | linux/386 | 970 MB | 343.8 MB | 341.2 MB |

Uncompressed is `docker images` on the NAS, which equals the `docker history` layer sum.
Compressed pull is `docker save <img> | wc -c` — `docker save` already emits gzipped layer blobs,
so that stream *is* the registry payload plus tar framing. For the amd64 image this was
cross-checked against the exact ghcr manifest (blob sum 370,641,235 B) and agreed to 0.006%,
which is the tar overhead. Piping through `gzip -1` as well takes ~0.8% more off (it only
squeezes the tar padding, not the already-compressed blobs) and is the weaker measure of the two;
it is shown for comparison because it is the commonly quoted approximation.

**`docker images` on Docker Desktop is not either of these** — it reports compressed blobs *plus*
unpacked layers, so it roughly doubles the image:

| image | compressed | + uncompressed | Desktop shows |
|-|-|-|-|
| native | 1.66 MB | 4.39 MB | 6.04 MB |
| wine i386 | 343.8 MB | 990.6 MB | 1.33 GB |
| wine amd64 | 370.6 MB | 1058.6 MB | 1.43 GB |

The size is entirely the wine package set: 972 MB of the amd64 image is the single
`apt-get install wine wine32 curl ca-certificates xvfb` layer, 85.3 MB is the debian base, and
everything of ours is 1.29 MB. The amd64 image is *fatter* than the i386 one (972 vs 902 MB)
because on amd64 apt installs the native wine packages **and** the i386 multiarch set; on i386
there is only one architecture to install.

WINEPREFIX is 614.75 MB after init and does **not** grow: 614,753,352 bytes before and after a
20-round run. `/work` grew 837 KB -> 1.18 MB, which is the log.

## Platform note

The wine container ran as `linux/amd64`, matching both the NAS and the published CI artefact
(`.github/workflows/build.yml` builds `linux/amd64` only; the ghcr manifest digest matches the
local image). The native image is `FROM scratch` holding one static i386 ELF — there is no distro
layer, so its `linux/386` label is metadata only and the amd64 kernel executes the binary either
way. The two containers therefore differ in that label and in nothing that runs.

## Two traps found while setting this up

`testgame-min` (20 MB) **cannot boot the wine GS.** It asserts (`caller=0x6123a3 nLine=0x8e7`)
and exits `0xc0000005` just after QSERVER init, because it lacks the 176-byte stub audio/video
archives (`d2music`, `d2sfx`, `d2speech`, `d2Xmusic`, `d2Xtalk`, `d2Xvideo`). Adding them fixes
it. This is the same signature previously blamed on QEMU on the Mac — it reproduces on native
x86_64, so emulation was probably never the cause.

`deploy/gs-entrypoint.sh` does not pass `--no-compress`. Without it the GS creates the game, the
client sends GAMELOGON and then never receives `0x6b`. `run-stack.sh` passes it locally, so the
container path silently differs from the one that is tested by hand.
