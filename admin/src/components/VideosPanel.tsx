import { useQuery } from "@tanstack/react-query";

import { videosQuery } from "../api/videos";

/** Music videos in the music folders, and the ones Hive couldn't match to a song. */
export function VideosPanel() {
  const { data } = useQuery(videosQuery);
  if (!data || data.items.length === 0) return null;
  const unmatched = data.items.filter((v) => !v.trackId);
  return (
    <section className="panel" aria-labelledby="videos-h">
      <h2 id="videos-h" className="panel__title">
        Music videos · {data.matched} of {data.items.length} matched
      </h2>
      <p className="note">
        A video plays with its song in the apps (the clapperboard on Now playing). Hive matches a video with the same
        name beside the song (<span className="mono">03 Malare.mp4</span> next to{" "}
        <span className="mono">03 Malare.flac</span>), or one named <span className="mono">Artist - Title.mp4</span>{" "}
        anywhere in the music folders.
      </p>
      {unmatched.length > 0 && (
        <>
          <p className="note">Not matched to a song yet:</p>
          <ul className="rows">
            {unmatched.map((v) => (
              <li key={v.id} className="row">
                <p className="row__title mono">{v.file}</p>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
