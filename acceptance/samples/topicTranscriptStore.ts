import { useCallback, useSyncExternalStore } from "react";
import type { JsonRpcNotification, JsonValue } from "@codex-ui/shared";
import {
  applyNotificationsPreservingActiveThread,
  initialClientState,
  type ClientState,
  type ThreadEntry,
  type WorkbenchItem,
  type WorkbenchTurn
} from "../../state/codexClient";
import { mergeWorkbenchTurns, upsertWorkbenchTurn } from "../../state/workbenchTimeline";
import { buildPanelTranscriptProjections, sameProjection, type PanelTranscriptProjection } from "./transcriptProjection";

const EMPTY_TURNS: WorkbenchTurn[] = [];
const EMPTY_ITEMS: WorkbenchTurn["items"] = [];
const EMPTY_THREADS: ThreadEntry[] = [];
const EMPTY_INDEX = new Map<string, WorkbenchTurn[]>();
const EMPTY_PROJECTION: PanelTranscriptProjection = {
  turns: EMPTY_TURNS,
  turnsByThreadId: EMPTY_INDEX,
  threads: EMPTY_THREADS
};
const EMPTY_AGENT_OVERVIEW = new Map<string, AgentTranscriptOverview>();
const MAX_BACKGROUND_TURNS = 8;
const MAX_AGENT_OVERVIEW_TEXT = 420;
const AGENT_OVERVIEW_INPUT_WINDOW = MAX_AGENT_OVERVIEW_TEXT * 2;

type Listener = () => void;

export interface AgentTranscriptOverview {
  threadId: string;
  turnId?: string;
  itemId?: string;
  status: string;
  text: string;
  itemType?: string;
  updatedAt?: number;
}

/**
 * Transcript source of truth partitioned by Codex thread/topic. A token update
 * changes one bucket and wakes only that thread. Parent topics receive compact
 * child lifecycle summaries, never child transcript bodies.
 */
export class TopicTranscriptStore {
  private readonly turnsByThreadId = new Map<string, WorkbenchTurn[]>();
  private readonly summaryTurnsByThreadId = new Map<string, WorkbenchTurn[]>();
  private readonly threadsById = new Map<string, ThreadEntry>();
  private readonly childThreadIdsByTopic = new Map<string, Set<string>>();
  private readonly listenersByTopic = new Map<string, Set<Listener>>();
  private readonly agentOverviewByThreadId = new Map<string, AgentTranscriptOverview>();
  private readonly agentOverviewListenersByTopic = new Map<string, Set<Listener>>();
  private readonly agentOverviewSnapshots = new Map<string, ReadonlyMap<string, AgentTranscriptOverview>>();
  private readonly agentOverviewVersions = new Map<string, number>();
  private readonly projections = new Map<string, PanelTranscriptProjection>();
  private readonly versions = new Map<string, number>();
  private readonly threadIdByTurnId = new Map<string, string>();
  private readonly loadedSnapshotThreadIds = new Set<string>();
  private readonly transcriptRetainCounts = new Map<string, number>();
  private notificationBatchCount = 0;
  private notificationCount = 0;
  private listenerWakeCount = 0;
  private agentOverviewListenerWakeCount = 0;
  private reducedThreadCount = 0;
  private reducedTurnCount = 0;

  constructor(private readonly onThreadRegistered?: (thread: ThreadEntry) => void) {}

  replaceCatalog(threads: ThreadEntry[]): void {
    const affected = new Set<string>();
    for (const thread of threads) {
      const previous = this.threadsById.get(thread.id);
      if (this.captureThread(thread)) {
        affected.add(previous?.parentThreadId ?? previous?.id ?? thread.id);
        affected.add(this.ownerTopicId(thread.id));
      }
    }
    this.refreshTopics(affected);
    this.refreshAgentOverviews(affected);
  }

  upsertThread(thread: ThreadEntry): void {
    if (!this.captureThread(thread)) return;
    const affected = new Set([thread.id, this.ownerTopicId(thread.id)]);
    this.refreshTopics(affected);
    this.refreshAgentOverviews(affected);
  }

  mergeTurns(turns: WorkbenchTurn[]): void {
    const incomingByThread = new Map<string, WorkbenchTurn[]>();
    for (const turn of turns) {
      const bucket = incomingByThread.get(turn.threadId);
      if (bucket) bucket.push(turn);
      else incomingByThread.set(turn.threadId, [turn]);
    }
    const affected = new Set<string>();
    const affectedAgentOverviews = new Set<string>();
    for (const [threadId, incoming] of incomingByThread) {
      if (!this.shouldRetainFullTranscript(threadId)) {
        const { lifecycleChanged, overviewChanged } = this.mergeBackgroundTurns(threadId, incoming);
        const ownerTopicId = this.ownerTopicId(threadId);
        if (lifecycleChanged) affected.add(ownerTopicId);
        if (overviewChanged && ownerTopicId !== threadId) affectedAgentOverviews.add(ownerTopicId);
        continue;
      }
      const current = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
      const next = mergeWorkbenchTurns(current, incoming);
      if (next === current || (next.length === current.length && next.every((turn, index) => turn === current[index]))) continue;
      const { lifecycleChanged, overviewChanged } = this.assignThreadTurns(threadId, next);
      affected.add(threadId);
      const ownerTopicId = this.ownerTopicId(threadId);
      if (lifecycleChanged) affected.add(ownerTopicId);
      if (overviewChanged && ownerTopicId !== threadId) affectedAgentOverviews.add(ownerTopicId);
    }
    this.refreshTopics(affected);
    this.refreshAgentOverviews(affectedAgentOverviews);
  }

