// Demo 2: TanStack DB syncing through @tanstack/electric-db-collection. It is
// the stock Electric setup; only shapeOptions.url points at Restdis. Two
// independent clients (A and B) subscribe to the same shape, the way two
// users' browsers would.
import "./console.js";
import { electricCollectionOptions } from "@tanstack/electric-db-collection";
import { createCollection, eq, useLiveQuery } from "@tanstack/react-db";
import { useEffect } from "react";
import { createRoot } from "react-dom/client";

const RESTDIS = new URL("/restdis", location.origin).href;
const POSTGREST = "/rest";
const API_KEY = "sk_demo";

const todosFor = (client) =>
  createCollection(
    electricCollectionOptions({
      id: `todos-${client}`,
      getKey: (todo) => todo.id,
      shapeOptions: {
        url: `${RESTDIS}/v1/shape`,
        params: { table: "todos" },
        headers: { authorization: `Bearer ${API_KEY}`, "x-demo-client": client },
        // Two users' browsers don't share an HTTP cache; keep these clients apart too.
        fetchClient: (input, init) => fetch(input, { ...init, cache: "no-store" }),
      },
    })
  );

const clients = { A: todosFor("A"), B: todosFor("B") };

// Another user writing straight to Postgres through PostgREST. Restdis reads
// each write from the WAL and pushes it to every open shape. It uses
// window.rawFetch so it stays out of this app's console.
const write = (method, path, body) =>
  window.rawFetch(`${POSTGREST}/${path}`, {
    method,
    headers: { "content-type": "application/json", prefer: "return=minimal" },
    body: body && JSON.stringify(body),
  });

const actions = {
  add: () => write("POST", "todos", { id: 3, title: "Ship the demo", done: false }),
  rename: () => write("PATCH", "todos?id=eq.3", { title: "Ship the demo video" }),
  complete: () => write("PATCH", "todos?id=eq.2", { done: true }),
  bulk: () =>
    write("POST", "todos", [
      { id: 4, title: "Write the changelog", done: false },
      { id: 5, title: "Tag the release", done: false },
      { id: 6, title: "Tell the team", done: false },
    ]),
  remove: () => write("DELETE", "todos?id=eq.1"),
};

function TodoList({ client }) {
  const todos = clients[client];
  const { data: all } = useLiveQuery((q) => q.from({ todo: todos }).orderBy(({ todo }) => todo.id));
  const { data: open } = useLiveQuery((q) =>
    q.from({ todo: todos }).where(({ todo }) => eq(todo.done, false))
  );

  useEffect(() => {
    if (all.length) console.log(`[${client}] useLiveQuery: ${all.length} todos, ${open.length} open`);
  }, [client, all.length, open.length]);

  return (
    <div className="client">
      <h3><span className={`tag ${client}`}>{client}</span> Client {client} <small>{open.length} open</small></h3>
      <table>
        <tbody>
          {all.map((t) => (
            <tr key={`${t.id}-${t.done}-${t.title}`} className="flash">
              <td className="id">{t.id}</td>
              <td className={t.done ? "done" : ""}>{t.title}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function App() {
  return (
    <div className="app">
      <h2>Todos</h2>
      <p className="sub">
        Two clients, each a <code>useLiveQuery</code> over its own <code>electricCollectionOptions</code> collection
        synced from Restdis
      </p>
      <div className="clients">
        <TodoList client="A" />
        <TodoList client="B" />
      </div>
      <div className="row">
        <span className="who">Another user:</span>
        <button id="add" className="danger" onClick={actions.add}>insert</button>
        <button id="rename" className="danger" onClick={actions.rename}>update title</button>
        <button id="complete" className="danger" onClick={actions.complete}>complete</button>
        <button id="bulk" className="danger" onClick={actions.bulk}>insert 3</button>
        <button id="remove" className="danger" onClick={actions.remove}>delete</button>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
