import { createRootRoute, createRoute, createRouter, type RouterHistory } from "@tanstack/react-router";

import { ComingSoon } from "./components/ComingSoon";
import { Shell } from "./layout/Shell";
import { allSections } from "./nav";
import { Overview } from "./pages/Overview";

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
    component: section.path === "/" ? Overview : () => <ComingSoon section={section} />,
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
