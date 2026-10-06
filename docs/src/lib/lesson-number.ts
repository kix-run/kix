// Tutorial pages are titled "05. Basic graph and deploy loop". The chrome
// shows the number and the title separately, so it splits them at render
// time instead of renaming the pages.
export function splitLessonNumber(title: string): { number: string; label: string } {
  const match = /^(\d+)\.\s+(.*)$/s.exec(title);
  return match ? { number: match[1], label: match[2] } : { number: '', label: title };
}
