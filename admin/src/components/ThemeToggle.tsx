import { Monitor, Moon, Sun } from "lucide-react";
import { useEffect, useState } from "react";

type Theme = "system" | "dark" | "light";
const KEY = "hive-admin-theme";
const ORDER: Theme[] = ["system", "dark", "light"];

function readTheme(): Theme {
  try {
    const v = localStorage.getItem(KEY);
    return v === "dark" || v === "light" ? v : "system";
  } catch {
    return "system";
  }
}

function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}

/** Cycles System → Dark → Light; remembered in this browser only. */
export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>(readTheme);

  useEffect(() => {
    applyTheme(theme);
    try {
      if (theme === "system") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, theme);
    } catch {
      /* private mode: the choice just isn't remembered */
    }
  }, [theme]);

  const Icon = theme === "dark" ? Moon : theme === "light" ? Sun : Monitor;
  const label = { system: "System theme", dark: "Dark theme", light: "Light theme" }[theme];
  const next = ORDER[(ORDER.indexOf(theme) + 1) % ORDER.length];

  return (
    <button className="icon-button" type="button" onClick={() => setTheme(next)} aria-label={`${label}. Switch theme`} title={label}>
      <Icon size={18} aria-hidden />
    </button>
  );
}
