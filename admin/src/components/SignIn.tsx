import { useMutation, useQueryClient } from "@tanstack/react-query";
import { KeyRound, Mail } from "lucide-react";
import { type FormEvent, useState } from "react";

import { type AdminSession, fetchSession, finishSignIn, startSignIn } from "../api/people";

export const sessionQuery = {
  queryKey: ["admin-session"],
  queryFn: fetchSession,
  staleTime: 60_000,
} as const;

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : "Something went wrong. Try again.";
}

/**
 * Away from the home computer an admin signs in with a code sent to their
 * email, plus the code from their authenticator app.
 */
export function SignIn() {
  const client = useQueryClient();
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [second, setSecond] = useState("");
  const [verificationId, setVerificationId] = useState<string | null>(null);

  const start = useMutation({
    mutationFn: () => startSignIn(email.trim()),
    onSuccess: (r) => setVerificationId(r.verificationId),
  });
  const finish = useMutation({
    mutationFn: () =>
      finishSignIn({
        verificationId: verificationId!,
        code: code.trim(),
        ...(second.trim() ? { authenticatorCode: second.trim() } : {}),
      }),
    onSuccess: (s: AdminSession) => client.setQueryData(sessionQuery.queryKey, s),
  });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (verificationId) finish.mutate();
    else start.mutate();
  };

  return (
    <main className="gate">
      <form className="gate__card" onSubmit={submit}>
        <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={40} height={40} />
        <h1 className="gate__title">Sign in to Hive Admin</h1>
        {!verificationId ? (
          <>
            <p className="gate__text">We'll email you a 6-digit code.</p>
            <label className="field">
              <span>Email</span>
              <input
                className="input"
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </label>
            {start.error && <p className="note note--error">{errorText(start.error)}</p>}
            <button className="button button--primary" type="submit" disabled={!email.trim() || start.isPending}>
              <Mail size={16} aria-hidden /> {start.isPending ? "Sending…" : "Email me a code"}
            </button>
          </>
        ) : (
          <>
            <p className="gate__text">
              If <strong>{email.trim()}</strong> is an admin here, a code is on its way. It works for 10 minutes.
            </p>
            <label className="field">
              <span>Code from the email</span>
              <input
                className="input mono"
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                required
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              />
            </label>
            <div className="field">
              <label className="field__control">
                <span>Code from your authenticator app</span>
                <input
                  className="input mono"
                  inputMode="numeric"
                  pattern="[0-9]{6}"
                  maxLength={6}
                  value={second}
                  onChange={(e) => setSecond(e.target.value.replace(/\D/g, ""))}
                />
              </label>
              <span className="field__hint">Needed once you've set one up in Settings.</span>
            </div>
            {finish.error && <p className="note note--error">{errorText(finish.error)}</p>}
            <button className="button button--primary" type="submit" disabled={code.length !== 6 || finish.isPending}>
              <KeyRound size={16} aria-hidden /> {finish.isPending ? "Checking…" : "Sign in"}
            </button>
            <button
              className="link-button"
              type="button"
              onClick={() => {
                setVerificationId(null);
                setCode("");
                setSecond("");
                finish.reset();
              }}
            >
              Use a different email
            </button>
          </>
        )}
      </form>
    </main>
  );
}

/** Nobody can sign in from elsewhere until the first admin exists. */
export function NotSetUp() {
  return (
    <main className="gate">
      <div className="gate__card">
        <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={40} height={40} />
        <h1 className="gate__title">Set up Hive Admin at home first</h1>
        <p className="gate__text">
          Open Hive Admin on the home computer (the one running Hive) and create the first admin there. After that you
          can sign in from anywhere on your private network.
        </p>
      </div>
    </main>
  );
}