  mergeSnapshot(thread: ThreadEntry | null, turns: WorkbenchTurn[], options?: { incomplete?: boolean }): void {
    const incomplete = options?.incomplete === true;
    if (thread) {
      this.upsertThread(thread);
      if (incomplete) {
        // Partial/failed restores must stay retryable: never mark them loaded
        // and never materialize an empty bucket that would satisfy
        // hasThreadTranscript() on the next open.
        this.loadedSnapshotThreadIds.delete(thread.id);
      } else if (this.shouldRetainFullTranscript(thread.id)) {
        this.loadedSnapshotThreadIds.add(thread.id);
        // An empty conversation is still a complete snapshot. Keep an explicit
        // bucket so a stale loaded marker can never make a later reopen skip IO
        // while there is no transcript data to project.
        if (!this.turnsByThreadId.has(thread.id) && !turns.some((turn) => turn.threadId === thread.id)) {
          this.turnsByThreadId.set(thread.id, EMPTY_TURNS);
        }
      } else {
        this.loadedSnapshotThreadIds.delete(thread.id);
      }
    }
    if (!incomplete) {
      for (const turn of turns) {
        if (this.shouldRetainFullTranscript(turn.threadId)) this.loadedSnapshotThreadIds.add(turn.threadId);
        else this.loadedSnapshotThreadIds.delete(turn.threadId);
      }
    } else {
      for (const turn of turns) {
        this.loadedSnapshotThreadIds.delete(turn.threadId);
      }
    }
    this.mergeTurns(turns);
  }

  applyNotifications(notifications: JsonRpcNotification[]): void {
    if (notifications.length === 0) return;
    this.notificationBatchCount += 1;
    this.notificationCount += notifications.length;
    // Register new child topics before routing the rest of the same websocket
    // batch. Codex can emit thread/started immediately followed by its first
    // delta; routing first would temporarily treat the child as a root topic.
    for (const notification of notifications) {
      this.registerNotificationRouting(notification);
    }
    const notificationsByThread = new Map<string, JsonRpcNotification[]>();
    for (const notification of notifications) {
      const threadId = this.notificationThreadId(notification);
      if (!threadId) continue;
      const bucket = notificationsByThread.get(threadId);
      if (bucket) bucket.push(notification);
      else notificationsByThread.set(threadId, [notification]);
    }

    const affectedTopics = new Set<string>();
    const affectedAgentOverviews = new Set<string>();
    for (const [threadId, scopedNotifications] of notificationsByThread) {
      this.captureTurnRouting(threadId, scopedNotifications);
      if (!this.shouldRetainFullTranscript(threadId)) {
        const { lifecycleChanged, overviewChanged } = this.applyBackgroundNotifications(threadId, scopedNotifications);
        const ownerTopicId = this.ownerTopicId(threadId);
        if (lifecycleChanged) affectedTopics.add(ownerTopicId);
        if (overviewChanged && ownerTopicId !== threadId) affectedAgentOverviews.add(ownerTopicId);
        continue;
      }
      // Root topics are observed from their creation and therefore have a
      // complete live transcript. A child can be selected halfway through its
      // rollout, so only thread/read may mark that child snapshot as complete.
      if (!this.threadsById.get(threadId)?.parentThreadId) {
        this.loadedSnapshotThreadIds.add(threadId);
      }
      const currentThread = this.threadsById.get(threadId);
      const currentTurns = this.turnsByThreadId.get(threadId)
        ?? this.summaryTurnsByThreadId.get(threadId)
        ?? EMPTY_TURNS;
      this.reducedThreadCount += 1;
      this.reducedTurnCount += currentTurns.length;
      const next = applyNotificationsPreservingActiveThread(
        {
          ...initialClientState,
          threads: currentThread ? [currentThread] : EMPTY_THREADS,
          turns: currentTurns,
          activeThreadId: threadId
        },
        scopedNotifications
      );
      this.captureThreads(next.threads);
      const { lifecycleChanged, overviewChanged } = this.assignThreadTurns(threadId, next.turns.filter((turn) => turn.threadId === threadId));
      affectedTopics.add(threadId);
      const ownerTopicId = this.ownerTopicId(threadId);
      if (lifecycleChanged) affectedTopics.add(ownerTopicId);
      if (overviewChanged && ownerTopicId !== threadId) affectedAgentOverviews.add(ownerTopicId);
    }
    this.refreshTopics(affectedTopics);
    // The stream scheduler already coalesces token deltas. Notify an open
    // all-agent overview once for the whole batch, never once per child token.
    this.refreshAgentOverviews(affectedAgentOverviews);
  }

  /** Registers child ownership synchronously, before a queued batch is reduced. */
  registerNotificationRouting(notification: JsonRpcNotification): void {
    if (notification.method !== "thread/started") return;
    const seeded = applyNotificationsPreservingActiveThread(initialClientState, [notification]);
    const affectedTopics = new Set<string>();
    for (const thread of seeded.threads) {
      const previous = this.threadsById.get(thread.id);
      if (!this.captureThread(thread)) continue;
      if (previous?.parentThreadId) affectedTopics.add(previous.parentThreadId);
      affectedTopics.add(this.ownerTopicId(thread.id));
    }
    this.refreshTopics(affectedTopics);
    this.refreshAgentOverviews(affectedTopics);
  }

  replaceThreadTurns(threadId: string, turns: WorkbenchTurn[]): void {
    if (!this.shouldRetainFullTranscript(threadId)) {
      this.loadedSnapshotThreadIds.delete(threadId);
      const { lifecycleChanged, overviewChanged } = this.replaceBackgroundTurns(threadId, turns);
      const ownerTopicId = this.ownerTopicId(threadId);
      if (lifecycleChanged) this.refreshTopics(new Set([ownerTopicId]));
      if (overviewChanged && ownerTopicId !== threadId) this.refreshAgentOverviews(new Set([ownerTopicId]));
      return;
    }
    const current = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    if (current.length === turns.length && current.every((turn, index) => turn === turns[index])) return;
    const { lifecycleChanged, overviewChanged } = this.assignThreadTurns(threadId, turns);
    const affected = new Set([threadId]);
    const ownerTopicId = this.ownerTopicId(threadId);
    if (lifecycleChanged) affected.add(ownerTopicId);
    this.refreshTopics(affected);
    if (overviewChanged && ownerTopicId !== threadId) this.refreshAgentOverviews(new Set([ownerTopicId]));
  }

  private assignThreadTurns(threadId: string, turns: WorkbenchTurn[]): { lifecycleChanged: boolean; overviewChanged: boolean } {
    const current = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const nextTurnIds = new Set(turns.map((turn) => turn.id));
    for (const turn of current) {
      if (!nextTurnIds.has(turn.id)) this.threadIdByTurnId.delete(turn.id);
    }
    this.turnsByThreadId.set(threadId, turns);
    for (const turn of turns) this.threadIdByTurnId.set(turn.id, threadId);
    const previousSummary = this.summaryTurnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const nextSummary = summarizeTurns(turns, previousSummary);
    const lifecycleChanged = nextSummary !== previousSummary;
    if (lifecycleChanged) this.summaryTurnsByThreadId.set(threadId, nextSummary);

    const previousOverview = this.agentOverviewByThreadId.get(threadId);
    const nextOverview = summarizeAgentTranscript(threadId, turns, previousOverview);
    const overviewChanged = nextOverview !== previousOverview;
    if (nextOverview) this.agentOverviewByThreadId.set(threadId, nextOverview);
    else this.agentOverviewByThreadId.delete(threadId);
    return { lifecycleChanged, overviewChanged };
  }

