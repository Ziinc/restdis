// Demo 1: a plain TanStack Query app. The only Restdis-specific code is the
// URL: reads go to Restdis's /pgrst/query endpoint instead of PostgREST.
import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { createRoot } from "react-dom/client";

const RESTDIS = "/restdis";
const POSTGREST = "/rest";
const API_KEY = "sk_demo";
const PATH = "products?select=id,name,price&order=id";

const queryClient = new QueryClient();

function App() {
  const [log, setLog] = useState([]);

  const products = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const started = performance.now();
      const res = await fetch(`${RESTDIS}/pgrst/query?path=${encodeURIComponent(PATH)}`, {
        headers: { authorization: `Bearer ${API_KEY}` },
      });
      const rows = await res.json();
      const entry = { cache: res.headers.get("sc-cache"), ms: performance.now() - started };
      setLog((prev) => [...prev, entry]);
      return rows;
    },
  });

  // Another service writing straight to Postgres (through PostgREST), not
  // through Restdis. Restdis sees the write in the WAL and evicts the entry.
  const reprice = useMutation({
    mutationFn: (price) =>
      fetch(`${POSTGREST}/products?id=eq.1`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ price }),
      }),
  });

  const espresso = products.data?.find((p) => p.id === 1);

  return (
    <div className="app">
      <h2>Menu</h2>
      <p className="sub">
        <code>useQuery</code> reads <code>/{PATH}</code> through Restdis
      </p>
      <table>
        <thead><tr><th>id</th><th>name</th><th>price</th></tr></thead>
        <tbody>
          {products.data?.map((p) => (
            <tr key={`${p.id}-${p.price}`} className="flash">
              <td>{p.id}</td><td>{p.name}</td><td>${(p.price / 100).toFixed(2)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="row">
        <button id="refetch" className="primary" onClick={() => products.refetch()}>refetch()</button>
        <button id="write" className="danger" onClick={() => reprice.mutate((espresso?.price ?? 300) + 25)}>
          Another service raises the Espresso price
        </button>
      </div>
      <table className="log">
        <thead><tr><th>fetch</th><th>sc-cache</th><th>browser round trip</th></tr></thead>
        <tbody>
          {log.map((e, i) => (
            <tr key={i} className="flash">
              <td>#{i + 1}</td>
              <td><span className={`badge ${e.cache}`}>{e.cache}</span></td>
              <td>{e.ms.toFixed(1)} ms</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

createRoot(document.getElementById("root")).render(
  <QueryClientProvider client={queryClient}><App /></QueryClientProvider>
);
