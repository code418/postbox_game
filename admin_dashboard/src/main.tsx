import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource/plus-jakarta-sans/400.css";
import "@fontsource/plus-jakarta-sans/600.css";
import "@fontsource/plus-jakarta-sans/700.css";
import "@fontsource/playfair-display/700.css";
import "leaflet/dist/leaflet.css";
import "./styles.css";
import { App } from "./App.tsx";

// Pasting a fresh link from a restarted server into this tab only changes the
// hash, which doesn't reload the page: reload so the new token is picked up.
window.addEventListener("hashchange", () => {
  if (/(?:^#|&)t=/.test(window.location.hash)) window.location.reload();
});

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
