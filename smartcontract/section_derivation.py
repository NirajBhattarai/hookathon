import matplotlib.pyplot as plt
import numpy as np

A = np.array([1.0, 2.0])
B = np.array([7.0, 8.0])
m, n = 3.0, 2.0
P = (m * B + n * A) / (m + n)

x1, y1 = A
x2, y2 = B
x, y = P

fig = plt.figure(figsize=(12, 15))
fig.patch.set_facecolor("white")
gs = fig.add_gridspec(3, 1, height_ratios=[2.2, 1.0, 1.0], hspace=0.28)

ax = fig.add_subplot(gs[0])
axd = fig.add_subplot(gs[1])
axd.axis("off")
axd2 = fig.add_subplot(gs[2])
axd2.axis("off")

red, blue, green, orange, purple = "#d62728", "#1f77b4", "#2ca02c", "#ff7f0e", "#8c6bb1"

ax.axhline(y1, color="#cccccc", lw=1)
ax.plot([A[0], B[0]], [A[1], B[1]], color="#888888", lw=3, ls="--", zorder=1)

ax.plot([A[0], B[0]], [y1, y1], color=blue, lw=3, zorder=1)
ax.plot([x, B[0]], [y1, y1], color=green, lw=3, zorder=1)
ax.plot([A[0], x], [y1, y], color=orange, lw=3, zorder=1)
ax.plot([x, B[0]], [y, y2], color=red, lw=3, zorder=1)

ax.plot([x, x], [y1, y], color=purple, lw=1.5, ls=":", zorder=2)
ax.plot([A[0], A[0]], [y1, y], color=purple, lw=1.5, ls=":", zorder=2)
ax.plot([x, x], [y, y2], color=purple, lw=1.5, ls=":", zorder=2)

tri1 = plt.Polygon([(x1, y1), (x, y1), (x, y)], closed=True, fill=True, facecolor=orange, alpha=0.15, edgecolor=orange, lw=1.5)
tri2 = plt.Polygon([(x, y1), (x2, y1), (x2, y2)], closed=True, fill=True, facecolor=blue, alpha=0.15, edgecolor=blue, lw=1.5)
ax.add_patch(tri1)
ax.add_patch(tri2)

for pt, lbl, col, off in [(A, "A(x\u2081, y\u2081)", red, (0, 14)),
                          (B, "B(x\u2082, y\u2082)", blue, (0, 14)),
                          (P, "P(x, y)", green, (0, -22))]:
    ax.scatter(*pt, color=col, s=130, zorder=6)
    ax.annotate(lbl, pt, textcoords="offset points", xytext=off, ha="center",
                fontsize=15, fontweight="bold", color=col, zorder=7)

ax.annotate("(x \u2212 x\u2081)", ((x1 + x) / 2, y1 + 0.45), ha="center", fontsize=15, color=green, fontweight="bold")
ax.annotate("(x\u2082 \u2212 x)", ((x + x2) / 2, y1 + 0.45), ha="center", fontsize=15, color=blue, fontweight="bold")
ax.annotate("(y \u2212 y\u2081)", (x1 - 0.45, (y1 + y) / 2), va="center", ha="right", fontsize=15, color=orange, fontweight="bold")
ax.annotate("(y\u2082 \u2212 y)", (x2 + 0.45, (y + y2) / 2), va="center", fontsize=15, color=red, fontweight="bold")

ax.annotate("AP = m", (A + P) / 2 + np.array([0.7, 0.45]), fontsize=15, color=purple, fontweight="bold")
ax.annotate("PB = n", (P + B) / 2 + np.array([0.7, 0.45]), fontsize=15, color=purple, fontweight="bold")

for pt in [A, B, P]:
    ax.plot([pt[0], pt[0]], [y1, pt[1]], color="#dddddd", lw=1.2, ls=":", zorder=0)

ax.set_title("Two Similar Right Triangles \u2014\u2014 just scale up \u25b3[1] by m : n to get \u25b3[2]",
             fontsize=16, fontweight="bold", pad=14)
ax.grid(False)
ax.set_aspect("equal")
ax.set_xlim(-1.5, 10.5)
ax.set_ylim(0.3, 10.5)
ax.set_xticks([])
ax.set_yticks([])
for s in ["top", "right", "left", "bottom"]:
    ax.spines[s].set_visible(False)

step1 = (
    "  STEP 1  \u2014  Drop perpendiculars from A and P to the x-axis.\n"
    "  The dashed lines are parallel, so the two right triangles share the same angles  \u21d2  they are SIMILAR."
)
axd.text(0.02, 0.92, step1, transform=axd.transAxes, fontsize=15, verticalalignment="top",
         fontfamily="monospace", color="#1a1a1a",
         bbox=dict(boxstyle="round,pad=0.8", fc="#eef3fb", ec="#7a9cc6", lw=1.5))

step2 = (
    "  STEP 2  \u2014  Similar triangles scale by the same factor. Scale = AP:PB = m:n, so:\n"
    "           (x \u2212 x\u2081)        m            (y \u2212 y\u2081)        m\n"
    "           \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500   =   \u2500\u2500       and        \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500   =   \u2500\u2500\n"
    "           (x\u2082 \u2212 x)        n            (y\u2082 \u2212 y)        n\n"
    "  STEP 3  \u2014  Cross-multiply and solve for x:\n"
    "           n(x \u2212 x\u2081) = m(x\u2082 \u2212 x)\n"
    "           nx \u2212 nx\u2081 = mx\u2082 \u2212 mx\n"
    "           x(m + n) = mx\u2082 + nx\u2081\n"
    "           x = (mx\u2082 + nx\u2081) / (m + n)      \u2713   y = (my\u2082 + ny\u2081) / (m + n)\n"
    "  CHECK  A(1,2), B(6,8), m=3, n=2  \u21d2  P = ( (3\u00b76+2\u00b71)/5 , (3\u00b78+2\u00b72)/5 ) = (4.0, 5.6)   \u2713"
)
axd2.text(0.02, 0.92, step2, transform=axd2.transAxes, fontsize=15, verticalalignment="top",
          fontfamily="monospace", color="#1a1a1a",
          bbox=dict(boxstyle="round,pad=0.8", fc="#fbf0e8", ec="#c98a5a", lw=1.5))

fig.suptitle("Section Formula \u2014 Internal Division (AP : PB = 3 : 2)", fontsize=20, fontweight="bold", y=0.975)
plt.savefig("section_derivation_v2.png", dpi=170, bbox_inches="tight", facecolor="white")
print("Saved section_derivation_v2.png")
