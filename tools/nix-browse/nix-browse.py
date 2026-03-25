#!/usr/bin/env python3
"""Interactive split-screen Nix store path browser.

Left pane:  dependency tree (expand/collapse with Enter)
Right pane: content preview (JSON-formatted files, directory listings)

Usage: nix-browse.py <store-path-or-symlink>
"""

import curses
import json
import os
import subprocess
import sys


# ── Store graph ──────────────────────────────────────────────────────────

def resolve_path(path):
    """Follow symlinks to get the real store path."""
    return os.path.realpath(path)


def get_references(path):
    """Get direct references of a store path via nix-store."""
    try:
        out = subprocess.check_output(
            ["nix-store", "-q", "--references", path],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        refs = [r for r in out.strip().split("\n") if r and r != path]
        refs.sort(key=lambda p: store_name(p).lower())
        return refs
    except subprocess.CalledProcessError:
        return []


def store_name(path):
    """Extract the human-readable part of a store path (after hash-)."""
    base = os.path.basename(path)
    if len(base) > 33 and base[32] == "-":
        return base[33:]
    return base


# ── Tree model ───────────────────────────────────────────────────────────

class TreeNode:
    __slots__ = ("path", "name", "children", "expanded", "depth", "loaded")

    def __init__(self, path, depth=0):
        self.path = path
        self.name = store_name(path)
        self.children = []
        self.depth = depth
        self.expanded = False
        self.loaded = False

    def ensure_children(self):
        if not self.loaded:
            self.loaded = True
            refs = get_references(self.path)
            self.children = [TreeNode(r, self.depth + 1) for r in refs]

    def toggle(self):
        self.ensure_children()
        self.expanded = not self.expanded


def flatten_visible(root):
    """Flatten the tree into the currently visible rows."""
    rows = []

    def walk(node):
        rows.append(node)
        if node.expanded:
            for child in node.children:
                walk(child)

    walk(root)
    return rows


# ── Preview logic ────────────────────────────────────────────────────────

def preview_for(path):
    """Return (lines, title) for the right pane."""
    if not os.path.exists(path):
        return [f"Path does not exist: {path}"], "error"

    # Single file
    if os.path.isfile(path):
        return preview_file(path), os.path.basename(path)

    # Directory
    if os.path.isdir(path):
        entries = sorted(os.listdir(path))

        # Single-file directory → preview that file
        real_files = [e for e in entries if os.path.isfile(os.path.join(path, e))]
        if len(real_files) == 1:
            fp = os.path.join(path, real_files[0])
            lines = preview_file(fp)
            return [f"── {real_files[0]} ──", ""] + lines, real_files[0]

        # List contents
        lines = []
        for entry in entries:
            full = os.path.join(path, entry)
            if os.path.isdir(full):
                lines.append(f"  📁 {entry}/")
            elif os.path.islink(full):
                target = os.readlink(full)
                lines.append(f"  🔗 {entry} → {target}")
            else:
                size = format_size(os.path.getsize(full))
                lines.append(f"  📄 {entry}  ({size})")
        return lines, f"{len(entries)} entries"

    return ["(unknown path type)"], "?"


def preview_file(path):
    """Read a file and return lines, trying JSON pretty-print first."""
    try:
        size = os.path.getsize(path)
        if size > 512 * 1024:
            return [f"(file too large: {format_size(size)})"]
        with open(path, "r") as f:
            raw = f.read()
    except (OSError, UnicodeDecodeError):
        return ["(binary or unreadable file)"]

    # Try JSON
    try:
        obj = json.loads(raw)
        formatted = json.dumps(obj, indent=2, ensure_ascii=False)
        return formatted.split("\n")
    except (json.JSONDecodeError, ValueError):
        pass

    # Plain text
    return raw.split("\n")


def format_size(nbytes):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if nbytes < 1024:
            return f"{nbytes:.0f} {unit}" if unit == "B" else f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TiB"


# ── TUI ──────────────────────────────────────────────────────────────────

TREE_RATIO = 0.4  # left pane width fraction

# Key constants for portability
KEY_ENTER = (curses.KEY_ENTER, 10, 13)


def draw_tree_row(win, y, x, node, width, selected, is_search_match=False):
    """Draw a single tree row."""
    indent = "  " * node.depth
    node.ensure_children()
    if node.children:
        icon = "▼ " if node.expanded else "▶ "
    else:
        icon = "  "
    label = f"{indent}{icon}{node.name}"
    label = label[:width]

    attr = curses.A_NORMAL
    if selected:
        attr = curses.color_pair(1) | curses.A_BOLD
    elif is_search_match:
        attr = curses.color_pair(3)
    try:
        win.addnstr(y, x, label, width, attr)
    except curses.error:
        pass


def draw_preview(win, lines, scroll, title=""):
    """Draw the right-pane preview."""
    h, w = win.getmaxyx()
    win.erase()

    # Title bar
    title_bar = f" {title} " if title else ""
    title_bar = title_bar[:w]
    try:
        win.addnstr(0, 0, title_bar, w, curses.color_pair(2) | curses.A_BOLD)
        # Fill rest of title line
        remaining = w - len(title_bar)
        if remaining > 0:
            win.addstr(0, len(title_bar), " " * (remaining - 1), curses.color_pair(2))
    except curses.error:
        pass

    # Content
    for i in range(1, h):
        line_idx = scroll + (i - 1)
        if line_idx >= len(lines):
            break
        line = lines[line_idx].replace("\t", "    ")
        line = line[:w - 1]
        try:
            win.addnstr(i, 0, line, w - 1)
        except curses.error:
            pass

    win.nfoutrefresh()


def main(stdscr, root_path):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)    # selected row
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_GREEN)   # title bar
    curses.init_pair(3, curses.COLOR_YELLOW, -1)                  # search match
    curses.init_pair(4, curses.COLOR_BLACK, curses.COLOR_YELLOW)  # search bar

    root = TreeNode(root_path)
    root.expanded = True
    root.ensure_children()

    cursor = 0
    preview_scroll = 0
    search_query = ""
    search_mode = False
    search_matches = set()  # indices into visible rows

    # Cache to avoid re-computing preview on every render
    preview_cache_path = None
    preview_cache = ([], "")

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        tree_w = max(int(w * TREE_RATIO), 20)
        preview_w = w - tree_w - 1  # 1 col for divider

        visible = flatten_visible(root)
        if not visible:
            break

        # Clamp cursor
        cursor = max(0, min(cursor, len(visible) - 1))

        # Recompute search matches
        if search_query:
            search_matches = set()
            q = search_query.lower()
            for i, node in enumerate(visible):
                if q in node.name.lower():
                    search_matches.add(i)
        else:
            search_matches = set()

        # Tree scroll offset
        tree_area_h = h - (1 if search_mode or search_query else 0)
        tree_scroll = 0
        if cursor >= tree_area_h:
            tree_scroll = cursor - tree_area_h + 1

        # Draw tree
        for i in range(tree_area_h):
            row_idx = tree_scroll + i
            if row_idx >= len(visible):
                break
            draw_tree_row(
                stdscr, i, 0, visible[row_idx], tree_w,
                selected=(row_idx == cursor),
                is_search_match=(row_idx in search_matches),
            )

        # Draw search bar at bottom if active
        if search_mode or search_query:
            search_y = h - 1
            prompt = f" /{search_query}"
            prompt = prompt[:tree_w]
            attr = curses.color_pair(4) if search_mode else curses.color_pair(2)
            try:
                stdscr.addnstr(search_y, 0, prompt, tree_w, attr)
                pad = tree_w - len(prompt)
                if pad > 0:
                    stdscr.addstr(search_y, len(prompt), " " * pad, attr)
            except curses.error:
                pass

        # Draw divider
        for y in range(h):
            try:
                stdscr.addch(y, tree_w, "│", curses.A_DIM)
            except curses.error:
                pass

        # Preview
        selected_node = visible[cursor]
        if selected_node.path != preview_cache_path:
            preview_cache_path = selected_node.path
            preview_lines, preview_title = preview_for(selected_node.path)
            preview_cache = (preview_lines, preview_title)
            preview_scroll = 0
        else:
            preview_lines, preview_title = preview_cache

        # Draw preview directly on stdscr
        px = tree_w + 1
        # Title
        title_bar = f" {preview_title} " if preview_title else ""
        title_bar = title_bar[:preview_w]
        try:
            stdscr.addnstr(0, px, title_bar, preview_w, curses.color_pair(2) | curses.A_BOLD)
            remaining = preview_w - len(title_bar)
            if remaining > 0:
                stdscr.addstr(0, px + len(title_bar), " " * (remaining - 1), curses.color_pair(2))
        except curses.error:
            pass

        # Preview content
        for i in range(1, h):
            line_idx = preview_scroll + (i - 1)
            if line_idx >= len(preview_lines):
                break
            line = preview_lines[line_idx].replace("\t", "    ")
            line = line[:preview_w - 1]
            try:
                stdscr.addnstr(i, px, line, preview_w - 1)
            except curses.error:
                pass

        # Path bar at bottom-right
        path_str = f" {selected_node.path} "
        try:
            stdscr.addnstr(h - 1, px, path_str[:preview_w], preview_w,
                           curses.color_pair(2))
            pad = preview_w - len(path_str)
            if pad > 0:
                stdscr.addstr(h - 1, px + len(path_str),
                              " " * (pad - 1), curses.color_pair(2))
        except curses.error:
            pass

        stdscr.refresh()

        # ── Input ──
        key = stdscr.getch()

        if search_mode:
            if key in (27,):  # Escape
                search_mode = False
                search_query = ""
            elif key in KEY_ENTER:
                search_mode = False
                # Jump to first match after cursor
                if search_matches:
                    forward = sorted(i for i in search_matches if i > cursor)
                    if forward:
                        cursor = forward[0]
                    else:
                        cursor = min(search_matches)
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                search_query = search_query[:-1]
                if not search_query:
                    search_mode = False
            elif 32 <= key < 127:
                search_query += chr(key)
            continue

        if key == ord("q"):
            break
        elif key == curses.KEY_UP or key == ord("k"):
            cursor = max(0, cursor - 1)
            preview_scroll = 0
        elif key == curses.KEY_DOWN or key == ord("j"):
            cursor = min(len(visible) - 1, cursor + 1)
            preview_scroll = 0
        elif key in KEY_ENTER or key == curses.KEY_RIGHT or key == ord("l"):
            node = visible[cursor]
            if key in KEY_ENTER:
                node.toggle()
            else:
                # Right arrow: expand only
                if not node.expanded:
                    node.ensure_children()
                    if node.children:
                        node.expanded = True
        elif key == curses.KEY_LEFT or key == ord("h"):
            node = visible[cursor]
            if node.expanded:
                node.expanded = False
            else:
                # Go to parent
                for i in range(cursor - 1, -1, -1):
                    if visible[i].depth < node.depth:
                        cursor = i
                        break
        elif key == ord("/"):
            search_mode = True
            search_query = ""
        elif key == ord("n"):
            # Next search match
            if search_matches:
                forward = sorted(i for i in search_matches if i > cursor)
                if forward:
                    cursor = forward[0]
                else:
                    cursor = min(search_matches)
        elif key == ord("N"):
            # Previous search match
            if search_matches:
                backward = sorted((i for i in search_matches if i < cursor), reverse=True)
                if backward:
                    cursor = backward[0]
                else:
                    cursor = max(search_matches)
        elif key == ord("J") or key == curses.KEY_NPAGE:
            # Scroll preview down
            preview_scroll = min(preview_scroll + 10, max(0, len(preview_lines) - h + 2))
        elif key == ord("K") or key == curses.KEY_PPAGE:
            # Scroll preview up
            preview_scroll = max(0, preview_scroll - 10)
        elif key == ord("G"):
            cursor = len(visible) - 1
        elif key == ord("g"):
            cursor = 0
        elif key == ord("e"):
            # Expand all children one level
            node = visible[cursor]
            node.ensure_children()
            node.expanded = True
            for child in node.children:
                child.ensure_children()
                child.expanded = True
        elif key == ord("c"):
            # Collapse all
            for node in visible[1:]:
                node.expanded = False
        elif key == ord("y"):
            # Yank path to clipboard
            try:
                subprocess.run(
                    ["xclip", "-selection", "clipboard"],
                    input=visible[cursor].path.encode(),
                    check=True,
                    stderr=subprocess.DEVNULL,
                )
            except (subprocess.CalledProcessError, FileNotFoundError):
                try:
                    subprocess.run(
                        ["wl-copy"],
                        input=visible[cursor].path.encode(),
                        check=True,
                        stderr=subprocess.DEVNULL,
                    )
                except (subprocess.CalledProcessError, FileNotFoundError):
                    pass


def usage():
    print("Usage: nix-browse <store-path-or-symlink>")
    print()
    print("Keybindings:")
    print("  j/k, ↑/↓     Navigate tree")
    print("  Enter         Toggle expand/collapse")
    print("  h/l, ←/→     Collapse / Expand")
    print("  J/K, PgDn/Up  Scroll preview")
    print("  /             Search, Enter to jump, n/N for next/prev")
    print("  e             Expand node + children one level")
    print("  c             Collapse all")
    print("  g/G           Jump to top/bottom")
    print("  y             Yank path to clipboard")
    print("  q             Quit")
    sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        usage()

    target = sys.argv[1]

    # Resolve symlinks (e.g. result/activation → /nix/store/...)
    resolved = resolve_path(target)
    if not os.path.exists(resolved):
        print(f"Error: {resolved} does not exist", file=sys.stderr)
        sys.exit(1)

    curses.wrapper(main, resolved)
