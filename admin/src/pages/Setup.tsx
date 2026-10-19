import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { type FormEvent, useState } from "react";

import { setUpAdmin } from "../api/people";
import { sessionQuery } from "../components/SignIn";

const SETTINGS_PATH: string = "/settings";

/** Create the first admin, on the home computer. */
export function SetupPage() {
  const client = useQueryClient();
  const session = useQuery(sessionQuery);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const setup = useMutation({
    mutationFn: () => setUpAdmin({ name: name.trim(), email: email.trim() }),
    onSuccess: (s) => {
      client.setQueryData(sessionQuery.queryKey, s);
      client.invalidateQueries({ queryKey: ["overview"] });
    },
  });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    setup.mutate();
  };

  const s = session.data;
  if (s && !s.needsSetup) {
    return (
      <section className="page">
        <header className="page__header">
          <h1 className="page__title">You're set up</h1>
          <p className="page__summary">
            {s.me ? `${s.me.name} is the admin.` : "Hive Admin already has an admin."} Next, add an authenticator app so
            you can sign in from other computers.
          </p>
        </header>
        <div className="actions">
          <Link to={SETTINGS_PATH} className="button button--primary">
            Open Settings
          </Link>
        </div>
      </section>
    );
  }

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Set up the first admin</h1>
        <p className="page__summary">You. Your email is where sign-in codes and "someone is waiting" notes go.</p>
      </header>
      {s && !s.onHomeComputer ? (
        <p className="note note--warning">Do this on the home computer itself.</p>
      ) : (
        <form className="panel form" onSubmit={submit}>
          <label className="field">
            <span>Your name</span>
            <input className="input" required maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />
          </label>
          <label className="field">
            <span>Your email</span>
            <input
              className="input"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </label>
          <p className="note">
            Afterwards the temporary key stops working: apps ask people to join with an invite instead. Likes, plays and
            playlists made so far become yours.
          </p>
          {setup.error && <p className="note note--error">{setup.error.message}</p>}
          <div className="actions">
            <button
              className="button button--primary"
              type="submit"
              disabled={!name.trim() || !email.trim() || setup.isPending}
            >
              {setup.isPending ? "Setting up…" : "Set up"}
            </button>
          </div>
        </form>
      )}
    </section>
  );
}