  private mergeBackgroundTurns(threadId: string, incoming: WorkbenchTurn[]): { lifecycleChanged: boolean; overviewChanged: boolean } {
    const previousSummary = this.summaryTurnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const incomingSummary = summarizeTurns(incoming, previousSummary);
    const nextSummary = summarizeTurns(mergeWorkbenchTurns(previousSummary, incomingSummary), previousSummary);
    const lifecycleChanged = nextSummary !== previousSummary;
    if (lifecycleChanged) this.assignBackgroundSummary(threadId, previousSummary, nextSummary);

    const previousOverview = this.agentOverviewByThreadId.get(threadId);
    const nextOverview = summarizeAgentTranscript(threadId, incoming, previousOverview);
    const overviewChanged = nextOverview !== previousOverview;
    if (nextOverview) this.agentOverviewByThreadId.set(threadId, nextOverview);
    else this.agentOverviewByThreadId.delete(threadId);
    return { lifecycleChanged, overviewChanged };
  }

  private replaceBackgroundTurns(threadId: string, turns: WorkbenchTurn[]): { lifecycleChanged: boolean; overviewChanged: boolean } {
    this.turnsByThreadId.delete(threadId);
    const previousSummary = this.summaryTurnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const nextSummary = summarizeTurns(turns, previousSummary);
    const lifecycleChanged = nextSummary !== previousSummary;
    if (lifecycleChanged) this.assignBackgroundSummary(threadId, previousSummary, nextSummary, true);

    const previousOverview = this.agentOverviewByThreadId.get(threadId);
    const nextOverview = summarizeAgentTranscript(threadId, turns, previousOverview);
    const overviewChanged = nextOverview !== previousOverview;
    if (nextOverview) this.agentOverviewByThreadId.set(threadId, nextOverview);
    else this.agentOverviewByThreadId.delete(threadId);
    return { lifecycleChanged, overviewChanged };
  }

  private assignBackgroundSummary(
    threadId: string,
    previous: WorkbenchTurn[],
    next: WorkbenchTurn[],
    clearAllOwned = false,
  ): void {
    const nextIds = new Set(next.map((turn) => turn.id));
    if (clearAllOwned) {
      for (const [turnId, ownerThreadId] of this.threadIdByTurnId) {
        if (ownerThreadId === threadId && !nextIds.has(turnId)) this.threadIdByTurnId.delete(turnId);
      }
    } else {
      for (const turn of previous) {
        if (!nextIds.has(turn.id) && this.threadIdByTurnId.get(turn.id) === threadId) {
          this.threadIdByTurnId.delete(turn.id);
        }
      }
    }
    if (next.length > 0) this.summaryTurnsByThreadId.set(threadId, next);
    else this.summaryTurnsByThreadId.delete(threadId);
    for (const turn of next) this.threadIdByTurnId.set(turn.id, threadId);
  }

  private applyBackgroundNotifications(
    threadId: string,
    notifications: JsonRpcNotification[],
  ): { lifecycleChanged: boolean; overviewChanged: boolean } {
    this.loadedSnapshotThreadIds.delete(threadId);
    const previousSummary = this.summaryTurnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const nextSummary = reduceBackgroundTurnLifecycle(threadId, previousSummary, notifications);
    if (nextSummary !== previousSummary) this.assignBackgroundSummary(threadId, previousSummary, nextSummary);

    const previousOverview = this.agentOverviewByThreadId.get(threadId);
    const nextOverview = reduceAgentOverview(threadId, notifications, previousOverview);
    const overviewChanged = nextOverview !== previousOverview;
    if (nextOverview) this.agentOverviewByThreadId.set(threadId, nextOverview);
    return { lifecycleChanged: nextSummary !== previousSummary, overviewChanged };
  }

  mergeTurn(turn: WorkbenchTurn): void {
    // Inline /review and other non-authoritative turns must merge into the
    // live waterfall instead of filtering the same-id turn and replacing it,
    // so streamed items that arrived before the RPC response are preserved.
    this.mergeTurns([turn]);
  }

  replaceThreadTurn(turn: WorkbenchTurn): void {
    if (!this.shouldRetainFullTranscript(turn.threadId)) {
      this.loadedSnapshotThreadIds.delete(turn.threadId);
      this.mergeTurns([turn]);
      return;
    }
    if (!this.threadsById.get(turn.threadId)?.parentThreadId) {
      this.loadedSnapshotThreadIds.add(turn.threadId);
    }
    const current = this.turnsByThreadId.get(turn.threadId) ?? EMPTY_TURNS;
    const next = mergeWorkbenchTurns(current.filter((entry) => entry.id !== turn.id), [turn]);
    this.replaceThreadTurns(turn.threadId, next);
  }

  updateRetryErrorItem(
    threadId: string,
    turnId: string,
    patch: { status: string; retrySource: string; attempt?: number; max?: number; delayMs?: number; exhausted?: boolean }
  ): void {
    const turns = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const turn = turns.find((entry) => entry.id === turnId);
    if (!turn) return;
    let itemIndex = -1;
    for (let index = turn.items.length - 1; index >= 0; index -= 1) {
      const payload = record(turn.items[index]?.payload);
      if (payload.retryError === true && (!patch.retrySource || payload.retrySource === patch.retrySource)) {
        itemIndex = index;
        break;
      }
    }
    if (itemIndex < 0) {
      for (let index = turn.items.length - 1; index >= 0; index -= 1) {
        if (record(turn.items[index]?.payload).retryError === true) {
          itemIndex = index;
          break;
        }
      }
    }
    if (itemIndex < 0) return;
    const item = turn.items[itemIndex]!;
    const items = [...turn.items];
    items[itemIndex] = {
      ...item,
      status: patch.status,
      payload: { ...record(item.payload), ...patch } as JsonValue
    };
    this.replaceThreadTurn({ ...turn, items });
  }

