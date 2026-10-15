// Demo 2: a TanStack DB app syncing through @tanstack/electric-db-collection.
// It is the stock Electric setup; only shapeOptions.url points at Restdis.
import "./console.js";
import { electricCollectionOptions } from "@tanstack/electric-db-collection";
import { createCollection, eq, useLiveQuery } from "@tanstack/react-db";
import { useEffect } from "react";
import { createRoot } from "react-dom/client";

const RESTDIS = new URL("/restdis", location.origin).href;
const POSTGREST = "/rest";
const API_KEY = "sk_demo";

const todos = createCollection(
  electricCollectionOptions({
    id: "todos",
    getKey: (todo) => todo.id,
    shapeOptions: {
      url: `${RESTDIS}/v1/shape`,
      params: { table: "todos" },
      headers: { authorization: `Bearer ${API_KEY}` },
    },
  })
);

// Another user writing straight to Postgres (through PostgREST). Restdis
// reads the write from the WAL and pushes it to every open shape.
// It uses window.rawFetch so it stays out of this app's console.
const write = (method, path, body) =>
  window.rawFetch(`${POSTGREST}/${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

function App() {
  const { data: all } = useLiveQuery((q) =>
    q.from({ todo: todos }).orderBy(({ todo }) => todo.id)
  );
  const { data: open } = useLiveQuery((q) =>
    q.from({ todo: todos }).where(({ todo }) => eq(todo.done, false))
  );
  const nextId = Math.max(0, ...all.map((t) => t.id)) + 1;

  useEffect(() => {
    if (all.length) console.log(`useLiveQuery: ${all.length} todos, ${open.length} open`);
  }, [all.length, open.length]);

  return (
    <div className="app">
      <h2>Todos</h2>
      <p className="sub">
        <code>useLiveQuery</code> over an <code>electricCollectionOptions</code> collection synced from Restdis
      </p>
      <table>
        <thead><tr><th>id</th><th>title</th><th>done</th></tr></thead>
        <tbody>
          {all.map((t) => (
            <tr key={`${t.id}-${t.done}-${t.title}`} className="flash">
              <td>{t.id}</td>
              <td className={t.done ? "done" : ""}>{t.title}</td>
              <td>{t.done ? "yes" : "no"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p><b id="open-count">{open.length}</b> open (a second live query, filtered in the browser)</p>
      <div className="row">
        <button id="add" className="danger" onClick={() => write("POST", "todos", { id: nextId, title: `Ship demo ${nextId}`, done: false })}>
          Another user adds a todo
        </button>
        <button id="complete" className="danger" onClick={() => write("PATCH", "todos?id=eq.2", { done: true })}>
          Another user completes todo 2
        </button>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
