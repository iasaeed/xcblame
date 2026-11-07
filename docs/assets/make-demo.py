"""Build docs/assets/demo.svg: an animated terminal (CSS keyframes) replaying real xcblame output
captured from the Acme* fixtures into the scratchpad (analyze.txt, doctor.txt, fix2.txt)."""
import re, sys, html

S = sys.argv[1]
OUT = sys.argv[2]
MAXC = 126


def load(name):
    with open(f"{S}/{name}", encoding="utf-8") as f:
        return f.read().splitlines()


def pick(lines, starts):
    out = []
    for st in starts:
        if st == "":
            out.append("")
            continue
        hit = next((l for l in lines if l.startswith(st)), None)
        if hit is None:
            raise SystemExit(f"missing line: {st!r}")
        out.append(hit)
    return out


def squeeze(l):
    # collapse long column padding so wide tables fit; text is unchanged
    return l if len(l) <= MAXC else l[: MAXC - 1] + "…"


analyze = pick(load("analyze.txt"), [
    "xcblame 0.6.0 · ",
    "  build   CLEAN",
    "TIME  log span",
    "      ≤ 2 lanes busy",
    "CRITICAL PATH 18.1 s",
    "   0.0– 3.7  build system",
    "   4.8– 7.5  SwiftSyntax:",
    "   8.8–11.2  explicit modules",
    "  11.2–14.2  LocalizeCore",
    "  15.2–18.1  AcmeApp",
    "TARGETS ",
    "  LocalizeCore ",
    "  SwiftSyntax ",
    "  AcmeApp ",
    "HOTSPOTS",
    "  StudioView.swift:399",
    "  StudioView.swift:8 ",
    "checks 12 pass",
])
doctor = pick(load("doctor.txt"), [
    "xcblame 0.6.0 doctor",
    "  graph ",
    "",
    "FINDINGS ",
    "  SET-001 ",
    "  SET-002 ",
    "  SET-004 ",
    "  SET-005 ",
    "  SET-010 ",
    "  SET-027 ",
    "  PHASE-001  Acme › Lint",
    "  PHASE-001  Acme › Stamp Build",
    "  PHASE-003 ",
    "  DEP-001 ",
    "  DEP-012 ",
    "",
    "PLAN  Commit your changes first",
    "      1. `xcblame verify --rules SET-001",
])
fix = pick(load("fix2.txt"), [
    "xcblame fix plan",
    "  2 steps",
    "",
    "STEPS",
    "  1. SET-004",
    "     overlay Debug: DEBUG_INFORMATION_FORMAT",
    "     risk: Breaks symbolication",
    "  2. SET-005",
    "     overlay Debug: ONLY_ACTIVE_ARCH",
    "     risk: Ignored for generic",
    "",
    "RUN",
    "  1. xcblame fix --install-hook",
    "  2. xcblame verify --rules SET-004",
    "  3. xcblame verify --rules SET-005",
    "  4. xcblame fix --rules SET-004,SET-005 --apply",
    "",
    "nothing in the project changed",
])

scenes = [
    ("xcblame analyze fixtures/logs/cli-xcode26 --index 1 --redact", analyze),
    ("xcblame doctor fixtures/projects/AcmeApp", doctor),
    ("cd AcmeFixWin && xcblame fix --rules SET-004,SET-005", fix),
]

T = 24.0          # loop length, seconds
SCENE = T / 3
FS = 12
CW = FS * 0.602   # monospace advance (Menlo/SF Mono)
LH = 17
W, H = 960, 412
X0, Y0 = 18, 64   # prompt baseline
HEADS = ("TIME", "CRITICAL PATH", "TARGETS", "HOTSPOTS", "FINDINGS", "PLAN", "STEPS", "RUN", "checks", "xcblame ")


def pct(t):
    return f"{max(0.0, min(100.0, t / T * 100)):.3f}%"


