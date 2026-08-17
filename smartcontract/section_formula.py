import matplotlib.pyplot as plt
import numpy as np

A = np.array([1.0, 2.0])
B = np.array([6.0, 8.0])
m, n = 3.0, 2.0

P_in = (m * B + n * A) / (m + n)
P_ex = (m * B - n * A) / (m - n)

fig = plt.figure(figsize=(14, 9))
gs = fig.add_gridspec(2, 2, height_ratios=[1.3, 1], hspace=0.32)

ax1 = fig.add_subplot(gs[0, 0])
ax2 = fig.add_subplot(gs[0, 1])
axd = fig.add_subplot(gs[1, :])
axd.axis("off")

def draw(ax, A, B, P, title, color_seg, color_other):
    ax.plot([A[0], B[0]], [A[1], B[1]], color="#bbb", lw=2.5, ls="--")
    ax.plot([A[0], P[0]], [A[1], P[1]], color=color_seg, lw=2.5)
    ax.plot([P[0], B[0]], [P[1], B[1]], color=color_other, lw=2.5)

    ax.scatter([A[0], B[0], P[0]], [A[1], B[1], P[1]],
               color=[color_seg, color_other, "#2ca02c"], s=100, zorder=5)
    ax.annotate("A(1, 2)", A, textcoords="offset points", xytext=(0, 12), ha="center", fontsize=11, fontweight="bold")
    ax.annotate("B(6, 8)", B, textcoords="offset points", xytext=(0, 12), ha="center", fontsize=11, fontweight="bold")
    ax.annotate(f"P({P[0]:.1f}, {P[1]:.1f})", P, textcoords="offset points", xytext=(0, -18),
                ha="center", fontsize=12, fontweight="bold", color="#2ca02c")

    off = np.array([0.5, 0.6])
    mid1 = (A + P) / 2
    mid2 = (P + B) / 2
    ax.annotate("m = 3", mid1 + off, ha="center", fontsize=12, color=color_seg)
    ax.annotate("n = 2", mid2 + off, ha="center", fontsize=12, color=color_other)

    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.grid(True, ls=":", alpha=0.5)
    ax.set_aspect("equal")
    ax.set_xlim(-1, 10.5)
    ax.set_ylim(-1, 11.5)

draw(ax1, A, B, P_in, "INTERNAL  (AP : PB = 3 : 2)", "#d62728", "#1f77b4")
draw(ax2, A, B, P_ex, "EXTERNAL  (AP : PB = 3 : 2)", "#d62728", "#1f77b4")

P_in_red = np.array([3.0, 4.0])
P_ex_red = np.array([11.0, 14.0])

derivation = (
    "DERIVATION  (drop perpendiculars to the x-axis \u2192 similar triangles)\n"
    "Internal  \u2014 P lies BETWEEN A and B, so AP:PB = m:n in the SAME direction:\n"
    "\n"
    "    (x \u2212 x\u2081)      m\n"
    "    \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500  =  \u2500\u2500         (x \u2212 x\u2081) \u00b7 n = m \u00b7 (x\u2082 \u2212 x)\n"
    "    (x\u2082 \u2212 x)      n\n"
    "\n"
    "    n\u00b7x \u2212 n\u00b7x\u2081 = m\u00b7x\u2082 \u2212 m\u00b7x\n"
    "    x(m + n) = m\u00b7x\u2082 + n\u00b7x\u2081\n"
    "    \u21d2   x = (m\u00b7x\u2082 + n\u00b7x\u2081) / (m + n)          [numerator: PLUS]\n"
    "\n"
    "External  \u2014 P lies OUTSIDE (past B), PB points backward, sign flips:\n"
    "\n"
    "    (x \u2212 x\u2081)      m\n"
    "    \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500  =  \u2500\u2500         (x \u2212 x\u2081) \u00b7 n = m \u00b7 (x \u2212 x\u2082)\n"
    "    (x \u2212 x\u2082)      n\n"
    "\n"
    "    n\u00b7x \u2212 n\u00b7x\u2081 = m\u00b7x \u2212 m\u00b7x\u2082\n"
    "    x(m \u2212 n) = m\u00b7x\u2082 \u2212 n\u00b7x\u2081\n"
    "    \u21d2   x = (m\u00b7x\u2082 \u2212 n\u00b7x\u2081) / (m \u2212 n)          [numerator: MINUS]\n"
    "\n"
    "Same for y with y\u2081, y\u2082.  Check with A(1,2), B(6,8), m=3, n=2:\n"
    "  Internal:  P = (3\u00b76 + 2\u00b71)/(3+2), (3\u00b78 + 2\u00b72)/(3+2) = (4.0, 5.6)\n"
    "  External:  P = (3\u00b76 \u2212 2\u00b71)/(3\u22122), (3\u00b78 \u2212 2\u00b72)/(3\u22122) = (16.0, 20.0)\n"
)
axd.text(0.01, 0.97, derivation, transform=axd.transAxes, fontsize=10.5, fontfamily="monospace",
         verticalalignment="top", color="#222",
         bbox=dict(boxstyle="round,pad=0.7", fc="#fafafa", ec="#999"))

fig.suptitle("Section Formula \u2014 Internal & External Division (m:n = 3:2)", fontsize=15, fontweight="bold", y=0.985)
plt.tight_layout(rect=[0, 0, 1, 0.96])
plt.savefig("section_formula_v2.png", dpi=150, bbox_inches="tight")
print("Saved section_formula_v2.png")
