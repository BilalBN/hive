import type { ReactElement } from "react";
import { createRootRoute, createRoute, createRouter, type RouterHistory } from "@tanstack/react-router";

import { ComingSoon } from "./components/ComingSoon";
import { Shell } from "./layout/Shell";
import { allSections } from "./nav";
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

const routes = allSections.map((section) =>
  createRoute({
    getParentRoute: () => rootRoute,
    path: section.path,
    component: built[section.path] ?? (() => <ComingSoon section={section} />),
  }),
);

export function makeRouter(history?: RouterHistory) {
  return createRouter({
    routeTree: rootRoute.addChildren(routes),
    basepath: "/admin",
    history,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof makeRouter>;
  }
}
