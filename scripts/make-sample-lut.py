#!/usr/bin/env python3
"""配布用の見本 LUT（暖かいフィルム調、17^3）を作る。"""
import os

SIZE = 17
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content", "luts", "warm-film.cube")


def clamp(v: float) -> float:
    return max(0.0, min(1.0, v))


def transform(r: float, g: float, b: float):
    # やわらかい S 字 + 黒を少し持ち上げ + 暖色寄り
    def s(x: float) -> float:
        y = x * x * (3 - 2 * x)
        return x + (y - x) * 0.25
    r, g, b = s(r), s(g), s(b)
    r, g, b = r + 0.04, g + 0.015, b - 0.035
    lift = 0.04
    return tuple(clamp(lift + c * (1 - lift)) for c in (r, g, b))


def main() -> None:
    lines = ['TITLE "Warm Film"', f"LUT_3D_SIZE {SIZE}"]
    n = SIZE - 1
    for bi in range(SIZE):
        for gi in range(SIZE):
            for ri in range(SIZE):
                out = transform(ri / n, gi / n, bi / n)
                lines.append("%.6f %.6f %.6f" % out)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
