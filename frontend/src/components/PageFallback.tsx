/** Lightweight shell shown while route chunks hydrate. */
export function PageFallback({ label = "Loading…" }: { label?: string }) {
  return (
    <main className="page-wrap">
      <div className="panel panel-loading">
        <div className="panel-head">
          <h2>{label}</h2>
          <p className="muted">Preparing view…</p>
        </div>
        <div className="skeleton-block" style={{ height: "12rem", borderRadius: "0.75rem" }} />
      </div>
    </main>
  );
}
