import type { Section } from "../nav";

/** Placeholder for a page whose milestone hasn't been built yet. */
export function ComingSoon({ section }: { section: Section }) {
  const Icon = section.icon;
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">{section.label}</h1>
        <p className="page__summary">{section.summary}</p>
      </header>
      <div className="empty">
        <Icon size={28} aria-hidden className="empty__icon" />
        <p className="empty__title">Arrives in {section.milestone}</p>
        <p className="empty__text">This page is part of milestone {section.milestone} in the build plan.</p>
      </div>
    </section>
  );
}