  appendRetryErrorItem(
    threadId: string,
    turnId: string,
    input: {
      title: string;
      text: string;
      status: string;
      retrySource: string;
      attempt: number;
      max: number;
      delayMs?: number;
      exhausted?: boolean;
      additionalDetails?: string;
    }
  ): void {
    const turns = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    const turn = turns.find((entry) => entry.id === turnId);
    if (!turn) return;
    const now = Date.now() / 1000;
    const stableId = `retry-error-${turnId}-app`;
    const isAppRetryItem = (item: WorkbenchItem) =>
      item.id === stableId || (record(item.payload).retryError === true && record(item.payload).retrySource === "app");
    const existingItem = turn.items.find(isAppRetryItem);
    const retryItem: WorkbenchItem = {
      id: stableId,
      type: "retryError",
      title: input.title,
      text: input.text,
      status: input.status,
      startedAt: existingItem ? existingItem.startedAt : now,
      updatedAt: now,
      payload: {
        ...(existingItem ? record(existingItem.payload) : {}),
        retryError: true,
        retrySource: input.retrySource,
        attempt: input.attempt,
        max: input.max,
        ...(input.delayMs != null ? { delayMs: input.delayMs } : {}),
        ...(input.exhausted != null ? { exhausted: input.exhausted } : {}),
        ...(input.additionalDetails ? { additionalDetails: input.additionalDetails } : {})
      }
    };
    let placed = false;
    const items: WorkbenchItem[] = [];
    for (const item of turn.items) {
      if (isAppRetryItem(item)) {
        if (!placed) {
          items.push(retryItem);
          placed = true;
        }
      } else {
        items.push(item);
      }
    }
    if (!placed) {
      items.push(retryItem);
    }
    this.replaceThreadTurn({ ...turn, items });
  }

  removeRetryErrorItems(threadId: string, turnIds: ReadonlySet<string>): void {
    const turns = this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS;
    let changed = false;
    const next = turns.map((turn) => {
      if (!turnIds.has(turn.id)) return turn;
      const items = turn.items.filter((item) => record(item.payload).retryError !== true);
      if (items.length === turn.items.length) return turn;
      changed = true;
      return { ...turn, items };
    });
    if (changed) this.replaceThreadTurns(threadId, next);
  }

  hasThreadTranscript(threadId: string | null): boolean {
    return Boolean(
      threadId
      && this.loadedSnapshotThreadIds.has(threadId)
      && this.turnsByThreadId.has(threadId)
    );
  }

  evict(threadIds: Iterable<string>): void {
    const affected = new Set<string>();
    const expanded = new Set(threadIds);
    for (const threadId of [...expanded]) {
      if (this.threadsById.get(threadId)?.parentThreadId) continue;
      for (const childThreadId of this.childThreadIdsByTopic.get(threadId) ?? []) expanded.add(childThreadId);
    }
    for (const threadId of expanded) {
      affected.add(this.ownerTopicId(threadId));
      for (const [turnId, ownerThreadId] of this.threadIdByTurnId) {
        if (ownerThreadId === threadId) this.threadIdByTurnId.delete(turnId);
      }
      this.turnsByThreadId.delete(threadId);
      this.summaryTurnsByThreadId.delete(threadId);
      this.agentOverviewByThreadId.delete(threadId);
      this.loadedSnapshotThreadIds.delete(threadId);
      affected.add(threadId);
    }
    this.refreshTopics(affected);
    this.refreshAgentOverviews(affected);
  }

  getThreadTurns(threadId: string | null): WorkbenchTurn[] {
    return threadId ? this.turnsByThreadId.get(threadId) ?? EMPTY_TURNS : EMPTY_TURNS;
  }

  getProjection(topicId: string | null): PanelTranscriptProjection {
    if (!topicId) return EMPTY_PROJECTION;
    const existing = this.projections.get(topicId);
    if (existing) return existing;
    const projection = this.buildProjection(topicId);
    this.projections.set(topicId, projection);
    return projection;
  }

  getVersion(topicId: string | null): number {
    return topicId ? this.versions.get(topicId) ?? 0 : 0;
  }

  getAgentOverview(topicId: string | null): ReadonlyMap<string, AgentTranscriptOverview> {
    if (!topicId) return EMPTY_AGENT_OVERVIEW;
    const existing = this.agentOverviewSnapshots.get(topicId);
    if (existing) return existing;
    const next = new Map<string, AgentTranscriptOverview>();
    for (const childThreadId of this.childThreadIdsByTopic.get(topicId) ?? []) {
      const overview = this.agentOverviewByThreadId.get(childThreadId);
      if (overview) next.set(childThreadId, overview);
    }
    this.agentOverviewSnapshots.set(topicId, next);
    return next;
  }

  getAgentOverviewVersion(topicId: string | null): number {
    return topicId ? this.agentOverviewVersions.get(topicId) ?? 0 : 0;
  }

  diagnostics() {
    return {
      topicBucketCount: this.turnsByThreadId.size,
      summaryBucketCount: this.summaryTurnsByThreadId.size,
      agentOverviewCount: this.agentOverviewByThreadId.size,
      agentOverviewTextChars: [...this.agentOverviewByThreadId.values()].reduce((total, entry) => total + entry.text.length, 0),
      loadedSnapshotThreadCount: this.loadedSnapshotThreadIds.size,
      retainedTranscriptCount: this.transcriptRetainCounts.size,
      turnIndexCount: this.threadIdByTurnId.size,
      subscribedTopicCount: this.listenersByTopic.size,
      subscribedAgentOverviewCount: this.agentOverviewListenersByTopic.size,
      materializedProjectionCount: this.projections.size,
      materializedAgentOverviewCount: this.agentOverviewSnapshots.size,
      notificationBatchCount: this.notificationBatchCount,
      notificationCount: this.notificationCount,
      listenerWakeCount: this.listenerWakeCount,
      agentOverviewListenerWakeCount: this.agentOverviewListenerWakeCount,
      reducedThreadCount: this.reducedThreadCount,
      reducedTurnCount: this.reducedTurnCount
    };
  }

