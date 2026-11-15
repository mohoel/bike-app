import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("bike", {
  init: () => ipcRenderer.invoke("bike:init"),
  action: (name: string, ...args: unknown[]) => ipcRenderer.invoke("bike:action", name, ...args),
  on: (channel: "state" | "ride" | "history" | "nav", listener: (payload: unknown) => void) => {
    const wrapped = (_event: unknown, payload: unknown) => listener(payload);
    ipcRenderer.on(channel, wrapped);
    return () => ipcRenderer.removeListener(channel, wrapped);
  },
});
