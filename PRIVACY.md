# Privacy

Hive is built so your family's music life stays at home.

**What stays at home, always:** your music files, who's in the family,
devices, likes, playlists, what everyone plays and when, Listen recordings.
Hive runs no analytics and has no account with us; there is no "us".

**How devices reach home:** only over your Tailscale network (encrypted end
to end between your devices). Hive doesn't listen on your home Wi-Fi or the
internet.

**What can leave home, and only when you allow it:**

| What | To | When | Turn off |
| --- | --- | --- | --- |
| Album and artist **names**, a sound fingerprint of a song | MusicBrainz, Cover Art Archive, Wikidata, AcoustID | Hive looking up covers and details for your music | Hive Admin → Library → *Album details from the internet* |
| A **fingerprint** of what Listen heard (never the sound) | Shazam (Apple) | Only if you turn Shazam on, and only after home couldn't name the song | Hive Admin → Recognition → Shazam (off by default) |
| A fixed message such as "New music at home" (never a name, song or email), encrypted | Apple's push service, or the UnifiedPush server your phone chose (e.g. ntfy) | Notifications while Hive is closed | App → Settings → Notifications |
| Sign-in codes and admin notes (never who or what) | Your own email account | Inviting people, signing in to Hive Admin, alerts | Hive Admin → Settings → Email |

Listen makes its sound landmarks on the phone; the recording never leaves
the phone. Logs never contain names, albums or emails at the normal level.
