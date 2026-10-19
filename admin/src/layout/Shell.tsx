import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, Outlet } from "@tanstack/react-router";
import { LogOut } from "lucide-react";

import { signOut } from "../api/people";
import { ServerStatus } from "../components/ServerStatus";
import { NotSetUp, SignIn, sessionQuery } from "../components/SignIn";
import { ThemeToggle } from "../components/ThemeToggle";
import { type Section, sectionGroups, settingsSection } from "../nav";
import { overviewQuery } from "../pages/Overview";

function NavItem({ section, badge }: { section: Section; badge?: number }) {
  const Icon = section.icon;
  return (
    <li>
      <Link
        to={section.path}
        className="nav__item"
        activeProps={{
          className: "nav__item nav__item--active",
          "aria-current": "page",
        }}
        activeOptions={{ exact: section.path === "/" }}
      >
        <Icon size={18} aria-hidden />
        <span>{section.label}</span>
        {badge ? (
          <span className="nav__badge" aria-label={`${badge} waiting`}>
            {badge}
          </span>
        ) : null}
      </Link>
    </li>
  );
}

function Me() {
  const client = useQueryClient();
  const { data } = useQuery(sessionQuery);
  const out = useMutation({
    mutationFn: signOut,
    onSuccess: () => client.invalidateQueries({ queryKey: sessionQuery.queryKey }),
  });
  if (!data?.me) return null;
  return (
    <div className="me">
      <div className="me__text">
        <p className="me__name">{data.me.name}</p>
        <p className="me__meta">{data.onHomeComputer ? "On the home computer" : data.me.email}</p>
      </div>
      {!data.onHomeComputer && (
        <button
          className="icon-button"
          type="button"
          title="Sign out"
          aria-label="Sign out"
          onClick={() => out.mutate()}
        >
          <LogOut size={16} aria-hidden />
        </button>
      )}
    </div>
  );
}

/** Sidebar navigation (as in Admin v2) with the current page beside it. */
export function Shell() {
  const session = useQuery(sessionQuery);
  const s = session.data;
  const overview = useQuery({
    ...overviewQuery,
    enabled: Boolean(s?.signedIn),
  });
  // Away from the home computer, nothing shows until an admin signs in.
  if (s && !s.signedIn) return s.needsSetup ? <NotSetUp /> : <SignIn />;

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
              {group.map((section) => (
                <NavItem
                  key={section.path}
                  section={section}
                  badge={section.path === "/requests" ? overview.data?.pendingRequests : undefined}
                />
              ))}
            </ul>
          ))}
          <ul className="nav__group nav__group--foot">
            <NavItem section={settingsSection} />
          </ul>
        </nav>
        <Me />
        <ServerStatus />
      </aside>
      <main className="content">
        <Outlet />
      </main>
    </div>
  );
}
