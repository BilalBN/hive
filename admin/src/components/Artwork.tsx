import { useState } from "react";

import { artworkUrl } from "../api/client";

/** Album art, or the album's initials on a tinted square when there's none. */
export function Artwork({ id, title, size = 40 }: { id?: string; title: string; size?: number }) {
  const [broken, setBroken] = useState(false);
  const initials = title
    .replace(/\(.*?\)/g, "")
    .split(/[\s\-–.]+/)
    .filter((w) => /\p{L}/u.test(w))
    .slice(0, 2)
    .map((w) => [...w][0]!.toUpperCase())
    .join("");
  let hue = 7;
  for (const ch of title) hue = (hue * 31 + ch.codePointAt(0)!) >>> 0;
  hue %= 360;
  if (id && !broken) {
    return (
      <img
        className="art"
        src={artworkUrl(id, size > 96 ? 192 : 96)}
        alt=""
        width={size}
        height={size}
        loading="lazy"
        onError={() => setBroken(true)}
      />
    );
  }
  return (
    <span
      className="art art--initials"
      aria-hidden
      style={{
        width: size,
        height: size,
        background: `linear-gradient(140deg, oklch(0.68 0.12 ${hue}) 0%, oklch(0.38 0.1 ${(hue + 40) % 360}) 100%)`,
      }}
    >
      {initials || "♪"}
    </span>
  );
}
