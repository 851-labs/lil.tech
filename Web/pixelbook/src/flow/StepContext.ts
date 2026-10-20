import { createContext } from "react";

/** `useSteps`'s function, for the screens' nodes. */
export const StepContext = createContext<(key: string, steps: number) => void>(() => {});