  subscribe(topicId: string | null, listener: Listener): () => void {
    if (!topicId) return () => undefined;
    let listeners = this.listenersByTopic.get(topicId);
    if (!listeners) {
      listeners = new Set();
      this.listenersByTopic.set(topicId, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners?.delete(listener);
      if (listeners?.size === 0) {
        this.listenersByTopic.delete(topicId);
        this.projections.delete(topicId);
        if (this.threadsById.get(topicId)?.parentThreadId && !this.shouldRetainFullTranscript(topicId)) {
          this.releaseChildTranscript(topicId);
        }
      }
    };
  }

  /** Keeps a child snapshot alive across the click-to-subscription load race. */
  retainThreadTranscript(threadId: string | null): () => void {
    if (!threadId) return () => undefined;
    this.transcriptRetainCounts.set(threadId, (this.transcriptRetainCounts.get(threadId) ?? 0) + 1);
    if (!this.turnsByThreadId.has(threadId)) {
      const summary = this.summaryTurnsByThreadId.get(threadId);
      if (summary?.length) {
        const overview = this.agentOverviewByThreadId.get(threadId);
        this.turnsByThreadId.set(threadId, materializeOverviewTurns(summary, overview));
      }
    }
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const nextCount = (this.transcriptRetainCounts.get(threadId) ?? 1) - 1;
      if (nextCount > 0) this.transcriptRetainCounts.set(threadId, nextCount);
      else this.transcriptRetainCounts.delete(threadId);
      if (this.threadsById.get(threadId)?.parentThreadId && !this.shouldRetainFullTranscript(threadId)) {
        this.releaseChildTranscript(threadId);
      }
    };
  }

