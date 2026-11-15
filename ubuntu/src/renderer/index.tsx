import { render } from "preact";
import "@fontsource/roboto-condensed/600.css";
import "@fontsource/roboto-condensed/700.css";
import "@fontsource/roboto-condensed/800.css";
import "./styles.css";
import { MainWindow } from "./main-window";
import { FullscreenView, OverlayView } from "./ride";
import { connect, useSnapshot, useWindowSize } from "./store";

const errors: string[] = ((window as any).__bikeErrors = []);
window.addEventListener("error", (e) => errors.push(String(e.error?.stack ?? e.message)));
window.addEventListener("unhandledrejection", (e) => errors.push(String(e.reason?.stack ?? e.reason)));

const view = new URLSearchParams(location.search).get("view") ?? "main";
document.documentElement.dataset.view = view;

function App() {
  const { state, ride, history } = useSnapshot();
  useWindowSize();
  if (!state) return null;
  if (view === "overlay") return <OverlayView state={state} ride={ride} />;
  if (view === "fullscreen") return <FullscreenView state={state} ride={ride} />;
  return <MainWindow state={state} ride={ride} history={history} />;
}

connect();
render(<App />, document.getElementById("app")!);
