import { describe, expect, it } from "vite-plus/test";
import { type KeyPress, shortcutFor } from "../src/lib/Keys.ts";

const press = (key: string, modifiers: Partial<KeyPress> = {}): KeyPress => ({
  key,
  code: "",
  shiftKey: false,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  repeat: false,
  ...modifiers,
});
const action = (key: KeyPress, helpShown = false) => shortcutFor(key, helpShown)?.action;

describe("shortcuts", () => {
  it("moves the selection with the arrow keys, without modifiers", () => {
    expect(shortcutFor(press("ArrowLeft"), false)).toEqual({ action: "move", direction: "left" });
    expect(shortcutFor(press("ArrowDown"), false)).toEqual({ action: "move", direction: "down" });
    expect(action(press("ArrowRight", { shiftKey: true }))).toBeUndefined();
    expect(action(press("ArrowRight", { metaKey: true }))).toBeUndefined();
    expect(action(press("ArrowUp", { altKey: true }))).toBeUndefined();
  });

  it("deselects with Escape", () => {
    expect(action(press("Escape"))).toBe("deselect");
    expect(action(press("Escape", { repeat: true }))).toBe("deselect");
  });

  it("fits with ⇧1 and zooms to the selection with ⇧2, by the key's position", () => {
    expect(action(press("!", { code: "Digit1", shiftKey: true }))).toBe("fit");
    expect(action(press("@", { code: "Digit2", shiftKey: true }))).toBe("zoomToSelection");
    // On a French keyboard, ⇧1 types 1.
    expect(action(press("1", { code: "Digit1", shiftKey: true }))).toBe("fit");
    expect(action(press("1", { code: "Digit1" }))).toBeUndefined();
    expect(action(press("!", { code: "Digit1", shiftKey: true, metaKey: true }))).toBeUndefined();
  });

  it("zooms with + and −, also with ⌘ or Control, but not Option", () => {
    expect(action(press("+", { shiftKey: true }))).toBe("zoomIn");
    expect(action(press("="))).toBe("zoomIn");
    expect(action(press("=", { metaKey: true }))).toBe("zoomIn");
    expect(action(press("-"))).toBe("zoomOut");
    expect(action(press("_", { shiftKey: true }))).toBe("zoomOut");
    expect(action(press("-", { ctrlKey: true }))).toBe("zoomOut");
    expect(action(press("=", { altKey: true }))).toBeUndefined();
  });

  it("shows and hides the list with ?, once per press", () => {
    expect(action(press("?", { shiftKey: true }))).toBe("help");
    expect(action(press("?", { shiftKey: true }), true)).toBe("help");
    expect(action(press("?", { shiftKey: true, repeat: true }))).toBeUndefined();
    expect(action(press("?", { shiftKey: true, metaKey: true }))).toBeUndefined();
  });

  it("leaves the other keys to the list while it's shown", () => {
    for (const key of [
      press("Escape"),
      press("ArrowLeft"),
      press("!", { code: "Digit1", shiftKey: true }),
      press("+"),
    ])
      expect(action(key, true)).toBeUndefined();
  });

  it("isn't other keys", () => {
    expect(action(press("a"))).toBeUndefined();
    expect(action(press(" "))).toBeUndefined();
    expect(action(press("Enter"))).toBeUndefined();
  });
});