  subscribeAgentOverview(topicId: string | null, listener: Listener): () => void {
    if (!topicId) return () => undefined;
    let listeners = this.agentOverviewListenersByTopic.get(topicId);
    if (!listeners) {
      listeners = new Set();
      this.agentOverviewListenersByTopic.set(topicId, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners?.delete(listener);
      if (listeners?.size === 0) {
        this.agentOverviewListenersByTopic.delete(topicId);
        this.agentOverviewSnapshots.delete(topicId);
      }
    };
  }

  hydrate(state: Pick<ClientState, "threads" | "turns">): void {
    this.replaceCatalog(state.threads);
    this.mergeTurns(state.turns);
  }

  private ownerTopicId(threadId: string): string {
    return this.threadsById.get(threadId)?.parentThreadId ?? threadId;
  }

  private shouldRetainFullTranscript(threadId: string): boolean {
    return !this.threadsById.get(threadId)?.parentThreadId
      || Boolean(this.listenersByTopic.get(threadId)?.size)
      || Boolean(this.transcriptRetainCounts.get(threadId));
  }

  private releaseChildTranscript(threadId: string): void {
    const turns = this.turnsByThreadId.get(threadId);
    if (turns?.length) {
      const previousSummary = this.summaryTurnsByThreadId.get(threadId) ?? EMPTY_TURNS;
      const nextSummary = summarizeTurns(turns, previousSummary);
      if (nextSummary !== previousSummary) this.assignBackgroundSummary(threadId, previousSummary, nextSummary, true);
      else {
        const retainedTurnIds = new Set(nextSummary.map((turn) => turn.id));
        for (const [turnId, ownerThreadId] of this.threadIdByTurnId) {
          if (ownerThreadId === threadId && !retainedTurnIds.has(turnId)) this.threadIdByTurnId.delete(turnId);
        }
      }
      const previousOverview = this.agentOverviewByThreadId.get(threadId);
      const nextOverview = summarizeAgentTranscript(threadId, turns, previousOverview);
      if (nextOverview) this.agentOverviewByThreadId.set(threadId, nextOverview);
    }
    this.turnsByThreadId.delete(threadId);
    this.loadedSnapshotThreadIds.delete(threadId);
    this.projections.delete(threadId);
  }

  private captureTurnRouting(threadId: string, notifications: JsonRpcNotification[]): void {
    for (const notification of notifications) {
      const params = record(notification.params);
      const item = record(params.item);
      const turnId = text(params.turnId)
        ?? text(params.turn_id)
        ?? text(record(params.turn).id)
        ?? text(item.turnId)
        ?? text(item.turn_id);
      if (turnId) this.threadIdByTurnId.set(turnId, threadId);
    }
  }

  private notificationThreadId(notification: JsonRpcNotification): string | null {
    const params = record(notification.params);
    const item = record(params.item);
    const direct = text(params.threadId)
      ?? text(params.thread_id)
      ?? text(record(params.turn).threadId)
      ?? text(record(params.turn).thread_id)
      ?? text(item.threadId)
      ?? text(item.thread_id)
      ?? text(record(params.thread).id);
    if (direct) return direct;
    const turnId = text(params.turnId) ?? text(params.turn_id) ?? text(record(params.turn).id);
    if (!turnId) return null;
    return this.threadIdByTurnId.get(turnId) ?? null;
  }

  private captureThreads(threads: ThreadEntry[]): void {
    for (const thread of threads) this.captureThread(thread);
  }

  private captureThread(thread: ThreadEntry): boolean {
    const previous = this.threadsById.get(thread.id);
    // thread/read and catalog mirrors can return only a subset of the thread
    // metadata. In particular, child snapshots may omit parentThreadId even
    // though thread/started already established the ownership. Treat absent
    // fields as "not supplied" so a partial mirror cannot promote a child to
    // a root topic and make its entire transcript permanently resident.
    const canonical = previous ? mergeThreadEntry(previous, thread) : thread;
    // App's structural reducer and the transcript store parse the same wire
    // notification independently. Preserve the canonical object when the
    // fields are equal so catalog mirroring cannot wake useSyncExternalStore
    // again from a React effect and create an update loop.
    if (previous && sameThreadEntry(previous, canonical)) return false;
    if (previous?.parentThreadId && previous.parentThreadId !== canonical.parentThreadId) {
      const previousChildren = this.childThreadIdsByTopic.get(previous.parentThreadId);
      previousChildren?.delete(thread.id);
      if (previousChildren?.size === 0) this.childThreadIdsByTopic.delete(previous.parentThreadId);
    }
    this.threadsById.set(canonical.id, canonical);
    if (canonical.parentThreadId) {
      let children = this.childThreadIdsByTopic.get(canonical.parentThreadId);
      if (!children) {
        children = new Set();
        this.childThreadIdsByTopic.set(canonical.parentThreadId, children);
      }
      children.add(canonical.id);
    }
    if (previous?.parentThreadId !== canonical.parentThreadId || !previous) {
      this.onThreadRegistered?.(canonical);
    }
    return true;
  }

  private refreshTopics(topicIds: Set<string>): void {
    for (const topicId of topicIds) {
      const listeners = this.listenersByTopic.get(topicId);
      if (!listeners || listeners.size === 0) {
        // Background topics retain only normalized buckets. Their React-facing
        // projection is rebuilt lazily if a pane later subscribes.
        this.projections.delete(topicId);
        continue;
      }
      const previous = this.projections.get(topicId);
      const next = this.buildProjection(topicId, previous);
      if (previous && previous === next) continue;
      this.projections.set(topicId, next);
      this.versions.set(topicId, (this.versions.get(topicId) ?? 0) + 1);
      for (const listener of listeners) {
        this.listenerWakeCount += 1;
        listener();
      }
    }
  }

  private refreshAgentOverviews(topicIds: Set<string>): void {
    for (const topicId of topicIds) {
      const listeners = this.agentOverviewListenersByTopic.get(topicId);
      const previous = this.agentOverviewSnapshots.get(topicId);
      this.agentOverviewSnapshots.delete(topicId);
      if (!listeners?.size) continue;
      const next = this.getAgentOverview(topicId);
      if (previous && sameAgentOverview(previous, next)) {
        this.agentOverviewSnapshots.set(topicId, previous);
        continue;
      }
      this.agentOverviewVersions.set(topicId, (this.agentOverviewVersions.get(topicId) ?? 0) + 1);
      for (const listener of listeners) {
        this.agentOverviewListenerWakeCount += 1;
        listener();
      }
    }
  }

  private buildProjection(topicId: string, previous?: PanelTranscriptProjection): PanelTranscriptProjection {
    const thread = this.threadsById.get(topicId);
    if (thread?.parentThreadId) {
      const turns = this.getThreadTurns(topicId);
      const threads = [thread];
      const index = new Map([[topicId, turns]]);
      if (previous
        && previous.turns === turns
        && previous.threads.length === 1
        && previous.threads[0] === thread
        && previous.turnsByThreadId.get(topicId) === turns) {
        return previous;
      }
      return { turns, turnsByThreadId: index, threads };
    }
    const scopedThreads = this.topicThreads(topicId);
    const scoped = new Map<string, WorkbenchTurn[]>();
    for (const childThreadId of this.childThreadIdsByTopic.get(topicId) ?? []) {
      scoped.set(childThreadId, this.summaryTurnsByThreadId.get(childThreadId) ?? EMPTY_TURNS);
    }
    const mainTurns = this.getThreadTurns(topicId);
    scoped.set(topicId, mainTurns);
    if (previous && sameProjection(previous, scoped, scopedThreads)) {
      return previous;
    }
    return buildPanelTranscriptProjections({
      activeMainThreadIds: [topicId],
      previous: previous ? new Map([[topicId, previous]]) : undefined,
      threads: scopedThreads,
      turnsByThreadId: this.turnsByThreadId,
      summaryTurnsByThreadId: this.summaryTurnsByThreadId
    }).get(topicId) ?? {
      turns: this.getThreadTurns(topicId),
      turnsByThreadId: new Map([[topicId, this.getThreadTurns(topicId)]]),
      threads: this.threadsById.get(topicId) ? [this.threadsById.get(topicId)!] : EMPTY_THREADS
    };
  }

  private topicThreads(topicId: string): ThreadEntry[] {
    const threads: ThreadEntry[] = [];
    const main = this.threadsById.get(topicId);
    if (main) threads.push(main);
    for (const childThreadId of this.childThreadIdsByTopic.get(topicId) ?? []) {
      const child = this.threadsById.get(childThreadId);
      if (child) threads.push(child);
    }
    return threads;
  }
}

function summarizeTurns(turns: WorkbenchTurn[], previous: WorkbenchTurn[]): WorkbenchTurn[] {
  const boundedTurns = turns.length > MAX_BACKGROUND_TURNS ? turns.slice(-MAX_BACKGROUND_TURNS) : turns;
  const previousById = new Map(previous.map((turn) => [turn.id, turn]));
  const next = boundedTurns.map((turn) => {
    const candidate: WorkbenchTurn = {
      id: turn.id,
      threadId: turn.threadId,
      status: turn.status,
      startedAt: turn.startedAt,
      completedAt: turn.completedAt,
      items: EMPTY_ITEMS
    };
    const old = previousById.get(turn.id);
    return old
      && old.threadId === candidate.threadId
      && old.status === candidate.status
      && old.startedAt === candidate.startedAt
      && old.completedAt === candidate.completedAt
      ? old
      : candidate;
  });
  return previous.length === next.length && previous.every((turn, index) => turn === next[index]) ? previous : next;
}

function summarizeAgentTranscript(
  threadId: string,
  turns: WorkbenchTurn[],
  previous?: AgentTranscriptOverview,
): AgentTranscriptOverview | undefined {
  const latestTurn = turns.at(-1);
  if (!latestTurn) return undefined;
  let latestItem: WorkbenchTurn["items"][number] | undefined;
  for (let turnIndex = turns.length - 1; turnIndex >= 0 && !latestItem; turnIndex -= 1) {
    const items = turns[turnIndex]?.items ?? EMPTY_ITEMS;
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const item = items[itemIndex];
      if (item && (item.text || item.title)) {
        latestItem = item;
        break;
      }
    }
  }
  const candidate: AgentTranscriptOverview = {
    threadId,
    turnId: latestTurn.id,
    itemId: latestItem?.id,
    status: latestTurn.status,
    text: compactAgentOverviewText(latestItem?.text || latestItem?.title || ""),
    itemType: latestItem?.type,
    updatedAt: latestTurn.completedAt ?? latestTurn.startedAt,
  };
  return previous && sameAgentOverviewEntry(previous, candidate) ? previous : candidate;
}

function materializeOverviewTurns(
  turns: WorkbenchTurn[],
  overview?: AgentTranscriptOverview,
): WorkbenchTurn[] {
  if (!overview?.turnId || !overview.itemId || !overview.text) return turns;
  return turns.map((turn) => turn.id !== overview.turnId ? turn : {
    ...turn,
    items: [{
      id: overview.itemId!,
      type: overview.itemType ?? "agentMessage",
      title: overview.itemType === "plan" ? "Plan" : "Codex",
      text: overview.text,
      status: overview.status,
    }],
  });
}

