/** `localStorage`, which may be unavailable (blocked, or a sandbox): then nothing is remembered. */
export const storage = {
  get: (key: string) => {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set: (key: string, value: string) => {
    try {
      localStorage.setItem(key, value);
    } catch {
      // Not remembered.
    }
  },
};
