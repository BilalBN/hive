import type { ReactElement } from "react";
import { createRootRoute, createRoute, createRouter, type RouterHistory } from "@tanstack/react-router";

import { ComingSoon } from "./components/ComingSoon";
import { Shell } from "./layout/Shell";
import { allSections } from "./nav";
import { type AlbumFilter } from "./api/client";
import { AlbumsPage, FILTERS } from "./pages/Albums";
import { BackupsPage } from "./pages/Backups";
import { LogsPage } from "./pages/Logs";
import { SystemPage } from "./pages/System";
import { ActivityPage } from "./pages/Activity";
import { DevicesPage } from "./pages/Devices";
import { InvitePage } from "./pages/Invite";
import { LibraryPage } from "./pages/Library";
import { Overview } from "./pages/Overview";
import { PeoplePage } from "./pages/People";
import { RecognitionPage } from "./pages/Recognition";
import { RequestsPage } from "./pages/Requests";
import { SettingsPage } from "./pages/Settings";
import { SetupPage } from "./pages/Setup";
import { UploadPage } from "./pages/Upload";

const built: Record<string, () => ReactElement> = {
  "/": Overview,
  "/library": LibraryPage,
  "/upload": () => <UploadPage />,
  "/requests": RequestsPage,
  "/devices": DevicesPage,
  "/invite": InvitePage,
  "/activity": ActivityPage,
  "/settings": SettingsPage,
  "/recognition": RecognitionPage,
  "/backups": BackupsPage,
  "/system": SystemPage,
  "/logs": LogsPage,
};

const rootRoute = createRootRoute({
  component: Shell,
  notFoundComponent: () => (
    <section className="page">
      <h1 className="page__title">Page not found</h1>
    </section>
  ),
});

const routes = allSections
  .filter((section) => section.path !== "/albums" && section.path !== "/people")
  .map((section) =>
    createRoute({
      getParentRoute: () => rootRoute,
      path: section.path,
      component: built[section.path] ?? (() => <ComingSoon section={section} />),
    }),
  );

/** Albums keeps its filter and the open album in the address, so either can be linked to. */
const albumsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/albums",
  component: AlbumsPage,
  validateSearch: (s: Record<string, unknown>): { filter: AlbumFilter; album?: string } => ({
    filter: (FILTERS.some((f) => f.value === s.filter) ? s.filter : "all") as AlbumFilter,
    ...(typeof s.album === "string" && s.album ? { album: s.album } : {}),
  }),
});

/** People keeps the open person in the address. */
const peopleRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/people",
  component: PeoplePage,
  validateSearch: (s: Record<string, unknown>): { person?: string } =>
    typeof s.person === "string" && s.person ? { person: s.person } : {},
});

/** Creating the first admin, linked from the Overview (not in the navigation). */
const setupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/setup",
  component: SetupPage,
});

export function makeRouter(history?: RouterHistory) {
  return createRouter({
    routeTree: rootRoute.addChildren([...routes, albumsRoute, peopleRoute, setupRoute]),
    basepath: "/admin",
    history,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>;
  }
}