function compactAgentOverviewText(value: string): string {
  const source = value.length > AGENT_OVERVIEW_INPUT_WINDOW
    ? value.slice(-AGENT_OVERVIEW_INPUT_WINDOW)
    : value;
  const compact = source.replace(/\s+/g, " ").trim();
  return compact.length <= MAX_AGENT_OVERVIEW_TEXT
    ? compact
    : `...${compact.slice(-(MAX_AGENT_OVERVIEW_TEXT - 3))}`;
}

function appendAgentOverviewText(current: string, delta: string): string {
  const currentTail = current.length > MAX_AGENT_OVERVIEW_TEXT
    ? current.slice(-MAX_AGENT_OVERVIEW_TEXT)
    : current;
  const deltaTail = delta.length > AGENT_OVERVIEW_INPUT_WINDOW
    ? delta.slice(-AGENT_OVERVIEW_INPUT_WINDOW)
    : delta;
  return compactAgentOverviewText(`${currentTail}${deltaTail}`);
}

function reduceBackgroundTurnLifecycle(
  threadId: string,
  previous: WorkbenchTurn[],
  notifications: JsonRpcNotification[],
): WorkbenchTurn[] {
  let next = previous;
  for (const notification of notifications) {
    if (!isTurnLifecycleNotification(notification) && !isTurnActivityNotification(notification)) continue;
    const params = record(notification.params);
    const wireTurn = record(params.turn);
    const wireItem = record(params.item);
    const turnId = text(wireTurn.id)
      ?? text(params.turnId)
      ?? text(params.turn_id)
      ?? text(wireItem.turnId)
      ?? text(wireItem.turn_id);
    if (!turnId) continue;
    const existing = next.find((turn) => turn.id === turnId);
    if ((notification.method === "turn/started" || isTurnActivityNotification(notification)) && isInterruptedTurnStatus(existing?.status)) continue;
    const started = notification.method === "turn/started" || isTurnActivityNotification(notification);
    const status = text(wireTurn.status) ?? (started ? "inProgress" : terminalTurnStatus(notification.method));
    const candidate: WorkbenchTurn = {
      id: turnId,
      threadId,
      status,
      startedAt: numeric(wireTurn.startedAt) ?? existing?.startedAt ?? (started ? Math.floor(Date.now() / 1000) : undefined),
      completedAt: numeric(wireTurn.completedAt) ?? existing?.completedAt ?? (!started ? Math.floor(Date.now() / 1000) : undefined),
      items: EMPTY_ITEMS,
    };
    next = upsertWorkbenchTurn(next, candidate);
    if (isTurnActivityNotification(notification)) {
      next = next.map((turn) => turn.id === turnId
        ? { ...turn, status: "inProgress", completedAt: undefined }
        : turn);
    }
  }
  return summarizeTurns(next, previous);
}

function isTurnLifecycleNotification(notification: JsonRpcNotification): boolean {
  return notification.method === "turn/started"
    || notification.method === "turn/completed"
    || notification.method === "turn/failed"
    || notification.method === "turn/interrupted";
}

function isTurnActivityNotification(notification: JsonRpcNotification): boolean {
  return notification.method === "item/started"
    || (notification.method === "error" && record(notification.params).willRetry === true);
}

function terminalTurnStatus(method: string): string {
  if (method === "turn/completed") return "completed";
  if (method === "turn/interrupted") return "interrupted";
  return "failed";
}

function isInterruptedTurnStatus(status?: string): boolean {
  return ["interrupted", "cancelled", "canceled"].includes((status ?? "").toLowerCase());
}

function isTerminalAgentOverviewStatus(status: string | undefined): boolean {
  return status === "completed" || status === "failed" || status === "interrupted";
}

function reduceAgentOverview(
  threadId: string,
  notifications: JsonRpcNotification[],
  previous?: AgentTranscriptOverview,
): AgentTranscriptOverview | undefined {
  let next = previous;
  for (const notification of notifications) {
    const params = record(notification.params);
    const wireTurn = record(params.turn);
    const wireItem = record(params.item);
    const turnId = text(params.turnId) ?? text(params.turn_id) ?? text(wireTurn.id)
      ?? text(wireItem.turnId) ?? text(wireItem.turn_id) ?? next?.turnId;
    const itemId = text(params.itemId) ?? text(params.item_id) ?? text(wireItem.id);
    const updatedAt = numeric(wireTurn.completedAt)
      ?? numeric(wireTurn.startedAt)
      ?? numeric(params.completedAt)
      ?? numeric(params.startedAt)
      ?? next?.updatedAt;

    if (notification.method === "turn/started") {
      next = updateAgentOverview(next, threadId, {
        turnId,
        itemId: undefined,
        status: text(wireTurn.status) ?? "inProgress",
        updatedAt,
      });
      continue;
    }
    if (notification.method === "turn/completed"
      || notification.method === "turn/failed"
      || notification.method === "turn/interrupted") {
      next = updateAgentOverview(next, threadId, {
        turnId,
        status: text(wireTurn.status) ?? terminalTurnStatus(notification.method),
        updatedAt,
      });
      continue;
    }
    if (notification.method === "item/started" || notification.method === "item/completed") {
      if (!itemId) continue;
      const sameItem = next?.turnId === turnId && next?.itemId === itemId;
      const itemText = overviewItemText(wireItem);
      const itemTitle = text(wireItem.title) ?? overviewItemTitle(wireItem);
      const replacementText = itemText || (sameItem ? next?.text ?? "" : itemTitle);
      const currentStatus = next?.status;
      next = updateAgentOverview(next, threadId, {
        turnId,
        itemId,
        itemType: overviewItemType(notification.method, wireItem),
        status: notification.method === "item/started"
          ? "inProgress"
          : isTerminalAgentOverviewStatus(currentStatus) && next?.turnId === turnId ? currentStatus : "inProgress",
        text: compactAgentOverviewText(replacementText),
        updatedAt,
      });
      continue;
    }
    if (notification.method === "turn/plan/updated") {
      const planText = overviewPlanText(params);
      next = updateAgentOverview(next, threadId, {
        turnId,
        itemId: turnId ? `turn-plan-${turnId}` : next?.itemId,
        itemType: "plan",
        status: text(params.status) ?? "inProgress",
        text: planText || next?.text || "",
        updatedAt,
      });
      continue;
    }

    const delta = typeof params.delta === "string" ? params.delta : undefined;
    if (delta !== undefined && itemId) {
      const sameItem = next?.turnId === turnId && next?.itemId === itemId;
      next = updateAgentOverview(next, threadId, {
        turnId,
        itemId,
        itemType: overviewDeltaItemType(notification.method),
        status: "inProgress",
        text: appendAgentOverviewText(sameItem ? next?.text ?? "" : "", delta),
        updatedAt,
      });
      continue;
    }

    if (notification.method === "thread/status/changed") {
      const status = text(params.status) ?? text(record(params.thread).status);
      if (status) next = updateAgentOverview(next, threadId, { status, updatedAt });
      continue;
    }
    if (notification.method === "error") {
      const message = text(record(params.error).message) ?? text(params.message);
      next = updateAgentOverview(next, threadId, {
        turnId,
        status: params.willRetry === true ? "running" : "failed",
        text: message ? compactAgentOverviewText(message) : next?.text ?? "",
        updatedAt,
      });
    }
  }
  return next;
}

