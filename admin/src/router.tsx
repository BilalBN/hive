import type { ReactElement } from "react";
import { createRootRoute, createRoute, createRouter, type RouterHistory } from "@tanstack/react-router";

import { ComingSoon } from "./components/ComingSoon";
import { Shell } from "./layout/Shell";
import { allSections } from "./nav";
import { type AlbumFilter } from "./api/client";
import { AlbumsPage, FILTERS } from "./pages/Albums";
import { LibraryPage } from "./pages/Library";
import { Overview } from "./pages/Overview";
import { UploadPage } from "./pages/Upload";

const built: Record<string, () => ReactElement> = {
  "/": Overview,
  "/library": LibraryPage,
  "/upload": () => <UploadPage />,
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
  .filter((section) => section.path !== "/albums")
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

export function makeRouter(history?: RouterHistory) {
  return createRouter({
    routeTree: rootRoute.addChildren([...routes, albumsRoute]),
    basepath: "/admin",
    history,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>;
  }
}
