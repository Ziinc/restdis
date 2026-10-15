// Demo 1: supabase-js inside TanStack Query. The app code is ordinary
// supabase-js; restdisFetch sends its reads through Restdis.
import "./console.js";
import { createClient } from "@supabase/supabase-js";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { restdisFetch } from "./restdis-fetch.js";

const supabase = createClient(`${location.origin}/supabase`, "sk_demo", {
  auth: { persistSession: false },
  global: { fetch: restdisFetch },
});

const queryClient = new QueryClient();

function App() {
  const products = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("id,name,price").order("id");
      if (error) throw error;
      console.log(`supabase.from("products").select() returned ${data.length} rows`);
      return data;
    },
  });

  // Another service writing straight to Postgres through PostgREST, outside
  // this app. Restdis sees the write in the WAL and evicts the cached read.
  const reprice = () => {
    const espresso = products.data?.find((p) => p.id === 1);
    return window.rawFetch("/rest/products?id=eq.1", {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ price: (espresso?.price ?? 300) + 25 }),
    });
  };

  return (
    <div className="app">
      <h2>Menu</h2>
      <p className="sub">
        <code>supabase.from("products").select()</code> in <code>useQuery</code>, with reads routed through Restdis
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
        <button id="write" className="danger" onClick={reprice}>Another service raises the Espresso price</button>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")).render(
  <QueryClientProvider client={queryClient}><App /></QueryClientProvider>
);