function updateAgentOverview(
  current: AgentTranscriptOverview | undefined,
  threadId: string,
  patch: Partial<AgentTranscriptOverview>,
): AgentTranscriptOverview {
  const candidate: AgentTranscriptOverview = {
    threadId,
    status: "waiting",
    text: "",
    ...current,
    ...patch,
  };
  return current && sameAgentOverviewEntry(current, candidate) ? current : candidate;
}

function overviewItemText(item: Record<string, unknown>): string {
  const direct = text(item.text) ?? text(item.content);
  if (direct) return compactAgentOverviewText(direct);
  if (!Array.isArray(item.content)) return "";
  let result = "";
  for (const entry of item.content) {
    const part = record(entry);
    const partType = text(part.type) ?? "";
    // 思考块独立成 Thinking 行，概览/正文不重复计入。
    if (partType === "reasoning" || partType === "reasoning_text" || partType === "thinking") continue;
    const value = text(part.text) ?? text(part.input_text) ?? text(part.output_text);
    if (value) result = appendAgentOverviewText(result, value);
  }
  return result;
}

function overviewItemTitle(item: Record<string, unknown>): string {
  const type = text(item.type) ?? "";
  if (type.includes("command")) return text(item.command) ?? "Command";
  if (type.includes("file")) return "File change";
  if (type.includes("plan")) return "Plan";
  if (type.includes("reasoning")) return "Reasoning";
  if (type === "toolCall" || type === "toolUse" || type === "tool_use") return text(item.toolName) ?? text(item.name) ?? "Tool";
  return "";
}

function overviewItemType(method: string, item: Record<string, unknown>): string | undefined {
  const type = text(item.type);
  if (type === "message") return text(item.role) === "user" ? "userMessage" : "agentMessage";
  return type ?? overviewDeltaItemType(method);
}

function overviewDeltaItemType(method: string): string | undefined {
  if (method.includes("agentMessage")) return "agentMessage";
  if (method.includes("plan")) return "plan";
  if (method.includes("command")) return "commandExecution";
  if (method.includes("reasoning")) return "reasoning";
  if (method.includes("fileChange")) return "fileChange";
  return undefined;
}

function overviewPlanText(params: Record<string, unknown>): string {
  let result = text(params.explanation) ?? "";
  for (const entry of Array.isArray(params.plan) ? params.plan : []) {
    const step = record(entry);
    const label = text(step.step) ?? text(step.text);
    if (label) result = appendAgentOverviewText(result, ` ${label}`);
  }
  return compactAgentOverviewText(result);
}

function sameAgentOverview(
  previous: ReadonlyMap<string, AgentTranscriptOverview>,
  next: ReadonlyMap<string, AgentTranscriptOverview>,
): boolean {
  if (previous.size !== next.size) return false;
  for (const [threadId, overview] of previous) {
    if (next.get(threadId) !== overview) return false;
  }
  return true;
}

function sameAgentOverviewEntry(previous: AgentTranscriptOverview, next: AgentTranscriptOverview): boolean {
  return previous.threadId === next.threadId
    && previous.turnId === next.turnId
    && previous.itemId === next.itemId
    && previous.status === next.status
    && previous.text === next.text
    && previous.itemType === next.itemType
    && previous.updatedAt === next.updatedAt;
}

function mergeThreadEntry(previous: ThreadEntry, incoming: ThreadEntry): ThreadEntry {
  const supplied = Object.fromEntries(
    Object.entries(incoming).filter(([, value]) => value !== undefined)
  ) as Partial<ThreadEntry>;
  return { ...previous, ...supplied, id: incoming.id };
}

function sameThreadEntry(previous: ThreadEntry, next: ThreadEntry): boolean {
  return previous.id === next.id
    && previous.sessionId === next.sessionId
    && previous.title === next.title
    && previous.name === next.name
    && previous.preview === next.preview
    && previous.model === next.model
    && previous.modelProvider === next.modelProvider
    && previous.parentThreadId === next.parentThreadId
    && previous.forkedFromId === next.forkedFromId
    && previous.agentNickname === next.agentNickname
    && previous.agentRole === next.agentRole
    && previous.createdAt === next.createdAt
    && previous.updatedAt === next.updatedAt
    && previous.recencyAt === next.recencyAt
    && previous.status === next.status
    && previous.cwd === next.cwd
    && previous.source === next.source
    && previous.threadSource === next.threadSource
    && previous.path === next.path
    && previous.historyMode === next.historyMode;
}

export function useTopicTranscript(
  store: TopicTranscriptStore,
  topicId: string | null,
): PanelTranscriptProjection {
  const subscribe = useCallback((listener: Listener) => store.subscribe(topicId, listener), [store, topicId]);
  const getSnapshot = useCallback(() => store.getVersion(topicId), [store, topicId]);
  useSyncExternalStore(
    subscribe,
    getSnapshot,
    getSnapshot
  );
  return store.getProjection(topicId);
}

export function useAgentTranscriptOverview(
  store: TopicTranscriptStore,
  topicId: string | null,
): ReadonlyMap<string, AgentTranscriptOverview> {
  const subscribe = useCallback((listener: Listener) => store.subscribeAgentOverview(topicId, listener), [store, topicId]);
  const getSnapshot = useCallback(() => store.getAgentOverviewVersion(topicId), [store, topicId]);
  useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  return store.getAgentOverview(topicId);
}

function record(value: JsonValue | unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}

function numeric(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
