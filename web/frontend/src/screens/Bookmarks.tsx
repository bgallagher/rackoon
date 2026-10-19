// Bookmarks: every container's Homepage labels (gethomepage.dev), grouped by homepage.group. Editing writes the
// labels into the service's compose file; the sheet after this one shows the diff.
import { useState } from "react";
import { api } from "../api";
import { BookmarkSheet, DockerProblem, SiteIcon, useAction } from "../components/docker";
import { Button, CopyButton, Empty, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { usePoll } from "../hooks";
import type { BookmarkItem, DockerState, Server } from "../types";

export function groupsOf(items: BookmarkItem[]): [string, BookmarkItem[]][] {
  const groups = new Map<string, BookmarkItem[]>();
  for (const item of items) {
    const g = item.bookmark.group ?? "Other";
    groups.set(g, [...(groups.get(g) ?? []), item]);
  }
  return [...groups.entries()].sort(([a], [b]) => (a === "Other" ? 1 : b === "Other" ? -1 : a.localeCompare(b)));
}

export function BookmarkRow(props: { item: BookmarkItem; onEdit?: () => void; onRemove?: () => void }) {
  const b = props.item.bookmark;
  const name = b.name ?? props.item.service ?? props.item.container;
  return (
    <li className="bookmark">
      <SiteIcon href={b.href} letter={name[0]?.toUpperCase() ?? "?"} hue={210} size={30} />
      <div className="bookmark-text">
        <a href={b.href} target="_blank" rel="noreferrer noopener"><strong>{name}</strong></a>
        <span className="dim">{props.item.address} <span className={`badge badge-${props.item.scope}`}>{props.item.scope}</span></span>
        {b.description && <span className="dim">{b.description}</span>}
      </div>
      <div className="row-actions">
        <CopyButton text={b.href} label="address" />
        {props.onEdit && <Button small onClick={props.onEdit}>Edit</Button>}
        {props.onRemove && <Button small kind="quiet" onClick={props.onRemove}>Remove</Button>}
      </div>
    </li>
  );
}

export function BookmarksScreen(props: { server: Server }) {
  const app = useApp();
  const base = `/api/servers/${props.server.id}/docker`;
  const { data, error, reload } = usePoll(() => api.get<DockerState>(`${base}?watch=true`), 8000, [props.server.id]);
  const [editing, setEditing] = useState<BookmarkItem | "new">();
  const action = useAction(() => void reload());
  if (!data) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const readOnly = app.safety?.readOnly ?? true;
  const items = data.bookmarks ?? [];
  const services = data.stacks.filter((s) => !s.isStandalone && !s.notStarted).flatMap((s) =>
    s.containers.filter((c) => c.service && !c.bookmark).map((c) => ({ stackId: s.id, stackName: s.name, service: c.service! })));
  const save = (target: { stackId: string; service: string }, bookmark: unknown, apply: boolean) => {
    setEditing(undefined);
    void action.request(`${base}/bookmark`, { ...target, bookmark, apply });
  };
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Bookmarks</h1>
          <p className="muted">From the Homepage labels (homepage.href, .name, .group) of {props.server.name}'s containers.</p>
        </div>
        <Button kind="primary" disabled={readOnly || services.length === 0}
                title={readOnly ? "Read-only mode is on" : undefined} onClick={() => setEditing("new")}>Add Bookmark</Button>
      </header>
      <DockerProblem state={data} server={props.server} />
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      {data.status === "ready" && items.length === 0 && (
        <Empty title="No bookmarks yet"><p>Add one to a service and it is written as Homepage labels in its compose file.</p></Empty>
      )}
      <div className="bookmark-groups">
        {groupsOf(items).map(([group, list]) => (
          <section key={group} className="card">
            <h3>{group}</h3>
            <ul className="bookmarks">
              {list.map((item) => (
                <BookmarkRow key={`${item.containerId}`} item={item}
                             onEdit={item.editable ? () => setEditing(item) : undefined}
                             onRemove={item.editable && !readOnly && item.service
                               ? () => void action.request(`${base}/bookmark`, { stackId: item.stackId, service: item.service, bookmark: null, apply: true })
                               : undefined} />
              ))}
            </ul>
          </section>
        ))}
      </div>
      {editing === "new" && (
        <BookmarkSheet title="Add a bookmark" services={services} readOnly={readOnly} onCancel={() => setEditing(undefined)}
                       onSubmit={save} />
      )}
      {editing && editing !== "new" && editing.service && (
        <BookmarkSheet title={`Bookmark for ${editing.service}`} initial={editing.bookmark} readOnly={readOnly}
                       fixed={{ stackId: editing.stackId, service: editing.service }}
                       onCancel={() => setEditing(undefined)} onSubmit={save} />
      )}
      {action.sheet}
    </div>
  );
}
