"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { api, ApiError } from "../../../lib/api.ts";
import type { Channel, Expert, Project } from "../../../lib/types.ts";
import { Board } from "../../../components/board.tsx";
import { Chat } from "../../../components/chat.tsx";
import { ErrorBox, RuntimeMark, Spinner } from "../../../components/atoms.tsx";

/**
 * One channel: its message stream and its board.
 *
 * The tab strip is the whole shape of the product. Chat is where work is asked
 * for and argued about; the board is the same work seen as state. They are two
 * views of one channel rather than two features, which is why the tab lives here
 * and not in the sidebar.
 *
 * There is no Files tab. The reference product has one, but TodoAgent stores no
 * files of its own — an agent's output lands in a git branch. A tab that opens
 * onto a permanent "nothing here" is worse than no tab.
 */

type Tab = "chat" | "tasks";

export default function ChannelPage() {
  const params = useParams<{ id: string }>();
  const channelId = params.id;

  const [channel, setChannel] = useState<Channel | null>(null);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [project, setProject] = useState<Project | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("chat");
  const [taskBump, setTaskBump] = useState(0);

  /** The channel in the URL right now, readable when a response resolves. */
  const openId = useRef(channelId);
  openId.current = channelId;

  const load = useCallback(async () => {
    try {
      /*
       * The channel comes from the message endpoint rather than a dedicated
       * fetch: it returns the channel alongside its stream, so opening a channel
       * is one request instead of two sequential ones.
       */
      const [stream, ex, projects] = await Promise.all([
        api.messages(channelId, 1),
        api.experts(),
        api.projects(),
      ]);
      /*
       * Ignored if the user has already navigated elsewhere.
       *
       * `load` is recreated per channel, so a request for A resolves inside the OLD
       * closure where `channelId` is still A — comparing against that would compare
       * A to A and pass. The ref is the only value current at resolution time.
       */
      if (stream.channel.id !== openId.current) return;
      setChannel(stream.channel);
      setExperts(ex);
      setProject(
        stream.channel.projectId === null
          ? null
          : (projects.find((p) => p.id === stream.channel.projectId) ?? null),
      );
      setError(null);
    } catch (err) {
      if (openId.current !== channelId) return;
      setError(err instanceof ApiError ? err.message : String(err));
    }
  }, [channelId]);

  useEffect(() => {
    /*
     * Cleared BEFORE fetching, which is the actual root cause of the
     * cross-channel bug rather than the stale-response race I chased first.
     *
     * This page never reset `channel` when the id changed, so navigating from A to
     * B rendered A's header, A's repo path and A's conversation while the URL said
     * B — every single time, not occasionally. Now the switch shows the spinner
     * until B's own data lands.
     */
    setChannel(null);
    setProject(null);
    setError(null);
    // The TAB is deliberately kept. Switching channels while comparing two boards
    // should not throw you back to 聊天, and the tab has nothing to do with the bug
    // this reset exists for.
    void load();
  }, [load]);

  if (error !== null) {
    return (
      <div className="p-4">
        <ErrorBox message={error} onRetry={() => void load()} />
      </div>
    );
  }

  if (channel === null) {
    return (
      <div className="grid flex-1 place-items-center p-6">
        <Spinner label="打开频道" />
      </div>
    );
  }

  const dmExpert =
    channel.dmExpertId === null ? null : (experts.find((e) => e.id === channel.dmExpertId) ?? null);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* ── Channel header ── */}
      <header className="app-header">
        <div className="flex min-w-0 items-center gap-2">
          {dmExpert ? (
            <RuntimeMark kind={dmExpert.runtimeKind} name={dmExpert.name} />
          ) : (
            <h1 className="t-md truncate">
              <span aria-hidden className="text-subtle-fg">
                #
              </span>
              {channel.name}
            </h1>
          )}
          {/*
            The repository is the header's second line because it answers the
            question a person actually has here: where does work in this channel
            land? A channel without one can still hold cards but cannot execute
            them, so saying so up front beats a button that fails later.
          */}
          {channel.purpose !== "" || project !== null ? (
            <span className="t-meta ml-1 hidden truncate sm:block">
              {project !== null ? project.repoPath : channel.purpose}
            </span>
          ) : null}
        </div>
      </header>

      {/* ── Tabs ── */}
      <div className="flex shrink-0 items-center gap-1 border-b border-line px-3">
        {(
          [
            ["chat", "聊天"],
            ["tasks", "任务"],
          ] as const
        ).map(([key, label]) => (
          <button
            key={key}
            type="button"
            role="tab"
            aria-selected={tab === key}
            onClick={() => setTab(key)}
            // A bottom rule on the active tab, drawn over the container's own
            // border so the two do not stack into a 2px line.
            className={`-mb-px border-b-2 px-3 py-2 text-[0.8125rem] transition-colors ${
              tab === key
                ? "border-fg font-medium text-fg"
                : "border-transparent text-muted-fg hover:text-fg"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === "chat" ? (
        <Chat
          channel={channel}
          experts={experts}
          onTaskCreated={() => setTaskBump((n) => n + 1)}
        />
      ) : (
        // Remounted when a message created a card, so the board a person
        // switches to is never one refresh behind the chat they came from.
        <Board key={taskBump} channel={channel} experts={experts} />
      )}
    </div>
  );
}
