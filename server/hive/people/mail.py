"""Email: sign-in codes, invites and "someone asked to join" notes.

Sent through the admin's own mail account (a Gmail app password works). Mail
never carries anything about what anyone listens to, and the notes to admins
carry no names or addresses: they only say to open Hive Admin.
"""

from __future__ import annotations

import logging
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

from hive.people.settings import EmailSettings

log = logging.getLogger("hive.mail")


class MailError(Exception):
    """The mail server refused or couldn't be reached; the text says which."""


def send(cfg: EmailSettings, to: str, subject: str, text: str, home_name: str) -> None:
    if not cfg.ready:
        raise MailError("Email isn't set up yet (Hive Admin → Settings).")
    msg = EmailMessage()
    msg["From"] = formataddr((f"Hive · {home_name}", cfg.sender))
    msg["To"] = to
    msg["Subject"] = subject
    msg["Message-ID"] = make_msgid(domain="hive.local")
    msg.set_content(text)
    try:
        if cfg.security == "ssl":
            server: smtplib.SMTP = smtplib.SMTP_SSL(
                cfg.host, cfg.port, timeout=20, context=ssl.create_default_context()
            )
        else:
            server = smtplib.SMTP(cfg.host, cfg.port, timeout=20)
        with server:
            if cfg.security == "starttls":
                server.starttls(context=ssl.create_default_context())
            if cfg.username:
                server.login(cfg.username, cfg.password)
            server.send_message(msg)
    except smtplib.SMTPAuthenticationError as e:
        raise MailError(
            "The mail server didn't accept the username and password. For Gmail, use an "
            "app password (myaccount.google.com/apppasswords), not your usual password."
        ) from e
    except (smtplib.SMTPException, OSError) as e:
        raise MailError(f"Couldn't send the email ({type(e).__name__}: {e}).") from e
    log.info("email sent: %s", subject)


def code_text(code: str, home_name: str, purpose: str) -> tuple[str, str]:
    if purpose == "admin":
        return (
            f"{code} is your Hive Admin sign-in code",
            f"Your code to sign in to Hive Admin for {home_name} is:\n\n    {code}\n\n"
            "It works for 10 minutes. If you didn't ask for it, ignore this email.\n",
        )
    return (
        f"{code} is your Hive code",
        f"Your code to join {home_name} on Hive is:\n\n    {code}\n\n"
        "Type it in the Hive app. It works for 10 minutes.\n"
        "If you didn't ask for it, ignore this email.\n",
    )


def invite_text(
    home_name: str, code: str, join_link: str, address: str, network_link: str | None
) -> tuple[str, str]:
    steps = []
    if network_link:
        steps.append(f"1. Join the family's private network: {network_link}")
    else:
        steps.append("1. Ask whoever sent this how to join the family's private network.")
    steps.append("2. Install the Hive app.")
    steps.append(f"3. Open it, choose Join with an invite, and type the code {code}")
    steps.append(f"   (home address: {address}).")
    return (
        f"You're invited to {home_name} on Hive",
        "You're invited to listen to the family's music on Hive.\n\n"
        + "\n".join(steps)
        + f"\n\nOn a phone you can also open this link once the app is installed:\n{join_link}\n\n"
        "The invite works for one week.\n",
    )


def request_note(home_name: str) -> tuple[str, str]:
    return (
        "Someone asked to join Hive",
        f"Someone has asked to join {home_name} on Hive.\n\n"
        "Open Hive Admin → Requests to approve or decline.\n",
    )


def song_request_note(home_name: str) -> tuple[str, str]:
    return (
        "A song request is waiting on Hive",
        f"Someone asked for a song to be added to {home_name} on Hive.\n\n"
        "Open Hive Admin → Requests → Songs to see it.\n",
    )