css, body = [], []
for i, (cmd, lines) in enumerate(scenes):
    s0, s1 = i * SCENE, (i + 1) * SCENE
    # scene visibility
    css.append(f"@keyframes s{i}{{0%{{opacity:0}}{pct(s0)}{{opacity:0}}{pct(s0 + 0.15)}{{opacity:1}}"
               f"{pct(s1 - 0.35)}{{opacity:1}}{pct(s1 - 0.05)}{{opacity:0}}100%{{opacity:0}}}}")
    css.append(f".s{i}{{animation:s{i} {T}s linear infinite both}}")
    # typing: a cover slides right in steps
    t0, t1 = s0 + 0.4, s0 + 0.4 + len(cmd) * 0.035
    dx = len(cmd) * CW
    css.append(f"@keyframes t{i}{{0%{{transform:translateX(0)}}{pct(t0)}{{transform:translateX(0);"
               f"animation-timing-function:steps({len(cmd)},end)}}{pct(t1)}{{transform:translateX({dx:.1f}px)}}"
               f"100%{{transform:translateX({dx:.1f}px)}}}}")
    css.append(f".t{i}{{animation:t{i} {T}s linear infinite both}}")
    cx = X0 + 2 * CW
    g = [f'<g class="s{i}">',
         f'<text x="{X0}" y="{Y0}"><tspan class="p">$</tspan> <tspan class="c">{html.escape(cmd)}</tspan></text>',
         f'<g class="t{i} cover"><rect x="{cx:.1f}" y="{Y0 - 13}" width="{W}" height="18" fill="#0F172A"/>'
         f'<rect class="cur" x="{cx:.1f}" y="{Y0 - 12}" width="{CW:.1f}" height="16" fill="#F97316"/></g>']
    ta = t1 + 0.3
    for j, line in enumerate(lines):
        if not line:
            continue
        t = ta + j * 0.07
        name = f"l{i}_{j}"
        css.append(f"@keyframes {name}{{0%{{opacity:0}}{pct(t)}{{opacity:0}}{pct(t + 0.02)}{{opacity:1}}100%{{opacity:1}}}}")
        cls = "h" if line.startswith(HEADS) else ""
        g.append(f'<text x="{X0}" y="{Y0 + 8 + (j + 1) * LH}" class="{cls}" '
                 f'style="animation:{name} {T}s linear infinite both">{html.escape(squeeze(line))}</text>')
    g.append("</g>")
    body.extend(g)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="xcblame demo: analyze a clean build, audit a project with doctor, and print a fix plan (Acme fixture projects)">
<style>
text{{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:{FS}px;fill:#E2E8F0;white-space:pre}}
.h{{fill:#FDBA74;font-weight:600}} .p{{fill:#F97316;font-weight:700}} .c{{fill:#F8FAFC;font-weight:600}}
.ttl{{fill:#94A3B8;font-size:12px}}
@keyframes blink{{50%{{opacity:0}}}} .cur{{animation:blink 1s steps(1) infinite}}
{chr(10).join(css)}
@media (prefers-reduced-motion: reduce){{*{{animation:none!important}} .s1,.s2,.cover{{display:none}}}}
</style>
<rect width="{W}" height="{H}" rx="10" fill="#0F172A"/>
<rect width="{W}" height="30" rx="10" fill="#1E293B"/><rect y="20" width="{W}" height="10" fill="#1E293B"/>
<circle cx="20" cy="15" r="5.5" fill="#F87171"/><circle cx="38" cy="15" r="5.5" fill="#FBBF24"/><circle cx="56" cy="15" r="5.5" fill="#34D399"/>
<text x="{W / 2}" y="19" text-anchor="middle" class="ttl">xcblame 0.6.0 · Acme fixture projects</text>
{chr(10).join(body)}
</svg>
'''
with open(OUT, "w", encoding="utf-8") as f:
    f.write(svg)
print(OUT, len(svg), "bytes;", max(len(squeeze(l)) for _, ls in scenes for l in ls), "max cols")
