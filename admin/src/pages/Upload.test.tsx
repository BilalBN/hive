import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { mockApi } from "../test/mockApi";
import type { SenderFactory } from "../upload/queue";
import { UploadPage } from "./Upload";

afterEach(() => vi.unstubAllGlobals());

describe("Upload page", () => {
  it("lists dropped files by album with progress, and skips what it can't take", async () => {
    mockApi();
    const finishers: Array<() => void> = [];
    const sender: SenderFactory = (_f, events) => ({
      start: () => {
        events.progress(400);
        finishers.push(events.done);
      },
      abort: () => {},
    });
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <UploadPage sender={sender} />
      </QueryClientProvider>,
    );
    expect(await screen.findByText("/Users/arun/Music/Hive/Uploads")).toBeInTheDocument();

    const input = screen.getByTestId("choose-files");
    const files = [new File([new Uint8Array(1000)], "Malare.flac"), new File(["x"], "setup.exe")];
    fireEvent.change(input, { target: { files } });

    expect(await screen.findByText("Uploading")).toBeInTheDocument();
    expect(screen.getByText("Skipped")).toBeInTheDocument();
    expect(screen.getByText("Unsupported file type")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Malare.flac upload" })).toHaveAttribute("aria-valuenow", "40");

    act(() => finishers[0]());
    expect(await screen.findByText("Uploaded · scanning")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Clear finished" }));
    expect(screen.queryByText("Malare.flac")).not.toBeInTheDocument();
  });
});
