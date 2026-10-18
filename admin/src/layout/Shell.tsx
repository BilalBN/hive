import { Link, Outlet } from "@tanstack/react-router";

import { ServerStatus } from "../components/ServerStatus";
import { ThemeToggle } from "../components/ThemeToggle";
import { type Section, sectionGroups, settingsSection } from "../nav";

function NavItem({ section }: { section: Section }) {
  const Icon = section.icon;
  return (
    <li>
      <Link
        to={section.path}
        className="nav__item"
        activeProps={{ className: "nav__item nav__item--active", "aria-current": "page" }}
        activeOptions={{ exact: section.path === "/" }}
      >
        <Icon size={18} aria-hidden />
        <span>{section.label}</span>
      </Link>
    </li>
  );
}

/** Sidebar navigation (as in Admin v2) with the current page beside it. */
export function Shell() {
  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar__brand">
          <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={24} height={24} />
          <span>Hive Admin</span>
          <ThemeToggle />
        </div>
        <nav aria-label="Admin sections" className="nav">
          {sectionGroups.map((group, i) => (
            <ul key={i} className="nav__group">
              {group.map((s) => (
                <NavItem key={s.path} section={s} />
              ))}
            </ul>
          ))}
          <ul className="nav__group nav__group--foot">
            <NavItem section={settingsSection} />
          </ul>
        </nav>
        <ServerStatus />
      </aside>
      <main className="content">
        <Outlet />
      </main>
    </div>
  );
}
